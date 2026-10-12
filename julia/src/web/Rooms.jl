function room_for(ctx, id)
    room = qone(
        ctx.app,
        """SELECT r.*, m.involvement FROM rooms r
JOIN memberships m ON m.room_id=r.id WHERE r.id=? AND m.user_id=?""",
        (id, ctx.user.id),
    )
    isnothing(room) && return nothing
    if room.type == "Rooms::Direct"
        names = qrows(
            ctx.app,
            """SELECT u.name FROM users u JOIN memberships m ON m.user_id=u.id
WHERE m.room_id=? AND u.id!=? ORDER BY lower(u.name),u.id""",
            (id, ctx.user.id),
        )
        return merge(
            room,
            (display_name = "Ping with " * join((u.name for u in names), ", "),),
        )
    end
    return merge(room, (display_name = room.name,))
end

function selected_room_users(ctx)
    ids = Set{Int64}([ctx.user.id])
    for text in allparams(ctx, "user_ids")
        id = tryparse(Int64, string(text))
        if id !== nothing &&
           scalar(ctx.app, "SELECT 1 FROM users WHERE id=? AND status=0", (id,)) !== nothing
            push!(ids, id)
        end
    end
    return sort!(collect(ids))
end

function grant_room!(ctx, room, ids; direct = false)
    timestamp = nowstr()
    for id in ids
        execute!(
            ctx.app,
            """INSERT OR IGNORE INTO memberships
(room_id,user_id,involvement,created_at,updated_at) VALUES (?,?,?,?,?)""",
            (room, id, direct ? "everything" : "mentions", timestamp, timestamp),
        )
    end
end

function can_create_room(ctx)
    ctx.user.role == 1 && return true
    settings = try
        JSON3.read(coalesce(ctx.account.settings, "{}"))
    catch
        return false
    end
    return !get(settings, :restrict_room_creation_to_administrators, false)
end

function create_room!(ctx, kind)
    direct = kind == "directs"
    direct || can_create_room(ctx) || return html_response("Forbidden"; status = 403)
    ids = selected_room_users(ctx)
    if direct
        # Exact set equality avoids reusing a larger private conversation.
        candidates = qrows(
            ctx.app,
            """SELECT r.id FROM rooms r JOIN memberships m ON m.room_id=r.id
WHERE r.type='Rooms::Direct' GROUP BY r.id HAVING COUNT(*)=?""",
            (length(ids),),
        )
        for row in candidates
            members = [
                m.user_id for m in qrows(
                    ctx.app,
                    "SELECT user_id FROM memberships WHERE room_id=? ORDER BY user_id",
                    (row.id,),
                )
            ]
            members == ids && return redirect("/rooms/$(row.id)")
        end
    end
    name = strip(string(param(ctx, "room[name]", direct ? "Ping" : "New room")))
    isempty(name) && return html_response("Room name is required"; status = 422)
    type = kind == "opens" ? "Rooms::Open" : direct ? "Rooms::Direct" : "Rooms::Closed"
    timestamp = nowstr()
    execute!(
        ctx.app,
        "INSERT INTO rooms (name,type,creator_id,created_at,updated_at) VALUES (?,?,?,?,?)",
        (name, type, ctx.user.id, timestamp, timestamp),
    )
    id = scalar(ctx.app, "SELECT last_insert_rowid()")
    kind == "opens" &&
        (ids = [u.id for u in qrows(ctx.app, "SELECT id FROM users WHERE status=0")])
    grant_room!(ctx, id, ids; direct)
    broadcast_sidebar!(ctx)
    return redirect("/rooms/$id")
end

function remove_room!(ctx, room)
    for row in qrows(ctx.app, "SELECT id,room_id FROM messages WHERE room_id=?", (room.id,))
        delete_message!(ctx, row)
    end
    execute!(ctx.app, "DELETE FROM memberships WHERE room_id=?", (room.id,))
    execute!(ctx.app, "DELETE FROM rooms WHERE id=?", (room.id,))
    push!(ctx.events, Event(:revoke_room, room.id, nothing))
    broadcast_sidebar!(ctx)
    return redirect("/")
end

