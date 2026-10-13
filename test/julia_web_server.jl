using Test, HTTP, SQLite, JSON3, CodecZlib, Sockets, Dates
if !isdefined(@__MODULE__, :Campfire)
    include(joinpath(@__DIR__, "../julia/src/Campfire.jl"))
end

@testset "Request target and form parameters" begin
    W = Campfire.Web
    req = HTTP.Request(
        "POST",
        "/rooms/1/messages?message%5Bbody%5D=query&label=Julia+%26+Ruby&tags%5B%5D=a&tags%5B%5D=b",
        ["Content-Type" => "application/x-www-form-urlencoded"],
        "message%5Bbody%5D=body+%F0%9F%91%8D",
    )
    parameters = W.request_parameters(req)
    @test parameters["message[body]"] == "body 👍"
    @test parameters["label"] == "Julia & Ruby"
    @test parameters["tags[]"] == ["a", "b"]
    @test W.request_parameters(req, HTTP.URI(req.target)) == parameters
end

@testset "Whole server HTTP and room authorization" begin
    W = Campfire.Web
    mktempdir() do directory
        # This suite inspects the single-owner cache; the reader suite exercises
        # concurrent shards and aggregate limits explicitly.
        app = W.WebApp(
            joinpath(directory, "campfire.sqlite3");
            secret = repeat("j", 64),
            readers = 0,
        )
        function request(
            method,
            path;
            cookie = "",
            params = Dict(),
            headers = Pair{String,String}[],
        )
            body = join(
                (
                    HTTP.escapeuri(string(k))*"="*HTTP.escapeuri(string(v)) for
                    (k, v) in params
                ),
                "&",
            )
            req = HTTP.Request(
                method,
                path,
                [
                    "Host"=>"localhost";
                    "Cookie"=>cookie;
                    "Content-Type"=>"application/x-www-form-urlencoded";
                    headers
                ],
                body,
            )
            return W.handle_request(app, req)
        end
        try
            @test request("GET", "/").status == 302
            @test HTTP.header(request("GET", "/"), "Location") == "/first_run"
            @test request("GET", "/first_run").status == 200
            @test request("GET", "/account/logo").status == 200
            @test request("GET", "/webmanifest").status == 200
            @test request("GET", "/service-worker").status == 200
            setup = request(
                "POST",
                "/first_run";
                params = Dict(
                    "user[name]"=>"Admin",
                    "user[email_address]"=>"admin@test.local",
                    "user[password]"=>"long-test-password",
                ),
            )
            @test setup.status == 302
            cookie = first(split(HTTP.header(setup, "Set-Cookie"), ';'))
            @test !isempty(cookie)
            @test W.scalar(app, "SELECT count(*) FROM accounts") == 1
            @test request("POST", "/first_run"; cookie).status == 302
            @test request(
                "POST",
                "/rooms/opens";
                cookie,
                params = Dict("room[name]"=>"forbidden"),
                headers = ["Origin"=>"http://evil.local"],
            ).status == 403
            @test request(
                "POST",
                "/rooms/opens";
                cookie,
                params = Dict("room[name]"=>"forbidden"),
                headers = ["Sec-Fetch-Site"=>"cross-site"],
            ).status == 403
            @test W.scalar(app, "SELECT count(*) FROM rooms") == 1
            @test request("GET", "/rooms/1"; cookie).status == 200
            @test request("GET", "/rooms/opens/new"; cookie).status == 200
            @test request("GET", "/rooms/closeds/new"; cookie).status == 200
            @test request("GET", "/rooms/directs/new"; cookie).status == 200
            @test request(
                "POST",
                "/unfurl_link";
                cookie,
                params = Dict("url"=>"http://127.0.0.1/private"),
            ).status == 204
            head = request("HEAD", "/rooms/1"; cookie)
            @test head.status == 200
            @test head.body == UInt8[]
            @test HTTP.header(head, "X-Content-Type-Options") == "nosniff"
            @test !isempty(request("GET", "/rooms/1"; cookie).body)
            @test isempty(request("HEAD", "/up").body)
            @test request("GET", "/users/me/sidebar"; cookie).status == 200
            @test request("GET", "/users/me/profile"; cookie).status == 200
            changed = W.handle_request(
                app,
                HTTP.Request(
                    "PATCH",
                    "/account",
                    ["Cookie"=>cookie, "Content-Type"=>"application/json"],
                    JSON3.write((account = (name = "JSON account",),)),
                ),
            )
            @test changed.status == 303
            @test W.scalar(app, "SELECT name FROM accounts") == "JSON account"
            # Browsers submit filename="" for an untouched file input. It must
            # preserve an existing avatar during an ordinary profile edit.
            boundary = "campfire-test-upload"
            image = read(joinpath(@__DIR__, "fixtures/files/moon.jpg"))
            prefix = "--$boundary\r\nContent-Disposition: form-data; name=\"user[avatar]\"; filename=\"moon.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n"
            uploaded = vcat(codeunits(prefix), image, codeunits("\r\n--$boundary--\r\n"))
            multipart_headers = [
                "Cookie"=>cookie,
                "Content-Type"=>"multipart/form-data; boundary=$boundary",
            ]
            @test W.handle_request(
                app,
                HTTP.Request("PATCH", "/users/me/profile", multipart_headers, uploaded),
            ).status == 303
            avatar = W.scalar(
                app,
                "SELECT blob_id FROM active_storage_attachments WHERE record_type='User' AND record_id=1 AND name='avatar'",
            )
            @test avatar !== nothing
            empty_upload = "--$boundary\r\nContent-Disposition: form-data; name=\"user[avatar]\"; filename=\"\"\r\nContent-Type: application/octet-stream\r\n\r\n\r\n--$boundary--\r\n"
            @test W.handle_request(
                app,
                HTTP.Request("PATCH", "/users/me/profile", multipart_headers, empty_upload),
            ).status == 303
            @test W.scalar(
                app,
                "SELECT blob_id FROM active_storage_attachments WHERE record_type='User' AND record_id=1 AND name='avatar'",
            ) == avatar
            W.execute!(
                app,
                "UPDATE sessions SET last_active_at='2000-01-01 00:00:00' WHERE user_id=1",
            )
            @test request("GET", "/rooms/1"; cookie).status == 200
            @test startswith(
                W.scalar(app, "SELECT last_active_at FROM sessions WHERE user_id=1"),
                string(year(now())),
            )
            @test request("GET", "/rooms/1/settings"; cookie).status == 302
            created = request(
                "POST",
                "/rooms/opens";
                cookie,
                params = Dict("room[name]"=>"New Test Room"),
            )
            @test created.status == 303
            @test HTTP.header(created, "Location") == "/rooms/2"
            @test request(
                "PATCH",
                "/rooms/opens/2";
                cookie,
                params = Dict("room[name]"=>"Renamed"),
            ).status == 303
            @test W.scalar(app, "SELECT name FROM rooms WHERE id=2") == "Renamed"
            # HTML forms override only POST and only the supported write verbs.
            for override in ("patch", "PuT")
                renamed = "Renamed by $override"
                @test request(
                    "post",
                    "/rooms/opens/2";
                    cookie,
                    params = Dict("_method"=>override, "room[name]"=>renamed),
                ).status == 303
                @test W.scalar(app, "SELECT name FROM rooms WHERE id=2") == renamed
            end
            for override in ("GET", "HEAD", "OPTIONS", "invalid")
                @test request(
                    "POST",
                    "/rooms/opens/2";
                    cookie,
                    params = Dict("_method"=>override, "room[name]"=>"Forbidden"),
                ).status == 405
            end
            @test request(
                "GET",
                "/rooms/opens/2";
                cookie,
                params = Dict("_method"=>"DELETE"),
            ).status == 302
            @test W.scalar(app, "SELECT name FROM rooms WHERE id=2") == "Renamed by PuT"
            @test request(
                "POST",
                "/rooms/2/messages";
                cookie,
                params = Dict("message[body]"=>"<strong>Julia &amp; Ruby</strong>"),
            ).status == 200
            @test W.scalar(app, "SELECT count(*) FROM message_search_index") == 1
            room = request("GET", "/rooms/2"; cookie)
            @test occursin("Julia &amp; Ruby", String(copy(room.body)))
            @test room.body isa Base.CodeUnits
            @test_throws CanonicalIndexError setindex!(room.body, 0x00, 1)
            @test String(room.body) == String(request("GET", "/rooms/2"; cookie).body)
            other_host =
                request("GET", "/rooms/2"; cookie, headers = ["Host"=>"other.test"])
            @test other_host.status == 200
            compressed = request(
                "GET",
                "/rooms/2";
                cookie,
                headers = ["Accept-Encoding"=>"br, gzip"],
            )
            @test HTTP.header(compressed, "Content-Encoding") == "gzip"
            @test transcode(GzipDecompressor, compressed.body) == room.body
            @test HTTP.header(
                request(
                    "GET",
                    "/rooms/2";
                    cookie,
                    headers = ["Accept-Encoding"=>"gzip;q=0, *;q=1"],
                ),
                "Content-Encoding",
            ) == ""
            @test app.cache_bytes <= app.cache_budget
            @test !isempty(app.cache)
            # A separate connection must invalidate cached data and cached access.
            external = SQLite.DB(joinpath(directory, "campfire.sqlite3"))
            try
                W.execute_db!(
                    external,
                    "UPDATE rooms SET name='Externally renamed' WHERE id=2",
                )
                @test occursin(
                    "Externally renamed",
                    String(request("GET", "/rooms/2"; cookie).body),
                )
                # Revoke after this reader has established its old SQLite snapshot.
                generation = W.cache_generation!(app)
                W.execute!(app, "BEGIN")
                @test W.scalar(
                    app,
                    "SELECT count(*) FROM memberships WHERE user_id=1 AND room_id=2",
                ) == 1
                W.execute_db!(
                    external,
                    "DELETE FROM memberships WHERE user_id=1 AND room_id=2",
                )
                cached_request =
                    HTTP.Request("GET", "/rooms/2", ["Host"=>"localhost", "Cookie"=>cookie])
                @test W.cached_page(app, cached_request, "/rooms/2", generation) === nothing
                W.execute!(app, "ROLLBACK")
                @test request("GET", "/rooms/2"; cookie).status == 404
                @test request("GET", "/rooms/2/messages"; cookie).status == 404
                W.execute_db!(
                    external,
                    "INSERT INTO memberships(user_id,room_id,created_at,updated_at) VALUES(1,2,'2026','2026')",
                )
            finally
                SQLite.close(external)
            end
            code = W.scalar(app, "SELECT join_code FROM accounts")
            joined = request(
                "POST",
                "/join/$code";
                params = Dict(
                    "user[name]"=>"Member",
                    "user[email_address]"=>"member@test.local",
                    "user[password]"=>"long-test-password",
                ),
            )
            @test joined.status == 302
            member = first(split(HTTP.header(joined, "Set-Cookie"), ';'))
            @test request("GET", "/account/bots"; cookie = member).status == 403
            @test request(
                "PATCH",
                "/rooms/opens/2";
                cookie = member,
                params = Dict("room[name]"=>"hijack"),
            ).status == 403
            @test request(
                "PATCH",
                "/account";
                cookie,
                params = Dict(
                    "account[settings][restrict_room_creation_to_administrators]"=>"1",
                ),
            ).status == 303
            @test request("POST", "/rooms/opens"; cookie = member).status == 403
            direct =
                request("POST", "/rooms/directs"; cookie, params = Dict("user_ids[]"=>"2"))
            @test direct.status == 303
            directpath = HTTP.header(direct, "Location")
            directid = parse(Int, last(split(directpath, '/')))
            @test HTTP.header(
                request(
                    "POST",
                    "/rooms/directs";
                    cookie = member,
                    params = Dict("user_ids[]"=>"1"),
                ),
                "Location",
            ) == directpath
            @test request("GET", "/rooms/opens/$directid/edit"; cookie).status == 404
            @test request(
                "PATCH",
                "/rooms/opens/$directid";
                cookie,
                params = Dict("room[name]"=>"leak"),
            ).status == 404
            @test occursin(
                "Ping with Member",
                String(request("GET", directpath; cookie).body),
            )
            @test request("GET", "/rooms/directs/2/edit"; cookie).status == 404
            autocomplete = request(
                "GET",
                "/autocompletable/users?query=Member";
                cookie,
                headers = ["Accept"=>"application/json"],
            )
            @test only(JSON3.read(autocomplete.body)).value == 2
            @test request("GET", only(JSON3.read(autocomplete.body)).avatar_url; cookie).status ==
                  200
            @test request(
                "PATCH",
                "/rooms/closeds/2";
                cookie,
                params = Dict("room[name]"=>"Private"),
            ).status == 303
            @test request("GET", "/rooms/2"; cookie = member).status == 404
            @test request("GET", "/autocompletable/users?room_id=2"; cookie = member).status ==
                  404
            @test request(
                "PATCH",
                "/rooms/opens/2";
                cookie,
                params = Dict("room[name]"=>"Public again"),
            ).status == 303
            @test request("GET", "/rooms/2"; cookie = member).status == 200
            @test request(
                "PATCH",
                "/rooms/2/involvement";
                cookie = member,
                params = Dict("involvement"=>"invalid"),
            ).status == 422
            @test request(
                "PATCH",
                "/rooms/2/involvement";
                cookie = member,
                params = Dict("involvement"=>"invisible"),
            ).status == 303
            @test !occursin(
                "room_2",
                String(request("GET", "/users/me/sidebar"; cookie = member).body),
            )
            @test request("GET", "/rooms/2/refresh?since=0"; cookie).status == 200
            @test request("GET", "/rooms/2/@1"; cookie).status == 200
            @test request("GET", "/rooms/1/@1"; cookie).status == 404
            for id = 2:100
                timestamp = "2026-10-12 12:00:$(lpad(id%60,2,'0')).$(lpad(id,3,'0'))"
                W.execute!(
                    app,
                    "INSERT INTO messages(id,room_id,creator_id,client_message_id,created_at,updated_at) VALUES(?,2,1,?,?,?)",
                    (id, string(id), timestamp, timestamp),
                )
                W.execute!(
                    app,
                    "INSERT INTO action_text_rich_texts(name,record_type,record_id,body,created_at,updated_at) VALUES('body','Message',?,'History',?,?)",
                    (id, timestamp, timestamp),
                )
            end
            refresh = String(request("GET", "/rooms/2/refresh?since=0"; cookie).body)
            @test length(collect(eachmatch(r"action=\"append\"", refresh))) == 40
            @test length(collect(eachmatch(r"action=\"replace\"", refresh))) == 40
            # Historical Rails fixtures may contain an orphaned creator. Deletion
            # still removes the room and its messages without presentation joins.
            W.execute!(app, "PRAGMA foreign_keys=OFF")
            W.execute!(
                app,
                "INSERT INTO messages(id,room_id,creator_id,client_message_id,created_at,updated_at) VALUES(101,2,9999,'orphan','2026','2026')",
            )
            W.execute!(app, "PRAGMA foreign_keys=ON")
            @test request("POST", "/rooms/2"; cookie, params = Dict("_method"=>"delete")).status ==
                  303
            @test W.scalar(app, "SELECT count(*) FROM message_search_index") == 0
            @test request("GET", "/rooms/2"; cookie).status == 404
            bot_created = request(
                "POST",
                "/account/bots";
                cookie,
                params = Dict("user[name]"=>"Robot"),
            )
            @test bot_created.status == 303
            bot = W.qone(app, "SELECT * FROM users WHERE role=2")
            app.origin = "https://chat.test"
            botpath = "/rooms/1/$(bot.id)-$(bot.bot_token)/messages"
            post = W.handle_request(
                app,
                HTTP.Request("POST", botpath, [], "HTTPS bot message"),
            )
            @test post.status == 201
            message_id = W.scalar(app, "SELECT max(id) FROM messages WHERE room_id=1")
            @test W.handle_request(
                app,
                HTTP.Request("PATCH", botpath*"/$message_id", [], "Updated HTTPS message"),
            ).status == 200
            @test W.handle_request(
                app,
                HTTP.Request("POST", botpath*"/$message_id/boosts", [], "👍"),
            ).status == 201
            @test W.handle_request(
                app,
                HTTP.Request(
                    "POST",
                    botpath,
                    ["Origin"=>"https://evil.test"],
                    "Cross-site",
                ),
            ).status == 403
            app.origin = ""
            # Exercise framing over TCP, including compressed bytes, Unicode,
            # HEAD and a bodyless response on reused HTTP connections.
            listener = listen(ip"127.0.0.1", 0)
            port = getsockname(listener)[2]
            server = W.start_server(app; server = listener)
            base = "http://127.0.0.1:$port"
            try
                @test HTTP.get(base * "/up?invalid=%ZZ"; status_exception = false).status ==
                      400
                @test HTTP.get(
                    base * "/up",
                    ["Connection" => "Upgrade", "Upgrade" => "websocket"],
                ).status == 200
                headers = ["Cookie" => cookie, "Accept-Encoding" => "gzip"]
                wire = HTTP.get(base * "/rooms/1", headers; decompress = false)
                @test parse(Int, HTTP.header(wire, "Content-Length")) == length(wire.body)
                @test HTTP.header(wire, "Transfer-Encoding") == ""
                @test HTTP.header(wire, "Content-Encoding") == "gzip"
                @test occursin(
                    "Updated HTTPS message",
                    String(transcode(GzipDecompressor, wire.body)),
                )
                head = HTTP.request("HEAD", base * "/rooms/1", headers)
                @test isempty(head.body)
                @test HTTP.header(head, "Transfer-Encoding") == ""
                empty = HTTP.post(
                    base * "/unfurl_link",
                    [
                        "Cookie" => cookie,
                        "Content-Type" => "application/x-www-form-urlencoded",
                    ],
                    "url=http%3A%2F%2F127.0.0.1%2Fprivate",
                )
                @test empty.status == 204
                @test isempty(empty.body)
                @test HTTP.header(empty, "Content-Length") == ""
                plain = HTTP.get(
                    base * "/rooms/1",
                    ["Cookie" => cookie, "Accept-Encoding" => "identity"],
                )
                @test parse(Int, HTTP.header(plain, "Content-Length")) == length(plain.body)
                @test occursin("👍", String(plain.body))
            finally
                close(server)
            end
            @test request("DELETE", "/session"; cookie).status == 302
            @test request("GET", "/rooms/1"; cookie).status == 302
        finally
            close(app)
        end
    end
end
