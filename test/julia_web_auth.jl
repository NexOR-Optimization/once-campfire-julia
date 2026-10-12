using Test, HTTP, SQLite, DBInterface, SHA, JSON3

if !isdefined(@__MODULE__, :Campfire)
    include("../julia/src/Campfire.jl")
end
if !isdefined(Campfire, :Web)
    Base.include(Campfire, joinpath(@__DIR__, "../julia/src/Web.jl"))
end

const AuthWeb = Campfire.Web

function auth_test_request(
    app,
    method,
    path;
    cookie = "",
    params = Pair{String,String}[],
    ip = "198.51.100.1",
    headers = Pair{String,String}[],
)
    body = join(
        (
            HTTP.escapeuri(string(key)) * "=" * HTTP.escapeuri(string(value)) for
            (key, value) in params
        ),
        '&',
    )
    request = HTTP.Request(
        method,
        path,
        [
            "Host" => "campfire.test",
            "Cookie" => cookie,
            "Content-Type" => "application/x-www-form-urlencoded",
            "Sec-Fetch-Site" => "same-origin",
            headers...,
        ],
        body,
    )
    request.context[:client_ip] = ip
    return AuthWeb.handle_request(app, request)
end

auth_cookie(response) = String(first(split(HTTP.header(response, "Set-Cookie"), ';')))
auth_body(response) = String(copy(response.body))