function route_rooms(ctx)
    path, method = ctx.path, ctx.method
    if path in ("/", "/rooms") && method == "GET"
        room = scalar(
            ctx.app,
            "SELECT room_id FROM memberships WHERE user_id=? ORDER BY room_id LIMIT 1",
            (ctx.user.id,),
        )
        return room === nothing ? redirect("/rooms/opens/new"; status = 302) :
               redirect("/rooms/$room"; status = 302)
    elseif path == "/users/me/sidebar" && method == "GET"
        rooms = [
            room_for(ctx, r.room_id) for r in qrows(
                ctx.app,
                "SELECT room_id FROM memberships WHERE user_id=? AND involvement!='invisible' ORDER BY room_id",
                (ctx.user.id,),
            )
        ]
        return html_response(layout(ctx, view(ctx, :sidebar; rooms); title = "Rooms"))
    elseif (
        m = match(r"^/rooms/(opens|closeds|directs)(?:/(new|\d+)(?:/(edit))?)?$", path)
    ) !== nothing
        kind, target, edit = m.captures
        if target === nothing && method == "POST"
            return create_room!(ctx, kind)
        elseif target == "new" && method == "GET"
            kind == "directs" && return html_response(view(ctx, :direct_new))
            can_create_room(ctx) || return html_response("Forbidden"; status = 403)
            users =
                qrows(ctx.app, "SELECT * FROM users WHERE status=0 ORDER BY lower(name),id")
            return html_response(view(ctx, :room_form; kind, users))
        elseif target !== nothing && target != "new"
            room = room_for(ctx, parse(Int64, target))
            room === nothing && return html_response("Not found"; status = 404)
            (room.type == "Rooms::Direct") == (kind == "directs") ||
                return html_response("Not found"; status = 404)
            admin =
                kind == "directs" || ctx.user.role == 1 || room.creator_id == ctx.user.id
            if method == "GET"
                edit === nothing && return redirect("/rooms/$(room.id)"; status = 302)
                if kind == "directs"
                    return html_response(view(ctx, :room_settings; room))
                end
                users = qrows(
                    ctx.app,
                    """SELECT u.*, EXISTS(SELECT 1 FROM memberships m WHERE m.user_id=u.id AND m.room_id=?) AS selected
  FROM users u WHERE status=0 ORDER BY lower(name),id""",
                    (room.id,),
                )
                return html_response(view(ctx, :room_form; room, kind, users))
            end
            admin || return html_response("Forbidden"; status = 403)
            method == "DELETE" && return remove_room!(ctx, room)
            if method in ("PATCH", "PUT") && kind != "directs"
                name = strip(string(param(ctx, "room[name]", room.name)))
                isempty(name) && return html_response("Room name is required"; status = 422)
                execute!(
                    ctx.app,
                    "UPDATE rooms SET name=?,type=?,updated_at=? WHERE id=?",
                    (
                        name,
                        kind == "opens" ? "Rooms::Open" : "Rooms::Closed",
                        nowstr(),
                        room.id,
                    ),
                )
                ids =
                    kind == "opens" ?
                    [u.id for u in qrows(ctx.app, "SELECT id FROM users WHERE status=0")] :
                    selected_room_users(ctx)
                old = qrows(
                    ctx.app,
                    "SELECT user_id FROM memberships WHERE room_id=?",
                    (room.id,),
                )
                for member in old
                    if member.user_id ∉ ids
                        execute!(
                            ctx.app,
                            "DELETE FROM memberships WHERE room_id=? AND user_id=?",
                            (room.id, member.user_id),
                        )
                    end
                end
                grant_room!(ctx, room.id, ids)
                push!(ctx.events, Event(:revoke_room, room.id, nothing))
                broadcast_sidebar!(ctx)
                return redirect("/rooms/$(room.id)")
            end
        end
        return html_response("Method not allowed"; status = 405)
    elseif (
        m = match(
            r"^/rooms/(\d+)(?:/(?:@(\d+)|(settings|involvement|refresh|edit)))?$",
            path,
        )
    ) !== nothing
        id, anchor, operation = m.captures
        room = room_for(ctx, parse(Int64, id))
        room === nothing && return html_response("Not found"; status = 404)
        if operation == "involvement"
            if method in ("PUT", "PATCH")
                involvement = string(param(ctx, "involvement"))
                involvement in ("nothing", "mentions", "everything", "invisible") ||
                    return html_response("Invalid involvement"; status = 422)
                execute!(
                    ctx.app,
                    "UPDATE memberships SET involvement=?,updated_at=? WHERE user_id=? AND room_id=?",
                    (involvement, nowstr(), ctx.user.id, room.id),
                )
                broadcast_sidebar!(ctx, [ctx.user.id])
                return redirect("/rooms/$id/involvement")
            end
            method == "GET" && return html_response(
                view(ctx, :involvement; room, involvement = room.involvement),
            )
        elseif operation == "refresh" && method == "GET"
            since = something(tryparse(Int64, string(param(ctx, "since", "0"))), 0)
            # Bound conversion to the representable application date range.
            0 <= since <= 253402300799000 ||
                return html_response("Invalid timestamp"; status = 400)
            date =
                Dates.format(unix2datetime(since/1000), dateformat"yyyy-mm-dd HH:MM:SS.sss")
            created = qrows(
                ctx.app,
                WEB_MESSAGE_COLUMNS *
                " WHERE m.room_id=? AND m.created_at>? ORDER BY m.created_at,m.id LIMIT 40",
                (room.id, date),
            )
            created_ids = [message.id for message in created]
            updated = qrows(
                ctx.app,
                WEB_MESSAGE_COLUMNS *
                " WHERE m.room_id=? AND m.updated_at>? AND m.id NOT IN (SELECT value FROM json_each(?)) ORDER BY +m.created_at DESC,m.id DESC LIMIT 40",
                (room.id, date, JSON3.write(created_ids)),
            )
            reverse!(updated)
            rows = message_presentations(ctx, vcat(created, updated))
            body = join(
                message_stream(
                    message.id ∈ created_ids ? "append" : "replace",
                    message.id ∈ created_ids ? messages_target(room) :
                    "message_$(message.id)",
                    message_html(ctx, message),
                ) for message in rows
            )
            return stream_response(body)
        elseif operation in ("settings", "edit") && method == "GET"
            kind =
                room.type == "Rooms::Open" ? "opens" :
                room.type == "Rooms::Closed" ? "closeds" : "directs"
            return redirect("/rooms/$kind/$id/edit"; status = 302)
        elseif operation === nothing && method == "GET"
            anchor !== nothing &&
                get_message(ctx, parse(Int64, anchor); room = room.id) === nothing &&
                return html_response("Not found"; status = 404)
            messages = query_messages(
                ctx,
                room.id;
                around = anchor === nothing ? nothing : parse(Int64, anchor),
            )
            return html_response(view(ctx, :room; room, messages))
        elseif operation === nothing && method == "DELETE"
            (
                ctx.user.role == 1 ||
                ctx.user.id == room.creator_id ||
                room.type == "Rooms::Direct"
            ) || return html_response("Forbidden"; status = 403)
            return remove_room!(ctx, room)
        end
        return html_response("Method not allowed"; status = 405)
    elseif path in (
        "/autocompletable/users",
        "/autocompletable/users.json",
        "/users/autocompletable",
    ) && method == "GET"
        return autocomplete_users(ctx)
    end
    return nothing
