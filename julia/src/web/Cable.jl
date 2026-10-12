# Socket writes are serialized by a bounded per-client queue. Database and broker
# changes share app.lock; no socket I/O runs while that lock is held.
function enqueue!(client, payload)
    if isopen(client.outgoing) && Base.n_avail(client.outgoing) < 256
        put!(client.outgoing, payload isa String ? payload : JSON3.write(payload))
        return true
    end
    isopen(client.outgoing) && close(client.outgoing)
    return false
end

function cable_user(app, client)
    user = authenticate(app, client.request)
    return user !== nothing && user.id == client.user_id ? user : nothing
end
cable_member(app, client, room) =
    scalar(
        app,
        "SELECT 1 FROM memberships WHERE user_id=? AND room_id=?",
        (client.user_id, room),
    ) !== nothing

function cable_subscription(app, client, identifier)
    data = JSON3.read(identifier)
    channel = string(get(data, :channel, ""))
    room = something(tryparse(Int64, string(get(data, :room_id, "0"))), 0)
    if channel == "RoomMessagesChannel"
        stream = verify_token(app, "stream", string(get(data, :signed_stream_name, "")))
        stream == "room:$room:messages" && cable_member(app, client, room) || return nothing
        return Subscription(channel, room, stream)
    elseif channel == "Turbo::StreamsChannel"
        stream = verify_token(app, "stream", string(get(data, :signed_stream_name, "")))
        stream in ("rooms", "user:$(client.user_id):rooms") || return nothing
        return Subscription(channel, 0, stream)
    elseif channel in ("PresenceChannel", "TypingNotificationsChannel")
        cable_member(app, client, room) || return nothing
        return Subscription(channel, room, "")
    elseif channel in ("ReadRoomsChannel", "UnreadRoomsChannel", "HeartbeatChannel")
        return Subscription(channel, 0, "")
    end
    return nothing
end

function deliver_channel!(app, channel, payload; user = 0, room = 0, unread = false)
    frames = Dict{String,String}()
    for client in values(app.broker.clients)
        user != 0 && user != client.user_id && continue
        cable_user(app, client) === nothing && continue
        room != 0 && !cable_member(app, client, room) && continue
        if unread
            cutoff = Dates.format(now(UTC)-Second(60), dateformat"yyyy-mm-dd HH:MM:SS.sss")
            scalar(
                app,
                """SELECT 1 FROM memberships WHERE user_id=? AND room_id=?
         AND (unread_at IS NOT NULL OR connected_at>=?)""",
                (client.user_id, room, cutoff),
            ) === nothing && continue
        end
        for (identifier, subscription) in client.subscriptions
            subscription.channel == channel || continue
            subscription.room_id != 0 && subscription.room_id != room && continue
            frame = get!(frames, identifier) do
                return JSON3.write((identifier = identifier, message = payload))
            end
            enqueue!(client, frame)
        end
    end
end

function presence!(app, client, room, action)
    app.closing && return
    if action == "absent"
        room ∈ client.present || return
        delete!(client.present, room)
        execute!(
            app,
            """UPDATE memberships SET connections=max(0,connections-1),
   connected_at=CASE WHEN connections<=1 THEN NULL ELSE connected_at END
   WHERE room_id=? AND user_id=?""",
            (room, client.user_id),
        )
    elseif action in ("present", "refresh") && cable_member(app, client, room)
        increment = room ∈ client.present ? 0 : 1
        push!(client.present, room)
        cutoff = Dates.format(now(UTC)-Second(60), dateformat"yyyy-mm-dd HH:MM:SS.sss")
        timestamp = nowstr()
        unread = action == "present" ? ",unread_at=NULL" : ""
        execute!(
            app,
            """UPDATE memberships SET connections=CASE
   WHEN connected_at>=? THEN max(1,connections+?) ELSE 1 END,connected_at=?
   $unread WHERE room_id=? AND user_id=?""",
            (cutoff, increment, timestamp, room, client.user_id),
        )
        action == "present" && deliver_channel!(
            app,
            "ReadRoomsChannel",
            (room_id = room, at = time());
            user = client.user_id,
        )
    end
    return nothing
end

function cable_command!(app, client, raw)
    length(raw) <= 65536 || throw(ArgumentError("websocket command too large"))
    data = JSON3.read(raw)
    command = get(data, :command, "")
    identifier = string(get(data, :identifier, ""))
    user = cable_user(app, client)
    if user === nothing
        enqueue!(client, (type = "disconnect", reason = "unauthorized", reconnect = false))
        close(client.outgoing)
        return
    end
    if command == "subscribe"
        length(client.subscriptions) < 64 || return
        subscription = cable_subscription(app, client, identifier)
        if subscription === nothing
            enqueue!(client, (type = "reject_subscription", identifier = identifier))
        else
            client.subscriptions[identifier] = subscription
            enqueue!(client, (type = "confirm_subscription", identifier = identifier))
            subscription.channel == "PresenceChannel" &&
                presence!(app, client, subscription.room_id, "present")
        end
    elseif command == "unsubscribe"
        subscription = pop!(client.subscriptions, identifier, nothing)
        if subscription !== nothing && subscription.channel == "PresenceChannel"
            remains = any(
                s ->
                    s.channel == "PresenceChannel" && s.room_id == subscription.room_id,
                values(client.subscriptions),
            )
            remains || presence!(app, client, subscription.room_id, "absent")
        end
    elseif command == "message"
        subscription = get(client.subscriptions, identifier, nothing)
        subscription === nothing && return
        subscription.room_id != 0 &&
            !cable_member(app, client, subscription.room_id) &&
            return
        message = JSON3.read(string(get(data, :data, "{}")))
        action = string(get(message, :action, ""))
        if subscription.channel == "PresenceChannel"
            presence!(app, client, subscription.room_id, action)
        elseif subscription.channel == "TypingNotificationsChannel" &&
               action in ("start", "stop")
            deliver_channel!(
                app,
                "TypingNotificationsChannel",
                (action = action, user = (id = user.id, name = user.name));
                room = subscription.room_id,
            )
        end
    end
    return nothing
