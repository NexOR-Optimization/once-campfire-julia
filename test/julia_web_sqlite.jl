using Test, SQLite, DBInterface
if !isdefined(@__MODULE__, :Campfire)
    include(joinpath(@__DIR__, "../julia/src/Campfire.jl"))
end

@testset "Explicit SQLite writer durability" begin
    W = Campfire.Web
    mktempdir() do directory
        path = joinpath(directory, "durability.sqlite3")
        for (mode, expected) in (("FULL", 2), ("NORMAL", 1))
            app = W.WebApp(path; secret = repeat("s", 64), readers = 0, synchronous = mode)
            try
                @test W.scalar(app, "PRAGMA synchronous") == expected
                @test W.scalar(app, "PRAGMA journal_mode") == "wal"
            finally
                close(app)
            end
        end
        for (mode, expected) in ((nothing, 2), ("NORMAL", 1))
            withenv("DATABASE_SYNCHRONOUS" => mode) do
                app = W.WebApp(path; secret = repeat("s", 64), readers = 0)
                try
                    @test W.scalar(app, "PRAGMA synchronous") == expected
                finally
                    close(app)
                end
            end
        end
        invalid_path = joinpath(directory, "invalid.sqlite3")
        @test_throws ArgumentError W.WebApp(invalid_path; synchronous = "OFF")
        @test !ispath(invalid_path)
    end
end

