using Test, HTTP, SHA, JSON3, Sockets, SQLite

if !isdefined(@__MODULE__, :Campfire)
    include("../julia/src/Campfire.jl")
end
if !isdefined(Campfire, :Web)
    Base.include(Campfire, joinpath(@__DIR__, "../julia/src/Web.jl"))
end
const PushWeb = Campfire.Web

function verify_push_signature(public_key, input, signature)
    return PushWeb.with_p256(; public = public_key) do key
        sig = ccall((:ECDSA_SIG_new, PushWeb.CRYPTO_LIBRARY), Ptr{Cvoid}, ())
        r = ccall(
            (:BN_bin2bn, PushWeb.CRYPTO_LIBRARY),
            Ptr{Cvoid},
            (Ptr{UInt8}, Cint, Ptr{Cvoid}),
            signature[1:32],
            32,
            C_NULL,
        )
        s = ccall(
            (:BN_bin2bn, PushWeb.CRYPTO_LIBRARY),
            Ptr{Cvoid},
            (Ptr{UInt8}, Cint, Ptr{Cvoid}),
            signature[33:64],
            32,
            C_NULL,
        )
        try
            ccall(
                (:ECDSA_SIG_set0, PushWeb.CRYPTO_LIBRARY),
                Cint,
                (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                sig,
                r,
                s,
            ) == 1 || error("cannot import signature")
            digest = sha256(input)
            return ccall(
                (:ECDSA_do_verify, PushWeb.CRYPTO_LIBRARY),
                Cint,
                (Ptr{UInt8}, Cint, Ptr{Cvoid}, Ptr{Cvoid}),
                digest,
                length(digest),
                sig,
                key,
            ) == 1
        finally
            ccall((:ECDSA_SIG_free, PushWeb.CRYPTO_LIBRARY), Cvoid, (Ptr{Cvoid},), sig)
        end
    end
end

@testset "Julia Web Push encryption and delivery" begin
    # RFC 8291 section 5 and Appendix A independent interoperability vector:
    # https://www.rfc-editor.org/rfc/rfc8291.html#appendix-A
    recipient = PushWeb.unurlbase64(
        "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
    )
    sender_private = PushWeb.unurlbase64("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw")
    salt = PushWeb.unurlbase64("DGv6ra1nlYgDCS1FRnbzlw")
    auth = PushWeb.unurlbase64("BTBZMqHH6r4Tts7J_aSIgg")
    plaintext = "When I grow up, I want to be a watermelon"
    @testset "RFC 8291 interoperability and malformed keys" begin
        PushWeb.with_p256(; private = sender_private) do key
            public_key = PushWeb.p256_public(key)
            @test PushWeb.urlbase64(public_key) ==
                  "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
            @test PushWeb.p256_private(key) == sender_private
            shared = PushWeb.p256_shared_secret(key, recipient)
            @test PushWeb.urlbase64(shared) == "kyrL1jIIOHEzg3sM2ZWRHDRB62YACZhhSlknJ672kSs"
            derived = PushWeb.push_content_keys(shared, auth, salt, recipient, public_key)
            @test PushWeb.urlbase64(derived.key) == "oIhVW04MRdy2XN9CiKLxTg"
            @test PushWeb.urlbase64(derived.nonce) == "4h_95klXJ5E_qnoN"
        end
        ciphertext = PushWeb.encrypt_push(
            plaintext,
            recipient,
            auth;
            salt = salt,
            sender_private = sender_private,
        )
        @test PushWeb.urlbase64(ciphertext) ==
              "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
        @test length(ciphertext) == 144
        @test PushWeb.encrypt_push(plaintext, recipient, auth) != ciphertext
        @test PushWeb.encrypt_push(plaintext, recipient, auth) !=
              PushWeb.encrypt_push(plaintext, recipient, auth)
        @test length(PushWeb.encrypt_push(repeat("a", 3993), recipient, auth)) == 4096
        @test_throws ArgumentError PushWeb.encrypt_push(repeat("a", 3994), recipient, auth)
        @test_throws ArgumentError PushWeb.encrypt_push(plaintext, zeros(UInt8, 65), auth)
        @test_throws ArgumentError PushWeb.encrypt_push(
            plaintext,
            [0x04; zeros(UInt8, 64)],
            auth,
        )
        @test_throws ArgumentError PushWeb.encrypt_push(
            plaintext,
            recipient,
            zeros(UInt8, 15),
        )
        @test_throws ArgumentError PushWeb.encrypt_push(
            plaintext,
            recipient,
            auth;
            salt = zeros(UInt8, 15),
        )
        @test_throws ArgumentError PushWeb.with_p256(
            _ -> nothing;
            private = zeros(UInt8, 31),
        )
        @test_throws ArgumentError PushWeb.with_p256(
            _ -> nothing;
            private = zeros(UInt8, 32),
        )
        @test_throws ArgumentError PushWeb.with_p256(_ -> nothing; private = fill(0xff, 32))
        @test PushWeb.valid_push_keys(PushWeb.urlbase64(recipient), PushWeb.urlbase64(auth))
        @test !PushWeb.valid_push_keys("bad", "bad")
    end

    @testset "VAPID key persistence and ES256 authorization" begin
        mktempdir() do directory
            public_key, private_key =
                PushWeb.ensure_vapid_keys!(directory; public_key = "", private_key = "")
            @test length(PushWeb.unurlbase64(public_key)) == 65
            @test length(PushWeb.unurlbase64(private_key)) == 32
            @test stat(joinpath(directory, "vapid_private_key")).mode & 0o777 == 0o600
            @test PushWeb.ensure_vapid_keys!(
                directory;
                public_key = "",
                private_key = "",
            ) == (public_key, private_key)
            @test PushWeb.ensure_vapid_keys!(
                directory;
                public_key = public_key,
                private_key = private_key,
            ) == (public_key, private_key)
            # Ruby WebPush emits padded base64url; compare decoded key material.
            @test PushWeb.ensure_vapid_keys!(
                directory;
                public_key = public_key * "=",
                private_key = private_key * "=",
            ) == (public_key, private_key * "=")
            another_public, _ = PushWeb.generate_vapid_keys()
            @test_throws ArgumentError PushWeb.ensure_vapid_keys!(
                directory;
                public_key = another_public * "=",
                private_key = private_key * "=",
            )
            @test_throws ArgumentError PushWeb.ensure_vapid_keys!(
                directory;
                public_key = public_key,
                private_key = "",
            )
            @test_throws ArgumentError PushWeb.ensure_vapid_keys!(
                directory;
                public_key = "wrong",
                private_key = private_key,
            )
            header = PushWeb.vapid_authorization(
                public_key,
                private_key,
                "https://push.example.test:443/push/id";
                subject = "mailto:operator@example.test",
                at = 1000,
            )
            @test startswith(header, "vapid t=")
            token = first(split(header[9:end], ','))
            pieces = split(token, '.')
            @test length(pieces) == 3
            metadata, claims = JSON3.read(PushWeb.unurlbase64(pieces[1])),
            JSON3.read(PushWeb.unurlbase64(pieces[2]))
            @test metadata[:alg] == "ES256"
            @test claims[:aud] == "https://push.example.test"
            @test claims[:exp] == 1000 + 12 * 3600
            @test claims[:sub] == "mailto:operator@example.test"
            @test endswith(header, ", k=" * public_key)
            signature = PushWeb.unurlbase64(pieces[3])
            @test length(signature) == 64
            @test verify_push_signature(
                PushWeb.unurlbase64(public_key),
                pieces[1] * "." * pieces[2],
                signature,
            )
            @test !verify_push_signature(
                PushWeb.unurlbase64(public_key),
                pieces[1] * "." * pieces[2] * "0",
                signature,
            )
            @test_throws ArgumentError PushWeb.vapid_authorization(
                public_key,
                private_key,
                "http://push.example.test";
                at = 1000,
            )
            @test_throws ArgumentError PushWeb.vapid_authorization(
                public_key,
                private_key,
                "https://push.example.test";
                subject = "not a URI",
                at = 1000,
            )
        end
        for endpoint in (
            "https://fcm.googleapis.com/send/id",
            "https://web.push.apple.com/Q/id",
            "https://subdomain.notify.windows.com/push",
            "https://updates.push.services.mozilla.com/push",
        )
            @test PushWeb.permitted_push_endpoint(endpoint)
        end
        for endpoint in (
            "http://fcm.googleapis.com/send/id",
            "https://fcm.googleapis.com:444/id",
            "https://fcm.googleapis.com.evil.test/id",
            "https://user@fcm.googleapis.com/id",
            "https://127.0.0.1/id",
        )
            @test !PushWeb.permitted_push_endpoint(endpoint)
        end
        notification =
            PushWeb.push_json(repeat("🔥", 300), repeat("🔥", 4000), "/rooms/1", 3)
        @test ncodeunits(notification) <= 3993
        @test JSON3.read(notification)[:options][:data][:badge] == 3
        @test JSON3.read(notification)[:options][:data][:path] == "/rooms/1"
    end

    @testset "selection, authorization, delivery and expired subscriptions" begin
        mktempdir() do directory
            app = PushWeb.WebApp(joinpath(directory, "push.sqlite3"))
            try
                timestamp = PushWeb.nowstr()
                PushWeb.execute!(
                    app,
                    "INSERT INTO accounts (id,name,join_code,created_at,updated_at) VALUES (1,'Push Test','join',?,?)",
                    (timestamp, timestamp),
                )
                for id = 1:6
                    PushWeb.execute!(
                        app,
                        "INSERT INTO users (id,name,email_address,role,status,created_at,updated_at) VALUES (?,?,?,0,?,?,?)",
                        (
                            id,
                            "User $id",
                            "user$id@example.test",
                            id == 6 ? 2 : 0,
                            timestamp,
                            timestamp,
                        ),
                    )
                end
                PushWeb.execute!(
                    app,
                    "INSERT INTO rooms (id,name,type,creator_id,created_at,updated_at) VALUES (1,'Room','Rooms::Open',1,?,?)",
                    (timestamp, timestamp),
                )
                for id = 1:6
                    involvement = id == 3 ? "mentions" : id == 4 ? "nothing" : "everything"
                    PushWeb.execute!(
                        app,
                        "INSERT INTO memberships (room_id,user_id,involvement,connections,unread_at,created_at,updated_at) VALUES (1,?,?,?,?,?,?)",
                        (id, involvement, id == 5 ? 1 : 0, timestamp, timestamp, timestamp),
                    )
                    PushWeb.execute!(
                        app,
                        "INSERT INTO push_subscriptions (user_id,endpoint,p256dh_key,auth_key,created_at,updated_at) VALUES (?,?,?,?,?,?)",
                        (
                            id,
                            "https://fcm.googleapis.com/push/$id",
                            PushWeb.urlbase64(recipient),
                            PushWeb.urlbase64(auth),
                            timestamp,
                            timestamp,
                        ),
                    )
                end
                PushWeb.execute!(
                    app,
                    "INSERT INTO messages (id,creator_id,room_id,client_message_id,created_at,updated_at) VALUES (1,1,1,'push-message',?,?)",
                    (timestamp, timestamp),
                )
                PushWeb.execute!(
                    app,
                    "INSERT INTO action_text_rich_texts (name,record_type,record_id,body,created_at,updated_at) VALUES ('body','Message',1,'Hello',?,?)",
                    (timestamp, timestamp),
                )
                PushWeb.execute!(
                    app,
                    "INSERT INTO message_search_index (rowid,body) VALUES (1,'Hello')",
                )
                deliveries =
                    PushWeb.message_push_deliveries(app, 1, "https://campfire.test")
                @test length(deliveries) == 1
                @test deliveries[1][1].user_id == 2
                @test JSON3.read(deliveries[1][2])[:title] == "Room"
                @test JSON3.read(deliveries[1][2])[:options][:body] == "User 1: Hello"
                @test isempty(
                    PushWeb.message_push_deliveries(app, 999, "https://campfire.test"),
                )
                @testset "Typed push badge counts preserve current unread state" begin
                    PushWeb.execute!(app, "SAVEPOINT push_badge_regressions")
                    try
                        @test (@inferred PushWeb.message_push_badge(app, Int64(999))) ===
                              Int64(0)
                        @test (@inferred PushWeb.message_push_badge(app, Int64(2))) ===
                              Int64(1)
                        for (room, involvement, unread) in (
                            (2, "invisible", timestamp),
                            (3, "everything", nothing),
                            (4, "nothing", timestamp),
                        )
                            PushWeb.execute!(
                                app,
                                "INSERT INTO rooms(id,name,type,creator_id,created_at,updated_at) VALUES(?,'Badge room','Rooms::Open',1,?,?)",
                                (room, timestamp, timestamp),
                            )
                            PushWeb.execute!(
                                app,
                                "INSERT INTO memberships(room_id,user_id,involvement,unread_at,created_at,updated_at) VALUES(?,2,?,?,?,?)",
                                (room, involvement, unread, timestamp, timestamp),
                            )
                        end
                        @test PushWeb.message_push_badge(app, Int64(2)) === Int64(2)
                        # Both APIs reuse the same cached statement. Alternating
                        # user IDs must replace bindings in either direction.
                        count_sql = "SELECT count(*) FROM memberships WHERE user_id = ? AND unread_at IS NOT NULL AND involvement != 'invisible'"
                        @test PushWeb.scalar(app, count_sql, (Int64(999),)) == 0
                        @test PushWeb.message_push_badge(app, Int64(3)) === Int64(1)
                        @test PushWeb.scalar(app, count_sql, (Int64(2),)) == 2
                        @test PushWeb.message_push_badge(app, Int64(999)) === Int64(0)
                        PushWeb.execute!(
                            app,
                            "UPDATE memberships SET involvement='nothing' WHERE user_id=2 AND room_id=2",
                        )
                        @test PushWeb.message_push_badge(app, Int64(2)) === Int64(3)
                        PushWeb.execute!(
                            app,
                            "UPDATE memberships SET unread_at=NULL WHERE user_id=2 AND room_id=1",
                        )
                        @test PushWeb.message_push_badge(app, Int64(2)) === Int64(2)
                        PushWeb.execute!(
                            app,
                            "DELETE FROM memberships WHERE user_id=2 AND room_id=4",
                        )
                        @test PushWeb.message_push_badge(app, Int64(2)) === Int64(1)
                        PushWeb.execute!(
                            app,
                            "UPDATE memberships SET unread_at=NULL WHERE user_id=2",
                        )
                        @test PushWeb.message_push_badge(app, Int64(2)) === Int64(0)
                        @test PushWeb.message_push_badge(app, Int64(3)) === Int64(1)
                    finally
                        PushWeb.execute!(app, "ROLLBACK TO push_badge_regressions")
                        PushWeb.execute!(app, "RELEASE push_badge_regressions")
                    end
                end
                @testset "Fixed push projections preserve fields and owned text" begin
                    PushWeb.execute!(app, "SAVEPOINT push_projection_regressions")
                    try
                        subscriptions = PushWeb.message_push_subscriptions(app, 1)
                        @test eltype(subscriptions) == PushWeb.PushSubscription
                        @test sort([s.user_id for s in subscriptions]) == [2, 3]
                        for subscription in subscriptions
                            expected = merge(
                                PushWeb.qone(
                                    app,
                                    "SELECT * FROM push_subscriptions WHERE id=?",
                                    (subscription.id,),
                                ),
                                (
                                    involvement = subscription.user_id == 2 ?
                                                  "everything" : "mentions",
                                    delivery_room_id = 1,
                                    delivery_creator_id = 1,
                                ),
                            )
                            @test isequal(subscription, expected)
                        end
                        @test isempty(PushWeb.message_push_subscriptions(app, 999))

                        original = PushWeb.message_push_message(app, 1, 1, 1)
                        @test original isa PushWeb.PushMessage
                        @test original == (
                            creator_id = 1,
                            room_id = 1,
                            author = "User 1",
                            room_name = "Room",
                            room_type = "Rooms::Open",
                            editable_body = "Hello",
                            plain_text = "Hello",
                        )
                        @test PushWeb.message_push_message(app, 999, 1, 1) === nothing
                        @test PushWeb.message_push_message(app, 1, 2, 1) === nothing
                        @test PushWeb.message_push_message(app, 1, 1, 2) === nothing

                        PushWeb.execute!(
                            app,
                            "UPDATE push_subscriptions SET auth_key=NULL,endpoint=NULL,p256dh_key=NULL,user_agent=NULL WHERE user_id=2",
                        )
                        nullable = only(
                            s for s in PushWeb.message_push_subscriptions(app, 1) if
                            s.user_id == 2
                        )
                        @test all(
                            ismissing,
                            (
                                nullable.auth_key,
                                nullable.endpoint,
                                nullable.p256dh_key,
                                nullable.user_agent,
                            ),
                        )
                        @test isequal(
                            nullable,
                            merge(
                                PushWeb.qone(
                                    app,
                                    "SELECT * FROM push_subscriptions WHERE id=?",
                                    (nullable.id,),
                                ),
                                (
                                    involvement = "everything",
                                    delivery_room_id = 1,
                                    delivery_creator_id = 1,
                                ),
                            ),
                        )
                        PushWeb.execute!(
                            app,
                            "UPDATE push_subscriptions SET auth_key='new-auth',endpoint='https://fcm.googleapis.com/changed',p256dh_key='new-key',user_agent='New agent ☕' WHERE user_id=2",
                        )
                        current = only(
                            s for s in PushWeb.message_push_subscriptions(app, 1) if
                            s.user_id == 2
                        )
                        @test current.user_agent == "New agent ☕"
                        @test current.auth_key == "new-auth"
                        @test current.p256dh_key == "new-key"
                        @test current.endpoint == "https://fcm.googleapis.com/changed"
                        # Earlier rows retain copied strings after rebinding and
                        # resetting the same statement on subsequent reads.
                        old = only(s for s in subscriptions if s.user_id == 2)
                        @test old.endpoint == "https://fcm.googleapis.com/push/2"
                        @test old.auth_key == PushWeb.urlbase64(auth)
                        @test old.p256dh_key == PushWeb.urlbase64(recipient)
                        @test ismissing(old.user_agent)
                        @test ismissing(nullable.endpoint)

                        PushWeb.execute!(
                            app,
                            "UPDATE users SET name='Changed ☕' WHERE id=1",
                        )
                        PushWeb.execute!(
                            app,
                            "UPDATE rooms SET name=NULL,type='Rooms::Direct' WHERE id=1",
                        )
                        PushWeb.execute!(
                            app,
                            "UPDATE action_text_rich_texts SET body='<b>Edited ☕</b>' WHERE record_id=1",
                        )
                        PushWeb.execute!(
                            app,
                            "UPDATE message_search_index SET body='Edited ☕' WHERE rowid=1",
                        )
                        current_message = PushWeb.message_push_message(app, 1, 1, 1)
                        @test ismissing(current_message.room_name)
                        @test current_message.author == "Changed ☕"
                        @test current_message.room_type == "Rooms::Direct"
                        @test current_message.editable_body == "<b>Edited ☕</b>"
                        @test current_message.plain_text == "Edited ☕"
                        @test original.author == "User 1"
                        @test original.room_name == "Room"
                        @test original.editable_body == "Hello"
                        @test original.plain_text == "Hello"
                        PushWeb.execute!(
                            app,
                            "DELETE FROM action_text_rich_texts WHERE record_id=1",
                        )
                        PushWeb.execute!(
                            app,
                            "DELETE FROM message_search_index WHERE rowid=1",
                        )
                        empty_body = PushWeb.message_push_message(app, 1, 1, 1)
                        @test empty_body.editable_body == ""
                        @test empty_body.plain_text == ""
                    finally
                        PushWeb.execute!(app, "ROLLBACK TO push_projection_regressions")
                        PushWeb.execute!(app, "RELEASE push_projection_regressions")
                    end
                end
                token = PushWeb.signed_token(app, "mention", "3")
                PushWeb.execute!(
                    app,
                    "UPDATE action_text_rich_texts SET body = ?",
                    (
                        "Hello <action-text-attachment sgid=\"$token\"></action-text-attachment>",
                    ),
                )
                deliveries =
                    PushWeb.message_push_deliveries(app, 1, "https://campfire.test")
                @test sort([item[1].user_id for item in deliveries]) == [2, 3]
                @testset "Owned push snapshots and unlocked payload encoding" begin
                    PushWeb.execute!(app, "SAVEPOINT push_snapshot_regressions")
                    try
                        PushWeb.execute!(
                            app,
                            "INSERT INTO rooms(id,name,type,creator_id,created_at,updated_at) VALUES(2,'Other','Rooms::Open',1,?,?)",
                            (timestamp, timestamp),
                        )
                        for (user, involvement) in ((2, "invisible"), (3, "everything"))
                            PushWeb.execute!(
                                app,
                                "INSERT INTO memberships(room_id,user_id,involvement,unread_at,created_at,updated_at) VALUES(2,?,?,?,?,?)",
                                (user, involvement, timestamp, timestamp, timestamp),
                            )
                        end
                        PushWeb.execute!(
                            app,
                            "INSERT INTO push_subscriptions(id,user_id,endpoint,p256dh_key,auth_key,created_at,updated_at) SELECT 7,user_id,endpoint || '/other',p256dh_key,auth_key,created_at,updated_at FROM push_subscriptions WHERE id=2",
                        )
                        snapshot = PushWeb.message_push_snapshot(app, 1)
                        @test snapshot.message isa PushWeb.PushMessage
                        @test eltype(snapshot.subscriptions) == PushWeb.PushSubscription
                        @test eltype(snapshot.badges) == Int64
                        @test length(snapshot.subscriptions) == length(snapshot.badges) == 3
                        @test Dict(
                            sub.id => snapshot.badges[index] for
                            (index, sub) in enumerate(snapshot.subscriptions)
                        ) == Dict(2 => 1, 3 => 2, 7 => 1)
                        expected =
                            PushWeb.message_push_deliveries(app, 1, "https://campfire.test")
                        @test isequal(PushWeb.message_push_deliveries(snapshot), expected)
                        @test PushWeb.message_push_snapshot(app, 999) === nothing
                        @test isempty(PushWeb.message_push_deliveries(nothing))

                        # Encoding is independent of the database and completes
                        # even while another task owns its writer lock.
                        held, release = Channel{Nothing}(1), Channel{Nothing}(1)
                        holder = @async lock(app.lock) do
                            put!(held, nothing)
                            take!(release)
                        end
                        take!(held)
                        encoded = @async PushWeb.message_push_deliveries(snapshot)
                        try
                            @test islocked(app.lock)
                            @test timedwait(() -> istaskdone(encoded), 5) == :ok
                        finally
                            put!(release, nothing)
                            wait(holder)
                        end
                        @test isequal(fetch(encoded), expected)

                        # A send may let another writer update all source rows.
                        # The complete delivery batch must already own its data.
                        sent_batch = Tuple{NamedTuple,String}[]
                        batch_sender = function (app, sub, text)
                            @test !islocked(app.lock)
                            push!(sent_batch, (sub, text))
                            if length(sent_batch) == 1
                                lock(app.lock) do
                                    PushWeb.execute!(
                                        app,
                                        "UPDATE users SET name='Changed author' WHERE id=1",
                                    )
                                    PushWeb.execute!(
                                        app,
                                        "UPDATE rooms SET name='Changed room' WHERE id=1",
                                    )
                                    PushWeb.execute!(
                                        app,
                                        "UPDATE action_text_rich_texts SET body='Changed markup' WHERE record_id=1",
                                    )
                                    PushWeb.execute!(
                                        app,
                                        "UPDATE message_search_index SET body='Changed body' WHERE rowid=1",
                                    )
                                    PushWeb.execute!(
                                        app,
                                        "UPDATE memberships SET unread_at=NULL",
                                    )
                                    PushWeb.execute!(
                                        app,
                                        "UPDATE push_subscriptions SET endpoint=endpoint || '/changed',auth_key='changed-auth'",
                                    )
                                end
                            end
                            return 201
                        end
                        @test PushWeb.deliver_message_push!(
                            app,
                            1,
                            "https://campfire.test";
                            sender = batch_sender,
                        ) === nothing
                        @test isequal(sent_batch, expected)
                        changed = PushWeb.message_push_snapshot(app, 1)
                        @test changed.message.author == "Changed author"
                        @test changed.message.room_name == "Changed room"
                        @test changed.message.editable_body == "Changed markup"
                        @test changed.message.plain_text == "Changed body"
                        @test all(iszero, changed.badges)
                        @test all(
                            endswith(sub.endpoint, "/changed") for
                            sub in changed.subscriptions
                        )
                        @test all(
                            sub.auth_key == "changed-auth" for sub in changed.subscriptions
                        )
                        @test isequal(PushWeb.message_push_deliveries(snapshot), expected)
                        @test snapshot.message.author == "User 1"
                        @test snapshot.message.room_name == "Room"
                        @test snapshot.message.plain_text == "Hello"
                        @test all(
                            sub.auth_key == PushWeb.urlbase64(auth) for
                            sub in snapshot.subscriptions
                        )
                    finally
                        PushWeb.execute!(app, "ROLLBACK TO push_snapshot_regressions")
                        PushWeb.execute!(app, "RELEASE push_snapshot_regressions")
                    end
                end
                subscription, payload = first(deliveries)
                sent = Ref(false)
                function fetcher(uri, ip, deadline; method, body, headers)
                    sent[] = true
                    @test method == "POST"
                    @test ip == ip"1.1.1.1"
                    @test uri.host == "fcm.googleapis.com"
                    @test get(Dict(headers), "Content-Encoding", "") == "aes128gcm"
                    @test startswith(get(Dict(headers), "Authorization", ""), "vapid t=")
                    @test body[21] == 65
                    @test body[22] == 0x04
                    @test length(body) == ncodeunits(payload) + 103
                    @test !occursin("User 1", String(copy(body)))
                    return (status = 201, headers = Dict{String,String}(), body = UInt8[])
                end
                @test PushWeb.send_web_push(
                    app,
                    subscription,
                    payload;
                    resolver = _ -> [ip"1.1.1.1"],
                    fetcher = fetcher,
                ) == 201
                @test sent[]
                sent[] = false
                @test PushWeb.send_web_push(
                    app,
                    subscription,
                    payload;
                    resolver = _ -> [ip"127.0.0.1"],
                    fetcher = fetcher,
                ) === nothing
                @test !sent[]
                @test PushWeb.send_web_push(
                    app,
                    merge(subscription, (endpoint = "https://evil.test/push",)),
                    payload;
                    resolver = _ -> error("must not resolve"),
                    fetcher = fetcher,
                ) === nothing
                @test PushWeb.send_web_push(
                    app,
                    merge(subscription, (auth_key = "bad",)),
                    payload;
                    resolver = _ -> error("must not resolve"),
                    fetcher = fetcher,
                ) === nothing
                sent_ids = Int64[]
                sender(app, sub, text) = (push!(sent_ids, sub.id); 201)
                PushWeb.deliver_message_push!(
                    app,
                    1,
                    "https://campfire.test";
                    sender = sender,
                )
                @test sort(sent_ids) == [2, 3]
                @testset "Fresh push text and recipients" begin
                    PushWeb.execute!(app, "SAVEPOINT push_payload_regressions")
                    try
                        PushWeb.execute!(
                            app,
                            "UPDATE memberships SET involvement='nothing' WHERE user_id=3",
                        )
                        PushWeb.execute!(
                            app,
                            "UPDATE users SET name='Updated author',role=2 WHERE id=1",
                        )
                        PushWeb.execute!(
                            app,
                            "UPDATE rooms SET name='Updated room',type='Rooms::Direct' WHERE id=1",
                        )
                        PushWeb.execute!(
                            app,
                            "UPDATE action_text_rich_texts SET body='<b>Updated text</b>' WHERE record_id=1",
                        )
                        PushWeb.execute!(
                            app,
                            "UPDATE message_search_index SET body='Updated ☕ text' WHERE rowid=1",
                        )
                        deliveries =
                            PushWeb.message_push_deliveries(app, 1, "https://campfire.test")
                        @test only(deliveries)[1].user_id == 2
                        payload = JSON3.read(only(deliveries)[2])
                        @test payload.title == "Updated author"
                        @test payload.options.body == "Updated ☕ text"
                        @test payload.options.icon == "/account/logo"
                        @test payload.options.data.path == "/rooms/1"
                        @test payload.options.data.badge == 1
                        PushWeb.execute!(
                            app,
                            "UPDATE rooms SET name=NULL,type='Rooms::Open' WHERE id=1",
                        )
                        payload = JSON3.read(
                            only(
                                PushWeb.message_push_deliveries(
                                    app,
                                    1,
                                    "https://campfire.test",
                                ),
                            )[2],
                        )
                        @test payload.title == "Campfire"
                        @test payload.options.body == "Updated author: Updated ☕ text"

                        PushWeb.execute!(
                            app,
                            "UPDATE memberships SET involvement='nothing' WHERE user_id IN (2,3)",
                        )
                        @test isempty(
                            PushWeb.message_push_deliveries(
                                app,
                                1,
                                "https://campfire.test",
                            ),
                        )
                        PushWeb.execute!(
                            app,
                            "UPDATE memberships SET involvement='mentions' WHERE user_id=3",
                        )
                        @test isempty(
                            PushWeb.message_push_deliveries(
                                app,
                                1,
                                "https://campfire.test",
                            ),
                        )
                        PushWeb.execute!(
                            app,
                            "UPDATE action_text_rich_texts SET body=? WHERE record_id=1",
                            (
                                "<action-text-attachment sgid=\"invalid\"></action-text-attachment>",
                            ),
                        )
                        @test isempty(
                            PushWeb.message_push_deliveries(
                                app,
                                1,
                                "https://campfire.test",
                            ),
                        )
                        PushWeb.execute!(
                            app,
                            "UPDATE action_text_rich_texts SET body=? WHERE record_id=1",
                            (
                                "<action-text-attachment sgid=\"$token\"></action-text-attachment>",
                            ),
                        )
                        @test only(
                            PushWeb.message_push_deliveries(
                                app,
                                1,
                                "https://campfire.test",
                            ),
                        )[1].user_id == 3
                        PushWeb.execute!(
                            app,
                            "UPDATE memberships SET connections=1 WHERE user_id=3",
                        )
                        @test isempty(
                            PushWeb.message_push_deliveries(
                                app,
                                1,
                                "https://campfire.test",
                            ),
                        )
                        PushWeb.execute!(
                            app,
                            "UPDATE memberships SET connections=0 WHERE user_id=3",
                        )
                        PushWeb.execute!(app, "UPDATE users SET status=1 WHERE id=3")
                        @test isempty(
                            PushWeb.message_push_deliveries(
                                app,
                                1,
                                "https://campfire.test",
                            ),
                        )
                        PushWeb.execute!(app, "UPDATE users SET status=0 WHERE id=3")
                        PushWeb.execute!(app, "UPDATE users SET status=2 WHERE id=1")
                        @test isempty(
                            PushWeb.message_push_deliveries(
                                app,
                                1,
                                "https://campfire.test",
                            ),
                        )
                        PushWeb.execute!(app, "UPDATE users SET status=0 WHERE id=1")
                        PushWeb.execute!(app, "DELETE FROM memberships WHERE user_id=3")
                        @test isempty(
                            PushWeb.message_push_deliveries(
                                app,
                                1,
                                "https://campfire.test",
                            ),
                        )
                        PushWeb.execute!(app, "DELETE FROM messages WHERE id=1")
                        @test isempty(
                            PushWeb.message_push_deliveries(
                                app,
                                1,
                                "https://campfire.test",
                            ),
                        )
                    finally
                        PushWeb.execute!(app, "ROLLBACK TO push_payload_regressions")
                        PushWeb.execute!(app, "RELEASE push_payload_regressions")
                    end
                end

                @testset "External message changes during push selection" begin
                    PushWeb.execute!(
                        app,
                        "INSERT INTO rooms(id,name,type,creator_id,created_at,updated_at) VALUES(2,'Private','Rooms::Direct',1,?,?)",
                        (timestamp, timestamp),
                    )
                    external = SQLite.DB(joinpath(directory, "push.sqlite3"))
                    try
                        for mutation in (
                            "UPDATE messages SET room_id=2 WHERE id=1",
                            "UPDATE messages SET creator_id=2 WHERE id=1",
                        )
                            changed = Ref(false)
                            callback_error = Ref{Any}(nothing)
                            callback = function (_, _, _, sql)
                                try
                                    # Run after recipient selection, just before
                                    # the separate statement reads message text.
                                    if !changed[] && occursin(
                                        "COALESCE(rt.body",
                                        unsafe_string(Ptr{UInt8}(sql)),
                                    )
                                        changed[] = true
                                        PushWeb.execute_db!(external, mutation)
                                    end
                                catch error
                                    callback_error[] = error
                                end
                                return Cint(0)
                            end
                            hook = @cfunction(
                                $callback,
                                Cint,
                                (Cuint, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid})
                            )
                            GC.@preserve hook callback external begin
                                @test SQLite.C.sqlite3_trace_v2(
                                    app.db.handle,
                                    SQLite.C.SQLITE_TRACE_STMT,
                                    hook,
                                    C_NULL,
                                ) == SQLite.C.SQLITE_OK
                                try
                                    @test isempty(
                                        PushWeb.message_push_deliveries(
                                            app,
                                            1,
                                            "https://campfire.test",
                                        ),
                                    )
                                    @test changed[]
                                    @test callback_error[] === nothing
                                finally
                                    SQLite.C.sqlite3_trace_v2(
                                        app.db.handle,
                                        0,
                                        C_NULL,
                                        C_NULL,
                                    )
                                    PushWeb.execute!(
                                        app,
                                        "UPDATE messages SET room_id=1,creator_id=1 WHERE id=1",
                                    )
                                end
                            end
                            @test sort([
                                sub.user_id for (sub, _) in PushWeb.message_push_deliveries(
                                    app,
                                    1,
                                    "https://campfire.test",
                                )
                            ]) == [2, 3]
                        end
                    finally
                        SQLite.close(external)
                        PushWeb.execute!(app, "DELETE FROM rooms WHERE id=2")
                    end
                end
                @test PushWeb.deliver_test_push!(
                    app,
                    2,
                    "https://campfire.test";
                    sender = sender,
                ) == 201
                @test PushWeb.deliver_test_push!(
                    app,
                    999,
                    "https://campfire.test";
                    sender = sender,
                ) === nothing

                ctx = PushWeb.Context(
                    app,
                    HTTP.Request("POST", "/"),
                    "POST",
                    "/users/me/push_subscriptions/2/test_notifications",
                    Dict{String,Any}(),
                    PushWeb.User(PushWeb.qone(app, "SELECT * FROM users WHERE id=2")),
                    PushWeb.qone(app, "SELECT * FROM accounts"),
                    "https://campfire.test",
                    "",
                    PushWeb.Event[],
                )
                @test PushWeb.mention_user(ctx, token).id == 3
                @test PushWeb.mentioned_user_ids(
                    ctx,
                    (
                        editable_body = "<action-text-attachment sgid=\"$token\"></action-text-attachment>",
                    ),
                ) == Set([3])
                @test PushWeb.route_push_subscriptions(ctx).status == 303
                @test length(ctx.events) == 1
                @test ctx.events[1].kind == :push_test
                @test ctx.events[1].id == 2
                ctx.path = "/users/me/push_subscriptions/1/test_notifications"
                @test PushWeb.route_push_subscriptions(ctx).status == 404
                @test length(ctx.events) == 1
                @test PushWeb.deliver_push_subscription!(
                    app,
                    subscription,
                    payload;
                    sender = (args...) -> 410,
                ) == 410
                @test PushWeb.scalar(
                    app,
                    "SELECT count(*) FROM push_subscriptions WHERE id=2",
                ) == 0
                other = PushWeb.qone(app, "SELECT * FROM push_subscriptions WHERE id=3")
                @test PushWeb.deliver_push_subscription!(
                    app,
                    other,
                    payload;
                    sender = (args...) -> 503,
                ) == 503
                @test PushWeb.scalar(
                    app,
                    "SELECT count(*) FROM push_subscriptions WHERE id=3",
                ) == 1
                PushWeb.execute!(app, "UPDATE users SET status=2 WHERE id=1")
                @test isempty(
                    PushWeb.message_push_deliveries(app, 1, "https://campfire.test"),
                )
            finally
                close(app)
            end
        end
    end
end