@testset "Julia web authentication and accounts" begin
    mktempdir() do directory
        app = AuthWeb.WebApp(
            joinpath(directory, "test.sqlite3");
            secret = "julia-rails-compatibility-test-secret",
        )
        try
            @testset "bcrypt, signatures, Rails compatibility and QR" begin
                digest = AuthWeb.password_digest("a password ☕"; cost = 4)
                @test startswith(digest, raw"$2b$04$")
                @test AuthWeb.password_matches("a password ☕", digest)
                @test !AuthWeb.password_matches("wrong", digest)
                @test !AuthWeb.password_matches("", digest)
                @test !AuthWeb.password_matches("password", missing)
                @test !AuthWeb.password_matches("password", "not a bcrypt digest")
                @test !AuthWeb.password_matches("nul\0password", digest)
                @test_throws ArgumentError AuthWeb.password_digest(""; cost = 4)
                @test_throws ArgumentError AuthWeb.password_digest(
                    repeat("a", 73);
                    cost = 4,
                )
                @test_throws ArgumentError AuthWeb.password_digest(
                    repeat("☕", 25);
                    cost = 4,
                )
                @test_throws ArgumentError AuthWeb.password_digest(
                    "nul\0password";
                    cost = 4,
                )
                @test_throws ArgumentError AuthWeb.password_digest("password"; cost = 3)
                @test AuthWeb.password_digest("a password ☕"; cost = 4) != digest
                token = AuthWeb.signed_token(app, "purpose", "payload ☕")
                @test AuthWeb.verify_token(app, "purpose", token) == "payload ☕"
                @test AuthWeb.verify_token(app, "different-purpose", token) === nothing
                @test AuthWeb.verify_token(app, "purpose", token * "0") === nothing
                @test AuthWeb.verify_token(app, "purpose", "bad") === nothing
                @test AuthWeb.verify_token(app, "purpose", repeat("a", 8193)) === nothing
                @test AuthWeb.verify_token(app, "purpose", nothing) === nothing
                # RFC 4231 case 2 fixes the algorithm independently of either
                # token implementation; the following vectors cover binary
                # inputs and SHA-256's HMAC key-length boundary.
                @test bytes2hex(
                    AuthWeb.token_hmac("Jefe", "what do ya want for nothing?"),
                ) == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
                for secret in ("", "key\0value", repeat("k", 64), repeat("k", 131))
                    @test AuthWeb.token_hmac(secret, "message\0☕") == hmac_sha256(
                        Vector{UInt8}(codeunits(secret)),
                        codeunits("message\0☕"),
                    )
                end
                # Tokens signed before the optimization must remain byte-for-
                # byte compatible, including every Base64 tail length.
                for value in ("", "a", "ab", "abc", "abcd", "payload ☕", "\0", "\uffff")
                    payload = AuthWeb.urlbase64(value)
                    signature = bytes2hex(
                        hmac_sha256(
                            Vector{UInt8}(codeunits(app.secret)),
                            codeunits("purpose:" * payload),
                        ),
                    )
                    legacy_native = payload * "." * signature
                    @test AuthWeb.signed_token(app, "purpose", value) == legacy_native
                    @test AuthWeb.verify_token(app, "purpose", legacy_native) == value
                    @test all(eachindex(signature)) do index
                        changed = collect(codeunits(signature))
                        changed[index] =
                            changed[index] == UInt8('0') ? UInt8('1') : UInt8('0')
                        return AuthWeb.verify_token(
                            app,
                            "purpose",
                            payload * "." * String(changed),
                        ) === nothing
                    end
                end
                # Even an authentic digest cannot make malformed Base64URL or
                # invalid UTF-8 into an accepted native token.
                for payload in ("A", "AA=", "A!", "AB", "AAF", "_w", "é", "a.a")
                    signature = bytes2hex(
                        hmac_sha256(
                            Vector{UInt8}(codeunits(app.secret)),
                            codeunits("purpose:" * payload),
                        ),
                    )
                    @test AuthWeb.verify_token(
                        app,
                        "purpose",
                        payload * "." * signature,
                    ) === nothing
                end
                @test AuthWeb.verify_token(app, "purpose", ".") === nothing
                @test !AuthWeb.secure_equal_hex("", zeros(UInt8, 32))
                boundary_value = repeat("x", 6095)
                boundary_token = AuthWeb.signed_token(app, "purpose", boundary_value)
                @test ncodeunits(boundary_token) == 8192
                @test AuthWeb.verify_token(app, "purpose", boundary_token) == boundary_value
                @test AuthWeb.verify_token(
                    app,
                    "purpose",
                    AuthWeb.signed_token(app, "purpose", boundary_value * "x"),
                ) === nothing
                token_tasks = map(1:16) do task_index
                    Threads.@spawn begin
                        local_app = (secret = "concurrent token key $task_index",)
                        all(1:20) do index
                            value = "token $task_index/$index ☕"
                            signed = AuthWeb.signed_token(local_app, "parallel", value)
                            AuthWeb.verify_token(local_app, "parallel", signed) == value
                        end
                    end
                end
                @test all(fetch, token_tasks)
                @test AuthWeb.secure_equal("equal", "equal")
                @test !AuthWeb.secure_equal("equal", "equaL")
                @test !AuthWeb.secure_equal("equal", "shorter")
                # Generated independently by Ruby ActiveSupport::KeyGenerator
                # and MessageVerifier, not by the implementation under test.
                rails_avatar = "eyJfcmFpbHMiOnsibWVzc2FnZSI6Ik5EST0iLCJleHAiOm51bGwsInB1ciI6InVzZXIvYXZhdGFyIn19--72971dd6a72375ed71f5568e25aab67b1f4f6116034e4214e184b6a89ab869c3"
                @test AuthWeb.verify_rails_signed_id(app, "avatar", rails_avatar) == 42
                @test AuthWeb.verify_rails_signed_id(app, "transfer", rails_avatar) ===
                      nothing
                @test AuthWeb.verify_rails_signed_id(app, "avatar", rails_avatar * "0") ===
                      nothing
                @test bytes2hex(
                    AuthWeb.rails_signing_key(app, "active_record/signed_id"),
                ) ==
                      "d1a2ab64a458b03af6f464361d3d1366c7c8bec636333eb0753014d267d05af70c4885f4baae4588df9d0946993fabec8a3f1e3321b4338aa544dc2c2ecf9b72"
                svg = AuthWeb.qr_svg("https://example.test/transfer")
                @test startswith(svg, "<svg")
                @test endswith(svg, "</svg>")
                @test occursin("shape-rendering=\"crispEdges\"", svg)
                @test occursin(r"width=\"\d+\"", svg)
                @test_throws ArgumentError AuthWeb.qr_svg("")
                @test_throws ArgumentError AuthWeb.qr_svg("\0")
                @test_throws ArgumentError AuthWeb.qr_svg(repeat("x", 2049))
            end

            @testset "cookie parsing" begin
                cookie_request(value) = HTTP.Request("GET", "/", ["Cookie" => value])
                for header in (
                    "session_token=first",
                    "theme=light; session_token=first; ui=full",
                    "; ; ignored; session_token=first; session_token=second",
                    " session_token=first  ",
                )
                    @test AuthWeb.request_cookie(cookie_request(header), "session_token") ==
                          "first"
                end
                @test AuthWeb.request_cookie(
                    cookie_request("session_token=hello%20world%3D%2B"),
                    "session_token",
                ) == "hello world=+"
                @test AuthWeb.request_cookie(
                    cookie_request("session_token=a=b+"),
                    "session_token",
                ) == "a=b+"
                @test AuthWeb.request_cookie(
                    cookie_request("session_token="),
                    "session_token",
                ) == ""
                @test AuthWeb.request_cookie(
                    cookie_request("session_token_extra=wrong"),
                    "session_token",
                ) == ""
                @test AuthWeb.request_cookie(HTTP.Request("GET", "/"), "session_token") ==
                      ""
            end

            @test auth_test_request(app, "GET", "/session/new").status == 302
            @test auth_test_request(app, "GET", "/first_run").status == 200
            invalid_setup = auth_test_request(
                app,
                "POST",
                "/first_run";
                params = [
                    "user[name]" => "Admin",
                    "user[email_address]" => "admin@test",
                    "user[password]" => "",
                ],
            )
            @test invalid_setup.status == 422
            @test AuthWeb.scalar(app, "SELECT count(*) FROM accounts") == 0
            @test AuthWeb.scalar(app, "SELECT count(*) FROM users") == 0
            setup = auth_test_request(
                app,
                "POST",
                "/first_run";
                params = [
                    "user[name]" => "Admin <name>",
                    "user[email_address]" => "admin@test",
                    "user[password]" => "a secure test password",
                ],
            )
            @test setup.status == 302
            admin = auth_cookie(setup)
            @test occursin("HttpOnly", HTTP.header(setup, "Set-Cookie"))
            @test occursin("SameSite=Lax", HTTP.header(setup, "Set-Cookie"))
            @test AuthWeb.scalar(app, "SELECT role FROM users WHERE id = 1") == 1
            @test AuthWeb.scalar(app, "SELECT count(*) FROM accounts") == 1
            @test AuthWeb.scalar(app, "SELECT name FROM rooms WHERE id = 1") == "All Talk"
            @test AuthWeb.scalar(
                app,
                "SELECT count(*) FROM memberships WHERE user_id = 1",
            ) == 1
            @testset "fresh typed cache identity" begin
                request = HTTP.Request("GET", "/", ["Cookie" => admin])
                token = AuthWeb.session_token(app, request)
                identity = AuthWeb.cached_identity(app, token)
                @test identity == (
                    id = Int64(1),
                    session_id = Int64(
                        AuthWeb.scalar(
                            app,
                            "SELECT id FROM sessions WHERE token=?",
                            (token,),
                        ),
                    ),
                    refresh_due = false,
                    room_access = true,
                )
                @test AuthWeb.cached_identity(app, token, "1") == identity
                @test AuthWeb.cached_identity(app, "unknown session") === nothing
                @test !AuthWeb.cached_identity(app, token, "999999").room_access
                @test !AuthWeb.cached_identity(app, token, "not a room").room_access
                AuthWeb.execute!(app, "BEGIN")
                try
                    AuthWeb.execute!(
                        app,
                        "DELETE FROM memberships WHERE user_id=1 AND room_id=1",
                    )
                    revoked = AuthWeb.cached_identity(app, token, "1")
                    @test revoked.id == 1
                    @test !revoked.room_access
                    @test AuthWeb.cached_identity(app, token).room_access
                    AuthWeb.execute!(
                        app,
                        "UPDATE sessions SET last_active_at='2000-01-01 00:00:00' WHERE token=?",
                        (token,),
                    )
                    revoked = AuthWeb.cached_identity(app, token, "1")
                    @test revoked.refresh_due
                    AuthWeb.mark_session_activity!(request, revoked)
                    @test request.context[:session_activity] == identity.session_id
                    AuthWeb.execute!(
                        app,
                        "UPDATE sessions SET last_active_at='not a timestamp' WHERE token=?",
                        (token,),
                    )
                    @test !AuthWeb.cached_identity(app, token).refresh_due
                    AuthWeb.execute!(app, "UPDATE users SET status=1 WHERE id=1")
                    @test AuthWeb.cached_identity(app, token) === nothing
                    AuthWeb.execute!(app, "UPDATE users SET status=0,role=2 WHERE id=1")
                    @test AuthWeb.cached_identity(app, token, "1") === nothing
                    AuthWeb.execute!(app, "UPDATE users SET role=1 WHERE id=1")
                    AuthWeb.execute!(app, "DELETE FROM sessions WHERE token=?", (token,))
                    @test AuthWeb.cached_identity(app, token) === nothing
                finally
                    AuthWeb.execute!(app, "ROLLBACK")
                end
                @test AuthWeb.cached_identity(app, token, "1") == identity
            end
            @test auth_test_request(
                app,
                "POST",
                "/first_run";
                params = ["user[name]" => "repeat"],
            ).status == 302
            @test AuthWeb.scalar(app, "SELECT count(*) FROM users") == 1
            @test auth_test_request(
                app,
                "GET",
                "/users/me/profile";
                cookie = admin * "0",
            ).status == 302
            profile = auth_test_request(app, "GET", "/users/me/profile"; cookie = admin)
            @test profile.status == 200
            @test !occursin("Admin <name>", auth_body(profile))
            @test occursin("Admin &lt;name&gt;", auth_body(profile))

            transfer_match = match(
                r"id=\"session_transfer_url\"[^>]*value=\"([^\"]+)\"|value=\"([^\"]+)\"[^>]*id=\"session_transfer_url\"",
                auth_body(profile),
            )
            @test transfer_match !== nothing
            transfer = something(transfer_match[1], transfer_match[2])
            transfer_path = replace(transfer, "http://campfire.test" => "")
            transfer_token = last(split(transfer, '/'))
            @test AuthWeb.transfer_user(app, transfer_token).id == 1
            @test AuthWeb.transfer_user(
                app,
                transfer_token;
                at = floor(Int, time()) + 5 * 3600,
            ) === nothing
            @test AuthWeb.transfer_user(app, transfer_token * "0") === nothing
            transfer_get = auth_test_request(app, "GET", transfer_path)
            @test transfer_get.status == 200
            @test occursin("auto-submit", auth_body(transfer_get))
            @test occursin("</form>", auth_body(transfer_get))
            @test AuthWeb.scalar(app, "SELECT count(*) FROM sessions") == 1
            transfer_login =
                auth_test_request(app, "PUT", transfer_path; ip = "198.51.100.2")
            @test transfer_login.status == 302
            @test AuthWeb.scalar(app, "SELECT count(*) FROM sessions") == 2
            @test auth_test_request(app, "PUT", transfer_path * "0").status == 400
            qr = auth_test_request(app, "GET", AuthWeb.qr_url(transfer))
            @test qr.status == 200
            @test HTTP.header(qr, "Content-Type") == "image/svg+xml"

            @test auth_test_request(
                app,
                "PATCH",
                "/users/me/profile";
                cookie = admin,
                params = ["user[bio]" => "Profile from Julia", "user[password]" => ""],
            ).status == 303
            @test AuthWeb.scalar(app, "SELECT bio FROM users WHERE id = 1") ==
                  "Profile from Julia"
            @test auth_test_request(
                app,
                "POST",
                "/session";
                params = [
                    "email_address" => "admin@test",
                    "password" => "a secure test password",
                ],
            ).status == 302
            @test auth_test_request(
                app,
                "POST",
                "/session";
                params = ["email_address" => "admin@test", "password" => "wrong"],
            ).status == 401
            @test auth_test_request(
                app,
                "POST",
                "/session";
                params = ["email_address" => "missing@test", "password" => "wrong"],
            ).status == 401
            for _ = 1:10
                auth_test_request(
                    app,
                    "POST",
                    "/session";
                    ip = "198.51.100.99",
                    params = ["email_address" => "missing@test", "password" => ""],
                )
            end
            @test auth_test_request(app, "POST", "/session"; ip = "198.51.100.99").status ==
                  429

            @test auth_test_request(
                app,
                "PATCH",
                "/account";
                cookie = admin,
                params = [
                    "account[name]" => "Julia Campfire",
                    "account[settings][restrict_room_creation_to_administrators]" => "true",
                ],
            ).status == 303
            @test AuthWeb.scalar(app, "SELECT name FROM accounts") == "Julia Campfire"
            @test JSON3.read(AuthWeb.scalar(app, "SELECT settings FROM accounts"))[:restrict_room_creation_to_administrators]
            @test auth_test_request(
                app,
                "PATCH",
                "/account/custom_styles";
                cookie = admin,
                params = ["account[custom_styles]" => "body { --custom: test; }"],
            ).status == 303
            @test occursin(
                "--custom: test",
                auth_body(auth_test_request(app, "GET", "/account/edit"; cookie = admin)),
            )
            invitation = AuthWeb.scalar(app, "SELECT join_code FROM accounts")
            @test auth_test_request(app, "GET", "/join/invalid").status == 404
            @test auth_test_request(app, "GET", "/join/$invitation").status == 200
            joined = auth_test_request(
                app,
                "POST",
                "/join/$invitation";
                ip = "198.51.100.3",
                params = [
                    "user[name]" => "Member",
                    "user[email_address]" => "member@test",
                    "user[password]" => "another test password",
                ],
            )
            @test joined.status == 302
            member = auth_cookie(joined)
            member_id = AuthWeb.scalar(
                app,
                "SELECT id FROM users WHERE email_address = 'member@test'",
            )
            @test AuthWeb.scalar(
                app,
                "SELECT role FROM users WHERE id = ?",
                (member_id,),
            ) == 0
            @test AuthWeb.scalar(
                app,
                "SELECT count(*) FROM memberships WHERE user_id = ?",
                (member_id,),
            ) == 1
            duplicate = auth_test_request(
                app,
                "POST",
                "/join/$invitation";
                params = ["user[email_address]" => "member@test"],
            )
            @test duplicate.status == 302
            @test startswith(HTTP.header(duplicate, "Location"), "/session/new?")
            @test auth_test_request(app, "GET", "/account/edit"; cookie = member).status ==
                  200
            @test !occursin(
                "Set up chat bots",
                auth_body(auth_test_request(app, "GET", "/account/edit"; cookie = member)),
            )
            for (method, path) in (
                ("PATCH", "/account"),
                ("GET", "/account/bots"),
                ("GET", "/account/bots/new"),
                ("PATCH", "/account/custom_styles"),
                ("POST", "/account/join_code"),
                ("PATCH", "/account/users/1"),
                ("POST", "/users/1/ban"),
            )
                @test auth_test_request(app, method, path; cookie = member).status == 403
            end
            @test auth_test_request(app, "GET", "/users/$member_id"; cookie = member).status ==
                  200
            @test auth_test_request(app, "GET", "/account/users"; cookie = admin).status ==
                  200

            @test auth_test_request(app, "GET", "/account/bots/new"; cookie = admin).status ==
                  200
            @test auth_test_request(
                app,
                "POST",
                "/account/bots";
                cookie = admin,
                params = [
                    "user[name]" => "Julia bot",
                    "user[webhook_url]" => "https://example.test/webhook",
                ],
            ).status == 303
            bot = AuthWeb.qone(app, "SELECT * FROM users WHERE role = 2")
            @test bot.status == 0
            @test AuthWeb.scalar(
                app,
                "SELECT count(*) FROM memberships WHERE user_id = ?",
                (bot.id,),
            ) == 1
            @test AuthWeb.scalar(
                app,
                "SELECT url FROM webhooks WHERE user_id = ?",
                (bot.id,),
            ) == "https://example.test/webhook"
            @test occursin(
                "curl command for posting messages",
                auth_body(auth_test_request(app, "GET", "/account/bots"; cookie = admin)),
            )
            @test auth_test_request(
                app,
                "GET",
                "/account/bots/$(bot.id)/edit";
                cookie = admin,
            ).status == 200
            @test auth_test_request(
                app,
                "PATCH",
                "/account/bots/$(bot.id)";
                cookie = admin,
                params = ["user[name]" => "Updated bot", "user[webhook_url]" => ""],
            ).status == 303
            @test AuthWeb.scalar(
                app,
                "SELECT count(*) FROM webhooks WHERE user_id = ?",
                (bot.id,),
            ) == 0
            @test auth_test_request(
                app,
                "PATCH",
                "/account/bots/$(bot.id)/key";
                cookie = admin,
            ).status == 303
            @test AuthWeb.scalar(
                app,
                "SELECT bot_token FROM users WHERE id = ?",
                (bot.id,),
            ) != bot.bot_token
            @test auth_test_request(
                app,
                "DELETE",
                "/account/bots/$(bot.id)";
                cookie = admin,
            ).status == 303
            @test AuthWeb.scalar(app, "SELECT status FROM users WHERE id = ?", (bot.id,)) ==
                  1
            @test AuthWeb.scalar(
                app,
                "SELECT count(*) FROM memberships WHERE user_id = ?",
                (bot.id,),
            ) == 0

            invalid_push = ["push_subscription[endpoint]" => "http://127.0.0.1/internal"]
            @test auth_test_request(
                app,
                "POST",
                "/users/me/push_subscriptions";
                cookie = member,
                params = invalid_push,
            ).status == 422
            push_params = [
                "push_subscription[endpoint]" => "https://fcm.googleapis.com/send/test",
                "push_subscription[p256dh_key]" => "p256",
                "push_subscription[auth_key]" => "auth",
            ]
            @test auth_test_request(
                app,
                "POST",
                "/users/me/push_subscriptions";
                cookie = member,
                params = push_params,
            ).status == 200
            @test auth_test_request(
                app,
                "POST",
                "/users/me/push_subscriptions";
                cookie = member,
                params = push_params,
            ).status == 200
            @test AuthWeb.scalar(app, "SELECT count(*) FROM push_subscriptions") == 1
            push_id = AuthWeb.scalar(app, "SELECT id FROM push_subscriptions")
            @test auth_test_request(
                app,
                "DELETE",
                "/users/me/push_subscriptions/$push_id";
                cookie = admin,
            ).status == 303
            @test AuthWeb.scalar(app, "SELECT count(*) FROM push_subscriptions") == 1
            @test auth_test_request(
                app,
                "DELETE",
                "/users/me/push_subscriptions/$push_id";
                cookie = member,
            ).status == 303
            @test AuthWeb.scalar(app, "SELECT count(*) FROM push_subscriptions") == 0

            @test auth_test_request(
                app,
                "PATCH",
                "/account/users/$member_id";
                cookie = admin,
                params = ["user[role]" => "administrator"],
            ).status == 303
            @test AuthWeb.scalar(
                app,
                "SELECT role FROM users WHERE id = ?",
                (member_id,),
            ) == 1
            @test auth_test_request(
                app,
                "PATCH",
                "/account/users/$member_id";
                cookie = admin,
                params = ["user[role]" => "bot"],
            ).status == 303
            @test AuthWeb.scalar(
                app,
                "SELECT role FROM users WHERE id = ?",
                (member_id,),
            ) == 0
            @test auth_test_request(app, "POST", "/users/$member_id/ban"; cookie = admin).status ==
                  303
            @test AuthWeb.scalar(
                app,
                "SELECT status FROM users WHERE id = ?",
                (member_id,),
            ) == 2
            @test AuthWeb.scalar(
                app,
                "SELECT count(*) FROM sessions WHERE user_id = ?",
                (member_id,),
            ) == 0
            @test AuthWeb.scalar(
                app,
                "SELECT ip_address FROM bans WHERE user_id = ?",
                (member_id,),
            ) == "198.51.100.3"
            @test auth_test_request(app, "GET", "/users/me/profile"; cookie = member).status ==
                  302
            @test auth_test_request(
                app,
                "DELETE",
                "/users/$member_id/ban";
                cookie = admin,
            ).status == 303
            @test AuthWeb.scalar(
                app,
                "SELECT status FROM users WHERE id = ?",
                (member_id,),
            ) == 0
            @test AuthWeb.scalar(app, "SELECT count(*) FROM bans") == 0
            @test auth_test_request(
                app,
                "DELETE",
                "/account/users/$member_id";
                cookie = admin,
            ).status == 303
            @test occursin(
                "-deactivated-",
                AuthWeb.scalar(
                    app,
                    "SELECT email_address FROM users WHERE id = ?",
                    (member_id,),
                ),
            )
            @test AuthWeb.scalar(
                app,
                "SELECT status FROM users WHERE id = ?",
                (member_id,),
            ) == 1
            @test auth_test_request(app, "POST", "/account/join_code"; cookie = admin).status ==
                  303
            @test AuthWeb.scalar(app, "SELECT join_code FROM accounts") != invitation
            @test auth_test_request(app, "GET", "/join/$invitation").status == 404

            @testset "hourly session activity without hot GET writes" begin
                request = HTTP.Request(
                    "GET",
                    "/users/me/profile",
                    ["Cookie" => admin, "User-Agent" => "Updated test browser"],
                )
                request.context[:client_ip] = "198.51.100.77"
                session_token = AuthWeb.session_token(app, request)
                AuthWeb.execute!(
                    app,
                    "UPDATE sessions SET last_active_at = '2000-01-01 00:00:00' WHERE token = ?",
                    (session_token,),
                )
                @test AuthWeb.authenticate(app, request).id == 1
                @test haskey(request.context, :session_activity)
                @test AuthWeb.scalar(
                    app,
                    "SELECT last_active_at FROM sessions WHERE token = ?",
                    (session_token,),
                ) == "2000-01-01 00:00:00"
                AuthWeb.refresh_session_activity!(app, request)
                @test !haskey(request.context, :session_activity)
                refreshed = AuthWeb.qone(
                    app,
                    "SELECT last_active_at, user_agent, ip_address FROM sessions WHERE token = ?",
                    (session_token,),
                )
                @test refreshed.last_active_at != "2000-01-01 00:00:00"
                @test refreshed.user_agent == "Updated test browser"
                @test refreshed.ip_address == "198.51.100.77"
                changes = AuthWeb.scalar(app, "SELECT total_changes()")
                @test AuthWeb.authenticate(app, request).id == 1
                @test !haskey(request.context, :session_activity)
                AuthWeb.refresh_session_activity!(app, request)
                @test AuthWeb.scalar(app, "SELECT total_changes()") == changes

                AuthWeb.execute!(
                    app,
                    "UPDATE sessions SET last_active_at = '2000-01-01 00:00:00' WHERE token = ?",
                    (session_token,),
                )
                @test auth_test_request(app, "GET", "/rooms/1"; cookie = admin).status ==
                      200
                @test AuthWeb.scalar(
                    app,
                    "SELECT last_active_at FROM sessions WHERE token = ?",
                    (session_token,),
                ) != "2000-01-01 00:00:00"
                changes = AuthWeb.scalar(app, "SELECT total_changes()")
                @test auth_test_request(app, "GET", "/rooms/1"; cookie = admin).status ==
                      200
                @test auth_test_request(app, "GET", "/rooms/1"; cookie = admin).status ==
                      200
                @test AuthWeb.scalar(app, "SELECT total_changes()") == changes

                closed_app = AuthWeb.WebApp(joinpath(directory, "closed.sqlite3"))
                close(closed_app)
                request.context[:session_activity] = 1
                @test AuthWeb.refresh_session_activity!(closed_app, request) === nothing
                @test !haskey(request.context, :session_activity)
            end

            @testset "signed and bounded return to requested page" begin
                destination = "/account/edit?source=auth-test"
                protected = auth_test_request(app, "GET", destination)
                @test protected.status == 302
                @test HTTP.header(protected, "Location") == "/session/new"
                return_cookie = auth_cookie(protected)
                @test startswith(return_cookie, "return_to=")
                @test occursin(
                    "HttpOnly; SameSite=Lax; Max-Age=3600",
                    HTTP.header(protected, "Set-Cookie"),
                )
                authenticated = auth_test_request(
                    app,
                    "POST",
                    "/session";
                    cookie = return_cookie,
                    ip = "198.51.100.88",
                    params = [
                        "email_address" => "admin@test",
                        "password" => "a secure test password",
                    ],
                )
                @test authenticated.status == 302
                @test HTTP.header(authenticated, "Location") == destination
                @test startswith(auth_cookie(authenticated), "session_token=")
                @test any(
                    pair ->
                        lowercase(first(pair)) == "set-cookie" &&
                        startswith(last(pair), "return_to=;") &&
                        occursin("Max-Age=0", last(pair)),
                    authenticated.headers,
                )

                expiry = floor(Int, time()) + 3600
                for unsafe in (
                    "https://evil.test/",
                    "//evil.test/",
                    "/\\evil.test/",
                    "/path\nLocation:bad",
                    "/path with spaces",
                    "/" * repeat("a", 2048),
                )
                    @test !AuthWeb.safe_return_path(unsafe)
                    token = AuthWeb.signed_token(app, "return-to", "$expiry\n$unsafe")
                    context = (
                        app = app,
                        req = HTTP.Request(
                            "GET",
                            "/session",
                            ["Cookie" => "return_to=$token"],
                        ),
                    )
                    @test AuthWeb.post_authenticating_path(context) == "/"
                end
                for payload in ("0\n/rooms/1", "invalid\n/rooms/1", "missing separator")
                    token = AuthWeb.signed_token(app, "return-to", payload)
                    context = (
                        app = app,
                        req = HTTP.Request(
                            "GET",
                            "/session",
                            ["Cookie" => "return_to=$token"],
                        ),
                    )
                    @test AuthWeb.post_authenticating_path(context) == "/"
                end
                tampered = (
                    app = app,
                    req = HTTP.Request(
                        "GET",
                        "/session",
                        ["Cookie" => return_cookie * "0"],
                    ),
                )
                @test AuthWeb.post_authenticating_path(tampered) == "/"
                @test AuthWeb.safe_return_path("/rooms/1?before=123")
                @test !AuthWeb.safe_return_path(nothing)
                secure_context = (
                    app = app,
                    req = HTTP.Request("GET", "/rooms/1"),
                    method = "GET",
                    path = "/rooms/1",
                    base_url = "https://campfire.test",
                )
                @test occursin(
                    "; Secure",
                    HTTP.header(
                        AuthWeb.authentication_redirect(secure_context),
                        "Set-Cookie",
                    ),
                )
                @test !HTTP.hasheader(
                    auth_test_request(app, "POST", "/rooms"),
                    "Set-Cookie",
                )
            end

            logout = auth_test_request(app, "DELETE", "/session"; cookie = admin)
            @test logout.status == 302
            @test occursin("Max-Age=0", HTTP.header(logout, "Set-Cookie"))
            @test auth_test_request(app, "GET", "/users/me/profile"; cookie = admin).status ==
                  302
            @test auth_test_request(
                app,
                "GET",
                "/users/me/profile";
                cookie = auth_cookie(transfer_login),
            ).status == 200
        finally
            close(app)
        end
    end
end