end

function sidebar_updates(ctx)
    rooms = [
        room_for(ctx, r.room_id) for r in qrows(
            ctx.app,
            "SELECT room_id FROM memberships WHERE user_id=? AND involvement!='invisible' ORDER BY room_id",
            (ctx.user.id,),
        )
    ]
    shared = join(sidebar_room_html(ctx, r) for r in rooms if r.type != "Rooms::Direct")
    directs = join(sidebar_room_html(ctx, r) for r in rooms if r.type == "Rooms::Direct")
    return message_stream("update", "shared_rooms", shared) *
           message_stream("update", "direct_rooms", directs)
end

function publish_events!(app, events)
    isempty(events) && return
    lock(app.lock) do
        app.closing && return
        for event in events
            if event.kind == :webhook
                launch_job!(() -> deliver_webhook!(app, event.id, event.payload), app)
            elseif event.kind == :push
                launch_job!(() -> deliver_message_push!(app, event.id, event.payload), app)
            elseif event.kind == :push_test
                launch_job!(() -> deliver_test_push!(app, event.id, event.payload), app)
            elseif event.kind == :purge_storage
                launch_job!(() -> purge_storage!(app, event.payload), app)
            elseif event.kind == :room
                deliver_channel!(app, "RoomMessagesChannel", event.payload; room = event.id)
            elseif event.kind == :unread
                deliver_channel!(
                    app,
                    "UnreadRoomsChannel",
                    event.payload;
                    room = event.id,
                    unread = true,
                )
            elseif event.kind == :sidebar
                rendered = Dict{Int64,String}()
                for client in values(app.broker.clients)
                    event.id != 0 && event.id != client.user_id && continue
                    user = cable_user(app, client)
                    user === nothing && continue
                    html = get!(rendered, user.id) do
                        ctx = current_context(
                            app,
                            client.request,
                            Dict{String,Any}(),
                            "/users/me/sidebar",
                            "GET",
                        )
                        return sidebar_updates(ctx)
                    end
                    # One per-user stream avoids duplicate delivery when also
                    # subscribed to the account-wide room stream.
                    for (identifier, subscription) in client.subscriptions
                        subscription.stream == "user:$(user.id):rooms" || continue
                        enqueue!(client, (identifier = identifier, message = html))
                    end
                end
            elseif event.kind in (:disconnect, :revoke_room)
                for client in values(app.broker.clients)
                    affected =
                        event.kind == :disconnect ? event.id == client.user_id :
                        any(s -> s.room_id == event.id, values(client.subscriptions)) &&
                        !cable_member(app, client, event.id)
                    affected || continue
                    enqueue!(
                        client,
                        (type = "disconnect", reason = "remote", reconnect = true),
                    )
                    close(client.outgoing)
                end
            end
        end
    end
    return nothing
end

function serve_cable(app, stream)
    req = stream.message
    user = lock(app.lock) do
        return same_origin_request(app, req) ? authenticate(app, req) : nothing
    end
    if user === nothing
        HTTP.setstatus(stream, 403)
        HTTP.startwrite(stream)
        return
    end
    protocols = strip.(split(HTTP.header(req, "Sec-WebSocket-Protocol"), ','))
    if "actioncable-v1-json" ∈ protocols
        HTTP.setheader(stream, "Sec-WebSocket-Protocol"=>"actioncable-v1-json")
    end
    HTTP.WebSockets.upgrade(stream; maxframesize = 65536, maxfragmentation = 16) do socket
        client = Client(
            uuid4(),
            user.id,
            req,
            socket,
            Channel{String}(256),
            Dict{String,Subscription}(),
            Set{Int64}(),
        )
        lock(app.lock) do
            return app.broker.clients[client.id] = client
        end
        writer = @async try
            for payload in client.outgoing
                HTTP.WebSockets.send(socket, payload)
            end
        finally
            close(socket)
        end
        enqueue!(client, (type = "welcome",))
        timer = Timer(3; interval = 3) do _
            lock(app.lock) do
                if cable_user(app, client) === nothing
                    enqueue!(
                        client,
                        (type = "disconnect", reason = "unauthorized", reconnect = false),
                    )
                    isopen(client.outgoing) && close(client.outgoing)
                else
                    refresh_session_activity!(app, client.request)
                    enqueue!(client, (type = "ping", message = floor(Int, time())))
                end
            end
        end
        try
            for raw in socket
                lock(app.lock) do
                    try
                        cable_command!(app, client, raw)
                    catch error
                        error isa ArgumentError || rethrow()
                        enqueue!(
                            client,
                            (
                                type = "disconnect",
                                reason = "invalid_request",
                                reconnect = false,
                            ),
                        )
                        isopen(client.outgoing) && close(client.outgoing)
                    end
                end
            end
        catch error
            # Closing an authenticated connection remotely wakes its reader with
            # EOF; this is the expected shutdown path, not a server error.
            error isa EOFError || HTTP.WebSockets.isok(error) || rethrow()
        finally
            close(timer)
            lock(app.lock) do
                for room in collect(client.present)
                    presence!(app, client, room, "absent")
                end
                delete!(app.broker.clients, client.id)
                return isopen(client.outgoing) && close(client.outgoing)
            end
            try
                wait(writer)
            catch error
                @debug "Socket writer closed" exception=error
            end
        end
    end
    return nothing
end
