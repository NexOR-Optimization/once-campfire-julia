using Test, HTTP, JSON3, Sockets
if !isdefined(@__MODULE__, :Campfire)
    include(joinpath(@__DIR__, "../julia/src/Campfire.jl"))
end

@testset "Action Cable transport and live authorization" begin
    W = Campfire.Web
    mktempdir() do directory
        app = W.WebApp(joinpath(directory, "db.sqlite3"); secret = repeat("c", 64))
        timestamp = W.nowstr()
        W.execute!(
            app,
            "INSERT INTO accounts(name,join_code,created_at,updated_at) VALUES('Test','code',?,?)",
            (timestamp, timestamp),
        )
        for id = 1:2
            W.execute!(
                app,
                "INSERT INTO users(id,name,email_address,created_at,updated_at) VALUES(?,?,?,?,?)",
                (id, "User $id", "$id@test.local", timestamp, timestamp),
            )
            W.execute!(
                app,
                "INSERT INTO sessions(user_id,token,last_active_at,created_at,updated_at) VALUES(?,?,?,?,?)",
                (id, "session-$id", timestamp, timestamp, timestamp),
            )
        end
        W.execute!(
            app,
            "INSERT INTO rooms(id,name,type,creator_id,created_at,updated_at) VALUES(1,'Private','Rooms::Closed',1,?,?)",
            (timestamp, timestamp),
        )
        W.execute!(
            app,
            "INSERT INTO memberships(user_id,room_id,created_at,updated_at) VALUES(1,1,?,?)",
            (timestamp, timestamp),
        )
        listener = listen(ip"127.0.0.1", 0)
        port = getsockname(listener)[2]
        server = W.start_server(app; server = listener)
        origin = "http://127.0.0.1:$port"
        cookies =
            ["session_token=" * W.signed_token(app, "session", "session-$id") for id = 1:2]
        function next_message(channel; type = nothing)
            deadline = time()+10
            while time()<deadline
                timedwait(
                    () -> isready(channel),
                    max(0.01, deadline-time());
                    pollint = 0.01,
                ) == :ok || error("Cable response timed out")
                message = take!(channel)
                (type === nothing || get(message, :type, nothing)==type) && return message
            end
            error("Cable message missing")
        end
        function subscribe(socket, channel; kwargs...)
            identifier = JSON3.write((channel = channel, kwargs...))
            HTTP.WebSockets.send(
                socket,
                JSON3.write((command = "subscribe", identifier = identifier)),
            )
            return identifier
        end
        try
            health = HTTP.get(origin*"/up")
            @test health.status == 200
            @test HTTP.get(origin*"/rooms/1", ["Cookie"=>cookies[1]]).status == 200
            W.execute!(
                app,
                "UPDATE users SET password_digest=? WHERE id=1",
                (W.password_digest("test-password"; cost = 4),),
            )
            blocked = HTTP.get(origin*"/rooms/1"; redirect = false)
            @test blocked.status == 302
            return_cookie = first(split(HTTP.header(blocked, "Set-Cookie"), ';'))
            login = HTTP.post(
                origin*"/session",
                [
                    "Cookie"=>return_cookie,
                    "Content-Type"=>"application/x-www-form-urlencoded",
                    "Origin"=>origin,
                ],
                "email_address=1%40test.local&password=test-password";
                redirect = false,
            )
            @test login.status == 302
            @test HTTP.header(login, "Location") == "/rooms/1"
            @test count(pair -> lowercase(pair.first)=="set-cookie", login.headers) == 2
            @test startswith(HTTP.header(login, "Set-Cookie"), "session_token=")
            @test_throws HTTP.Exceptions.RequestError HTTP.WebSockets.open(
                _ -> nothing,
                "ws://127.0.0.1:$port/cable";
                headers = ["Origin"=>origin],
            )
            @test_throws HTTP.Exceptions.RequestError HTTP.WebSockets.open(
                _ -> nothing,
                "ws://127.0.0.1:$port/cable";
                headers = ["Origin"=>"http://evil.test", "Cookie"=>cookies[1]],
            )
            HTTP.WebSockets.open(
                "ws://127.0.0.1:$port/cable";
                headers = [
                    "Origin"=>origin,
                    "Cookie"=>cookies[1],
                    "Sec-WebSocket-Protocol"=>"actioncable-v1-json",
                ],
            ) do socket
                incoming = Channel{Any}(100)
                reader = @async for payload in socket
                    put!(incoming, JSON3.read(payload))
                end
                @test next_message(incoming; type = "welcome").type == "welcome"
                signature = W.signed_token(app, "stream", "room:1:messages")
                room_id = subscribe(
                    socket,
                    "RoomMessagesChannel";
                    room_id = 1,
                    signed_stream_name = signature,
                )
                @test next_message(incoming; type = "confirm_subscription").identifier ==
                      room_id
                subscribe(
                    socket,
                    "RoomMessagesChannel";
                    room_id = 2,
                    signed_stream_name = signature,
                )
                @test next_message(incoming; type = "reject_subscription").type ==
                      "reject_subscription"
                subscribe(socket, "Turbo::StreamsChannel"; signed_stream_name = signature)
                @test next_message(incoming; type = "reject_subscription").type ==
                      "reject_subscription"
                read_id = subscribe(socket, "ReadRoomsChannel")
                next_message(incoming; type = "confirm_subscription")
                presence_id = subscribe(socket, "PresenceChannel"; room_id = 1)
                next_message(incoming; type = "confirm_subscription")
                read_event = next_message(incoming)
                @test read_event.identifier == read_id
                @test read_event.message.room_id == 1
                @test lock(
                    () -> W.scalar(
                        app,
                        "SELECT connections FROM memberships WHERE user_id=1 AND room_id=1",
                    ),
                    app.lock,
                ) == 1
                lock(app.lock) do
                    W.execute!(
                        app,
                        "UPDATE memberships SET connections=7,connected_at='2000',unread_at='2026' WHERE room_id=1 AND user_id=1",
                    )
                end
                HTTP.WebSockets.send(
                    socket,
                    JSON3.write((
                        command = "message",
                        identifier = presence_id,
                        data = JSON3.write((action = "refresh",)),
                    )),
                )
                @test timedwait(
                    () ->
                        lock(
                            () -> W.scalar(
                                app,
                                "SELECT connections FROM memberships WHERE user_id=1 AND room_id=1",
                            ),
                            app.lock,
                        )==1,
                    5;
                    pollint = 0.01,
                ) == :ok
                @test lock(
                    () -> W.scalar(
                        app,
                        "SELECT unread_at FROM memberships WHERE user_id=1 AND room_id=1",
                    ),
                    app.lock,
                ) == "2026"
                yield()
                @test lock(
                    () -> W.scalar(
                        app,
                        "SELECT connections FROM memberships WHERE user_id=1 AND room_id=1",
                    ),
                    app.lock,
                ) == 1
                post = HTTP.post(
                    origin*"/rooms/1/messages",
                    [
                        "Cookie"=>cookies[1],
                        "Content-Type"=>"application/x-www-form-urlencoded",
                        "Origin"=>origin,
                    ],
                    "message%5Bbody%5D=Live+Julia",
                )
                @test post.status == 200
                broadcast = next_message(incoming)
                @test broadcast.identifier == room_id
                @test occursin("Live Julia", broadcast.message)
                @test occursin("action=\"append\"", broadcast.message)
                sidebar_id = subscribe(
                    socket,
                    "Turbo::StreamsChannel";
                    signed_stream_name = W.signed_token(app, "stream", "user:1:rooms"),
                )
                @test next_message(incoming; type = "confirm_subscription").identifier ==
                      sidebar_id
                created_room = HTTP.post(
                    origin*"/rooms/opens",
                    [
                        "Cookie"=>cookies[1],
                        "Content-Type"=>"application/x-www-form-urlencoded",
                        "Origin"=>origin,
                    ],
                    "room%5Bname%5D=Live+room";
                    redirect = false,
                )
                @test created_room.status == 303
                sidebar = next_message(incoming)
                @test sidebar.identifier == sidebar_id
                @test occursin("Live room", sidebar.message)
                @test occursin("shared_rooms", sidebar.message)
                HTTP.WebSockets.open(
                    "ws://127.0.0.1:$port/cable";
                    headers = ["Origin"=>origin, "Cookie"=>cookies[2]],
                ) do outsider
                    @test JSON3.read(HTTP.WebSockets.receive(outsider)).type == "welcome"
                    subscribe(
                        outsider,
                        "RoomMessagesChannel";
                        room_id = 1,
                        signed_stream_name = signature,
                    )
                    @test JSON3.read(HTTP.WebSockets.receive(outsider)).type ==
                          "reject_subscription"
                end
                lock(app.lock) do
                    W.execute!(app, "DELETE FROM memberships WHERE user_id=1 AND room_id=1")
                end
                W.publish_events!(app, [W.Event(:revoke_room, 1, nothing)])
                @test next_message(incoming; type = "disconnect").reason == "remote"
                wait(reader)
            end
            @test timedwait(() -> isempty(app.broker.clients), 5; pollint = 0.01) == :ok
            # Fresh session revocation is also checked on each socket command.
            HTTP.WebSockets.open(
                "ws://127.0.0.1:$port/cable";
                headers = ["Cookie"=>cookies[2], "Origin"=>origin],
            ) do socket
                @test JSON3.read(HTTP.WebSockets.receive(socket)).type == "welcome"
                lock(app.lock) do
                    W.execute!(app, "DELETE FROM sessions WHERE user_id=2")
                end
                subscribe(socket, "HeartbeatChannel")
                @test JSON3.read(HTTP.WebSockets.receive(socket)).type == "disconnect"
            end
        finally
            close(server)
            close(app)
        end
    end
end