@testset "Prepared SQLite operations preserve bindings and recovery" begin
    W = Campfire.Web
    mktempdir() do directory
        app = W.WebApp(
            joinpath(directory, "db.sqlite3");
            secret = repeat("s", 64),
            readers = 0,
        )
        external = SQLite.DB(joinpath(directory, "db.sqlite3"))
        try
            W.execute!(
                app,
                "CREATE TABLE operation_test (id INTEGER PRIMARY KEY, text_value TEXT, data BLOB, nullable INTEGER)",
            )
            text = "Julia\0éλ"
            blob = UInt8[0x00, 0x80, 0xff]
            insert = "INSERT INTO operation_test VALUES(?,?,?,?)"
            W.execute!(app, insert, (1, text, blob, nothing))
            row = W.qone(app, "SELECT * FROM operation_test WHERE id=1")
            # Check stored bytes directly; SQLite.jl's generic text decoder
            # treats the embedded NUL as a string terminator.
            @test W.scalar(app, "SELECT hex(text_value) FROM operation_test WHERE id=1") ==
                  uppercase(bytes2hex(codeunits(text)))
            @test row.data == blob
            @test ismissing(row.nullable)
            @test_throws SQLite.SQLiteException W.execute!(
                app,
                insert,
                (1, "duplicate", blob, 2),
            )
            W.execute!(app, insert, (2, "recovered", UInt8[], 3))
            @test W.scalar(app, "SELECT count(*) FROM operation_test") == 2
            @test_throws SQLite.SQLiteException W.execute!(app, insert, (3,))
            W.execute!(app, insert, (3, "all bindings replaced", blob, missing))
            @test W.scalar(app, "SELECT text_value FROM operation_test WHERE id=3") ==
                  "all bindings replaced"

            # Parameterless commands reuse statements without constructing rows.
            W.execute!(app, "BEGIN")
            W.execute!(app, "DELETE FROM operation_test")
            W.execute!(app, "ROLLBACK")
            @test W.scalar(app, "SELECT count(*) FROM operation_test") == 3
            W.execute!(app, "BEGIN")
            W.execute!(app, "DELETE FROM operation_test WHERE id=3")
            W.execute!(app, "COMMIT")
            @test W.scalar(app, "SELECT count(*) FROM operation_test") == 2
            failed_sql = "INSERT INTO operation_test(id) VALUES(1)"
            @test_throws SQLite.SQLiteException W.execute!(app, failed_sql)
            W.execute!(app, "DELETE FROM operation_test WHERE id=1")
            W.execute!(app, failed_sql)
            @test W.scalar(app, "SELECT count(*) FROM operation_test") == 2

            statement = W.prepared_statement(app, "SELECT ?")
            read_text(handle, status) = begin
                @test status == SQLite.C.SQLITE_ROW
                return unsafe_string(
                    SQLite.C.sqlite3_column_text(handle, 0),
                    SQLite.C.sqlite3_column_bytes(handle, 0),
                )
            end
            for value in (text, SubString("prefix-λ", 8), "", LazyString("lazy", "λ"))
                @test W.with_statement(read_text, statement, (value,)) == value
            end
            read_integer(handle, status) = begin
                @test status == SQLite.C.SQLITE_ROW
                @test SQLite.C.sqlite3_column_type(handle, 0) == SQLite.C.SQLITE_INTEGER
                return SQLite.C.sqlite3_column_int64(handle, 0)
            end
            for value in
                (Int64(0), Int64(-1), Int64(2)^53 + 1, typemin(Int64), typemax(Int64))
                @test (@inferred W.with_statement(read_integer, statement, (value,))) ==
                      value
            end
            @test_throws SQLite.SQLiteException W.with_statement(
                read_integer,
                statement,
                (Int64(1), Int64(2)),
            )
            @test_throws ErrorException W.with_statement(
                statement,
                (typemin(Int64),),
            ) do _, _
                error("integer callback failed")
            end
            # Error cleanup must clear the old integer, not only reset the VM.
            handle = W.statement_handle(statement)
            try
                @test SQLite.C.sqlite3_step(handle) == SQLite.C.SQLITE_ROW
                @test SQLite.C.sqlite3_column_type(handle, 0) == SQLite.C.SQLITE_NULL
            finally
                SQLite.C.sqlite3_reset(handle)
            end
            @test W.with_statement(read_integer, statement, (typemax(Int64),)) ==
                  typemax(Int64)

            mixed = W.prepared_statement(app, "SELECT ?, ?, ?")
            read_mixed(handle, status) = begin
                @test status == SQLite.C.SQLITE_ROW
                return (
                    SQLite.C.sqlite3_column_int64(handle, 0),
                    unsafe_string(
                        SQLite.C.sqlite3_column_text(handle, 1),
                        SQLite.C.sqlite3_column_bytes(handle, 1),
                    ),
                    SQLite.C.sqlite3_column_int64(handle, 2),
                )
            end
            @test W.with_statement(
                read_mixed,
                mixed,
                (typemin(Int64), SubString("prefix" * text, 7), typemax(Int64)),
            ) == (typemin(Int64), text, typemax(Int64))
            @test W.with_statement(
                mixed,
                (Int64(4), LazyString("temporary", "λ"), Int64(-4)),
            ) do handle, status
                GC.gc()
                read_mixed(handle, status) == (4, "temporaryλ", -4)
            end
            integer_insert = W.prepared_statement(
                app,
                "INSERT INTO operation_test(id,text_value) VALUES(?,?)",
            )
            @test_throws SQLite.SQLiteException W.with_statement(
                (args...) -> nothing,
                integer_insert,
                (Int64(1), "duplicate"),
            )
            @test W.with_statement(
                integer_insert,
                (Int64(5), "recovered integer"),
            ) do _, status
                status == SQLite.C.SQLITE_DONE
            end
            @test W.scalar(app, "SELECT text_value FROM operation_test WHERE id=5") ==
                  "recovered integer"
            W.execute!(app, "DELETE FROM operation_test WHERE id=5")
            @test_throws SQLite.SQLiteException W.with_statement(read_text, statement)
            @test_throws ErrorException W.with_statement(
                statement,
                ("callback error",),
            ) do _, _
                error("callback failed")
            end
            @test W.with_statement(read_text, statement, ("after errors",)) ==
                  "after errors"
            limit = SQLite.C.sqlite3_limit(app.db.handle, SQLite.C.SQLITE_LIMIT_LENGTH, 10)
            try
                @test_throws SQLite.SQLiteException W.with_statement(
                    read_text,
                    statement,
                    (repeat("x", 1000),),
                )
                @test_throws SQLite.SQLiteException W.with_statement(
                    read_mixed,
                    mixed,
                    (typemin(Int64), repeat("x", 1000), typemax(Int64)),
                )
            finally
                SQLite.C.sqlite3_limit(app.db.handle, SQLite.C.SQLITE_LIMIT_LENGTH, limit)
            end
            @test W.with_statement(read_text, statement, ("after bind error",)) ==
                  "after bind error"
            @test W.with_statement(
                read_mixed,
                mixed,
                (Int64(7), "after bind error", Int64(8)),
            ) == (7, "after bind error", 8)
            # The native copy of a temporary string must survive Julia collection.
            @test W.with_statement(statement, (join(["temporary", "λ"]),)) do handle, status
                GC.gc()
                read_text(handle, status) == "temporaryλ"
            end
            @test W.with_statement(
                W.prepared_statement(app, "SELECT 1 WHERE 0"),
            ) do _, status
                status == SQLite.C.SQLITE_DONE
            end
            DBInterface.close!(statement)
            @test_throws SQLite.SQLiteException W.with_statement(
                read_text,
                statement,
                ("closed",),
            )
            @test_throws SQLite.SQLiteException W.with_statement(
                read_integer,
                statement,
                (Int64(0),),
            )

            before = @inferred W.cache_generation!(app)
            W.execute_db!(external, "INSERT INTO operation_test(id) VALUES(4)")
            after = @inferred W.cache_generation!(app)
            @test after != before
            @test (@inferred W.cache_generation!(app)) == after
        finally
            SQLite.close(external)
            close(app)
        end
    end
