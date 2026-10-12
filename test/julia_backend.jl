using Test, HTTP, SQLite, DBInterface, Sockets

if !isdefined(@__MODULE__, :Campfire)
    include("../julia/src/Campfire.jl")
end
using .Campfire

bodytext(result) = String(copy(result.body))
message_ids(result) =
    [parse(Int, m[1]) for m in eachmatch(r"data-message-id=\"(\d+)\"", bodytext(result))]

function request_for(token, path; method = "GET", body = "", content_type = "text/plain")
    return HTTP.Request(
        method,
        path,
        ["Authorization" => "Bearer $token", "Content-Type" => content_type],
        body,
    )
end

function dbvalue(db, sql)
    rows = DBInterface.execute(db, sql)
    try
        for row in rows
            return row[1]
        end
        return nothing
    finally
        DBInterface.close!(rows)
    end
end

@testset "Julia SQLite backend experiment" begin
    mktempdir() do directory
        path = joinpath(directory, "campfire.sqlite3")
        token = seed!(path)
        @test_throws ArgumentError seed!(path)
        @test_throws ArgumentError Store(joinpath(directory, "missing"))
        @test_throws ArgumentError Store(path; cache_budget = -1)
        store = Store(path)
        writer = SQLite.DB(path)
        try
            getpage(path) = handle(store, request_for(token, path))
            @test handle(store, HTTP.Request("GET", "/rooms/1")).status == 401
            @test handle(store, request_for("wrong", "/rooms/1")).status == 401
            @test handle(store, request_for("", "/rooms/1")).status == 401
            @test getpage("/up").status == 200
            @test getpage("/unknown").status == 404
            @test getpage("/rooms/999999999999999999999999").status == 404
            @test getpage("/rooms/2").status == 404
            @test getpage("/rooms/1/messages?before=bad").status == 400
            @test getpage("/" * repeat("x", 2048)).status == 414
            @test handle(store, request_for(token, "/rooms/1"; method = "DELETE")).status ==
                  405

            page = getpage("/rooms/1")
            @test page.status == 200
            @test message_ids(page) == collect(81:120)
            @test startswith(bodytext(page), "<!DOCTYPE html>")
            @test endswith(bodytext(page), "</html>")
            @test occursin("Julia &amp; &lt;friends&gt; — ☕", bodytext(page))
            @test HTTP.header(page, "Content-Type") == "text/html; charset=utf-8"
            @test message_ids(getpage("/rooms/1/messages?before=60")) == collect(20:59)
            @test message_ids(getpage("/rooms/1/messages")) == collect(81:120)
            @test isempty(message_ids(getpage("/rooms/1/messages?before=1")))
            @test message_ids(getpage("/searches?q=coffee")) == collect(21:120)
            @test isempty(message_ids(getpage("/searches?q=AND")))
            @test isempty(message_ids(getpage("/searches?q=%22")))
            @test isempty(message_ids(getpage("/searches?q=")))
            sidebar = bodytext(getpage("/users/me/sidebar"))
            @test occursin("shared_rooms", sidebar)
            @test occursin("Watercooler", sidebar)
            @test !occursin("Private", sidebar)

            # Cache hits share immutable bytes; every hit still authenticates.
            @test getpage("/rooms/1").body === page.body
            Campfire.execute!(writer, "UPDATE users SET status = 1 WHERE id = 1")
            @test getpage("/rooms/1").status == 401
            Campfire.execute!(writer, "UPDATE users SET status = 0 WHERE id = 1")
            @test getpage("/rooms/1").status == 200
            Campfire.execute!(writer, "DELETE FROM memberships WHERE user_id = 1")
            @test getpage("/rooms/1").status == 404
            @test isempty(message_ids(getpage("/searches?q=coffee")))
            Campfire.execute!(
                writer,
                "INSERT INTO memberships(user_id,room_id) VALUES (1,1)",
            )
            page = getpage("/rooms/1")
            Campfire.execute!(
                writer,
                "UPDATE message_search_index SET body = 'fresh external edit' WHERE rowid = 120",
            )
            changed = getpage("/rooms/1")
            @test changed.body !== page.body
            @test occursin("fresh external edit", bodytext(changed))

            post(body; kwargs...) = handle(
                store,
                request_for(token, "/rooms/1/messages"; method = "POST", body, kwargs...),
            )
            @test post(" ").status == 422
            @test post("{}"; content_type = "application/json").status == 415
            @test post("invalid media type"; content_type = "text/plaintext").status == 415
            @test post(repeat("x", 65537)).status == 413
            @test post(UInt8[0xff]).status == 400
            @test handle(
                store,
                request_for(token, "/rooms/2/messages"; method = "POST", body = "secret"),
            ).status == 404
            saved = post("fresh coffee <script>& '☕'")
            @test saved.status == 201
            id = parse(Int, bodytext(saved))
            @test id == 121
            @test HTTP.header(saved, "Location") == "/rooms/1/messages#message_121"
            @test dbvalue(
                writer,
                "SELECT body FROM message_search_index WHERE rowid = $id",
            ) == "fresh coffee <script>& '☕'"
            @test dbvalue(
                writer,
                "SELECT body FROM action_text_rich_texts WHERE record_id = $id",
            ) == "fresh coffee &lt;script&gt;&amp; &#39;☕&#39;"
            @test dbvalue(writer, "SELECT messages_count FROM rooms WHERE id = 1") == 121
            @test !isnothing(
                dbvalue(
                    writer,
                    "SELECT unread_at FROM memberships WHERE user_id = 2 AND room_id = 1",
                ),
            )
            @test last(message_ids(getpage("/rooms/1"))) == id
            @test last(message_ids(getpage("/searches?q=fresh"))) == id

            # A late write failure must roll back messages, FTS, and counts.
            Campfire.execute!(
                writer,
                """
CREATE TRIGGER reject_rich_text BEFORE INSERT ON action_text_rich_texts
BEGIN SELECT RAISE(ABORT, 'test failure'); END
""",
            )
            @test_throws SQLite.SQLiteException post("rolled back")
            @test dbvalue(writer, "SELECT count(*) FROM messages") == 121
            @test dbvalue(writer, "SELECT count(*) FROM message_search_index") == 121
            @test dbvalue(writer, "SELECT messages_count FROM rooms WHERE id = 1") == 121
            Campfire.execute!(writer, "DROP TRIGGER reject_rich_text")
            @test getpage("/rooms/1").status == 200

            # The cache payload budget and entry count stay bounded.
            store.cache_budget = 1
            Campfire.invalidate!(store)
            getpage("/rooms/1")
            @test isempty(store.cache)
            store.cache_budget = 1024^2
            for i = 1:520
                getpage("/searches?q=absent$i")
            end
            @test length(store.cache) <= 512
            @test store.cache_bytes <= store.cache_budget

            Campfire.execute!(writer, "DELETE FROM sessions")
            @test getpage("/rooms/1").status == 401
        finally
            close(store)
            SQLite.close(writer)
        end
    end
end

@testset "Real HTTP round trip" begin
    mktempdir() do directory
        path = joinpath(directory, "http.sqlite3")
        token = seed!(path; messages = 5)
        store = Store(path)
        listener = Sockets.listen(ip"127.0.0.1", 0)
        port = Sockets.getsockname(listener)[2]
        server = serve(store; port, server = listener)
        try
            url = "http://127.0.0.1:$port"
            headers = ["Authorization" => "Bearer $token"]
            for route in
                ("/rooms/1", "/rooms/1/messages", "/users/me/sidebar", "/searches?q=coffee")
                result = HTTP.get(url * route, headers)
                @test result.status == 200
                @test !isempty(result.body)
            end
            result = HTTP.post(
                url * "/rooms/1/messages",
                [headers; "Content-Type" => "text/plain"],
                "network coffee",
            )
            @test result.status == 201
            @test last(message_ids(HTTP.get(url * "/rooms/1", headers))) == 6
            @test HTTP.get(url * "/rooms/2", headers; status_exception = false).status ==
                  404
        finally
            close(server)
            close(store)
        end
    end
end

# Load the executable entry point too, without starting a listener.
include("../julia/server.jl")