end

function autocomplete_users(ctx)
    room = string(param(ctx, "room_id"))
    query = string(param(ctx, "filter", param(ctx, "query")))
    page = max(something(tryparse(Int, string(param(ctx, "page", "1"))), 1), 1)
    page > 100000 && return json_response([])
    parameters = Any[]
    sql = "SELECT u.* FROM users u WHERE u.status=0"
    if !isempty(room)
        reachable_room(ctx, room) || return html_response("Not found"; status = 404)
        sql *= " AND EXISTS(SELECT 1 FROM memberships m WHERE m.user_id=u.id AND m.room_id=?)"
        push!(parameters, room)
    end
    if !isempty(query)
        sql *= " AND instr(lower(u.name),lower(?))>0"
        push!(parameters, query)
    end
    sql *= " ORDER BY lower(u.name),u.id LIMIT 20 OFFSET ?"
    push!(parameters, 20*(page-1))
    users = qrows(ctx.app, sql, Tuple(parameters))
    if occursin("json", HTTP.header(ctx.req, "Accept")) || endswith(ctx.path, ".json")
        return json_response([
            (
                name = h(u.name),
                value = u.id,
                avatar_url = "/users/$(signed_token(ctx.app, "avatar", string(u.id)))/avatar",
            ) for u in users
        ])
    end
    body = join(mention_prompt_html(ctx, u) for u in users)
    return html_response(body)
end
