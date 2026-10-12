using Test, HTTP, SQLite, DBInterface, Dates
if !isdefined(@__MODULE__, :Campfire)
    include(joinpath(@__DIR__, "../julia/src/Campfire.jl"))
end

@testset "Exclusive database readers and live cache authorization" begin
    W = Campfire.Web
    mktempdir() do directory
        path = joinpath(directory, "db.sqlite3")
        app = W.WebApp(path; secret = repeat("r", 64), readers = 4)
        pool = app.readers
        timestamp = W.nowstr()
        W.execute!(
            app,
            "INSERT INTO accounts(name,join_code,created_at,updated_at) VALUES('Readers','join',?,?)",
            (timestamp, timestamp),
        )
        for id = 1:2
            W.execute!(
                app,
                "INSERT INTO users(id,name,email_address,created_at,updated_at) VALUES(?,?,?,?,?)",
                (id, "Reader $id", "$id@test.local", timestamp, timestamp),
            )
            W.execute!(
                app,
                "INSERT INTO sessions(user_id,token,last_active_at,created_at,updated_at) VALUES(?,?,?,?,?)",
                (id, "reader-$id", timestamp, timestamp, timestamp),
            )
            W.execute!(
                app,
                "INSERT INTO rooms(id,name,type,creator_id,created_at,updated_at) VALUES(?,?,'Rooms::Closed',?,?,?)",
                (id, "Private $id", id, timestamp, timestamp),
            )
            W.execute!(
                app,
                "INSERT INTO memberships(user_id,room_id,created_at,updated_at) VALUES(?,?,?,?)",
                (id, id, timestamp, timestamp),
            )
        end
        cookies =
            ["session_token=" * W.signed_token(app, "session", "reader-$id") for id = 1:2]
        request(id = 1, path = "/rooms/$id") =
            HTTP.Request("GET", path, ["Cookie" => cookies[id], "Host" => "localhost"])
        direct(reader, id = 1, path = "/rooms/$id") = W.request_response(
            reader,
            request(id, path),
            Dict{String,Any}(),
            path,
            "GET",
            W.Event[],
        )
        external = SQLite.DB(path)
        try
            @test length(pool.readers) == 4
            @test sum(r.cache_budget for r in pool.readers) == app.cache_budget
            @test sum(r.cache_entries for r in pool.readers) == 512
            @test all(r -> r.storage_lock === app.storage_lock, pool.readers)
            for reader in pool.readers
                @test W.scalar(reader, "PRAGMA query_only") == 1
                @test (@inferred W.cache_generation!(reader)) isa Int64
                identity = @inferred Union{Nothing} W.cached_identity(
                    reader,
                    "reader-1",
                    SubString("room=1", 6),
                )
                @test identity.id == 1
                @test identity.room_access
                @test_throws SQLite.SQLiteException W.execute!(reader, "DELETE FROM users")
                @test direct(reader).status == 200
                @test !isempty(reader.cache)
            end
            W.execute_db!(external, "UPDATE rooms SET name='Renamed externally' WHERE id=1")
            for reader in pool.readers
                @test occursin("Renamed externally", String(direct(reader).body))
            end
            # A snapshot can predate revocation even when its observer sees the
            # commit. An epoch change must reject the already-cached response.
            reader = first(pool.readers)
            generation = W.cache_generation!(reader)
            W.execute!(reader, "BEGIN")
            W.scalar(reader, "SELECT count(*) FROM memberships")
            W.execute_db!(external, "DELETE FROM memberships WHERE user_id=1")
            @test W.cached_page(reader, request(), "/rooms/1", generation) === nothing
            W.execute!(reader, "ROLLBACK")
            for reader in pool.readers
                @test direct(reader).status == 404
            end
            W.execute_db!(
                external,
                "INSERT INTO memberships(user_id,room_id,created_at,updated_at) VALUES(1,1,?,?)",
                (timestamp, timestamp),
            )
            for reader in pool.readers
                @test direct(reader).status == 200
            end
            W.execute_db!(external, "UPDATE users SET status=1 WHERE id=1")
            for reader in pool.readers
                @test direct(reader).status == 302
            end
            W.execute_db!(external, "UPDATE users SET status=0 WHERE id=1")
            W.execute_db!(
                external,
                "UPDATE sessions SET last_active_at='2000-01-01 00:00:00' WHERE user_id=1",
            )
            @test W.handle_request(app, request()).status == 200
            @test startswith(
                W.scalar(app, "SELECT last_active_at FROM sessions WHERE user_id=1"),
                string(year(now())),
            )
            @test all(r -> W.scalar(r, "PRAGMA query_only") == 1, pool.readers)
            # Simultaneous users must never receive another user's cached room.
            tasks = [
                Threads.@spawn begin
                    id = isodd(index) ? 1 : 2
                    allowed = W.handle_request(app, request(id))
                    denied = W.handle_request(app, request(id, "/rooms/$(3-id)"))
                    return (allowed.status, denied.status, String(allowed.body))
                end for index = 1:40
            ]
            for (index, task) in enumerate(tasks)
                status, denied, body = fetch(task)
                @test status == 200
                @test denied == 404
                @test occursin(isodd(index) ? "Renamed externally" : "Private 2", body)
            end
            @test sum(r.cache_bytes for r in pool.readers) <= app.cache_budget
            @test sum(length(r.cache) for r in pool.readers) <= 512
            @test W.handle_request(app, request(1, "/rooms/999999")).status == 404
            @test W.handle_request(
                app,
                request(1, "/rooms/99999999999999999999999999999999999"),
            ).status in (404, 422)
            @test W.handle_request(app, request()).status == 200
            @test_throws ErrorException W.with_reader(app) do _
                error("lease callback failed")
            end
            @test pool.active == 0
            @test length(pool.available) == 4
            for reader in pool.readers
                # Starting a new transaction detects any leaked prior BEGIN.
                W.execute!(reader, "BEGIN")
                W.execute!(reader, "ROLLBACK")
            end
            for reader in pool.readers
                @test direct(reader).status == 200
            end
            W.execute_db!(external, "DELETE FROM sessions WHERE user_id=1")
            for reader in pool.readers
                @test direct(reader).status == 302
            end
        finally
            SQLite.close(external)
        end
        # Shutdown waits for a leased reader and rejects all new leases. The
        # writer remains usable for deferred session effects until release.
        entered = Channel{Nothing}(1)
        release = Channel{Nothing}(1)
        borrowed = Threads.@spawn W.with_reader(app) do reader
            put!(entered, nothing)
            take!(release)
            @test W.scalar(reader, "SELECT count(*) FROM users") == 2
            lock(app.lock) do
                W.execute!(app, "UPDATE sessions SET last_active_at=?", (timestamp,))
            end
        end
        take!(entered)
        closing = Threads.@spawn close(app)
        @test timedwait(() -> lock(() -> pool.closing, pool.condition), 5) == :ok
        @test !istaskdone(closing)
        @test W.handle_request(app, request()).status == 503
        put!(release, nothing)
        fetch(borrowed)
        fetch(closing)
        @test pool.active == 0
    end
end