end

@testset "Fixed-schema authorization keeps live permissions" begin
    W = Campfire.Web
    mktempdir() do directory
        app = W.WebApp(
            joinpath(directory, "db.sqlite3");
            secret = repeat("s", 64),
            readers = 0,
        )
        try
            timestamp = W.nowstr()
            W.execute!(
                app,
                "INSERT INTO users(id,name,email_address,created_at,updated_at) VALUES(1,'Reader','reader@test.local',?,?)",
                (timestamp, timestamp),
            )
            token = "session\0λ"
            W.execute!(
                app,
                "INSERT INTO sessions(user_id,token,last_active_at,created_at,updated_at) VALUES(1,?,?,?,?)",
                (token, timestamp, timestamp, timestamp),
            )
            W.execute!(
                app,
                "INSERT INTO rooms(id,name,type,creator_id,created_at,updated_at) VALUES(1,'Room','Rooms::Closed',1,?,?)",
                (timestamp, timestamp),
            )
            W.execute!(
                app,
                "INSERT INTO memberships(user_id,room_id,created_at,updated_at) VALUES(1,1,?,?)",
                (timestamp, timestamp),
            )
            identity = @inferred Union{Nothing} W.cached_identity(app, token, "1")
            @test identity.id == 1
            @test identity.room_access
            @test !identity.refresh_due
            @test (@inferred Union{Nothing} W.cached_identity(app, token)).room_access
            @test (@inferred Union{Nothing} W.cached_identity(
                app,
                token,
                SubString("room=1", 6),
            )).room_access
            @test W.cached_identity(app, "wrong", "1") === nothing
            @test !W.cached_identity(app, token, "999999999999999999999999999999999999").room_access
            @test !W.cached_identity(app, token, "1 OR 1=1").room_access
            W.execute!(app, "DELETE FROM memberships")
            @test !W.cached_identity(app, token, "1").room_access
            W.execute!(app, "UPDATE sessions SET last_active_at='2000-01-01 00:00:00'")
            @test W.cached_identity(app, token).refresh_due
            W.execute!(app, "UPDATE sessions SET last_active_at='invalid datetime'")
            @test !W.cached_identity(app, token).refresh_due
            W.execute!(app, "UPDATE users SET status=1")
            @test W.cached_identity(app, token) === nothing
            W.execute!(app, "UPDATE users SET status=0,role=2")
            @test W.cached_identity(app, token) === nothing
            W.execute!(app, "UPDATE users SET role=0")
            @test W.cached_identity(app, token) !== nothing
            W.execute!(app, "DELETE FROM sessions")
            @test W.cached_identity(app, token) === nothing
        finally
            close(app)
        end
    end
end
