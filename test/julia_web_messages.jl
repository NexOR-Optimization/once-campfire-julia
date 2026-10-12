using Test, HTTP, JSON3, SQLite, Dates

if !isdefined(@__MODULE__, :Campfire)
    include(joinpath(@__DIR__, "../julia/src/Campfire.jl"))
end
if !isdefined(Campfire, :Web)
    Base.include(Campfire, joinpath(@__DIR__, "../julia/src/Web.jl"))
end

@testset "Julia web messages and media" begin
    W = Campfire.Web
    @test W.sanitize_rich_text("Julia & Ruby <b>work</b>") ==
          ("Julia &amp; Ruby <b>work</b>", "Julia & Ruby work")
    @test W.sanitize_rich_text(
        "<img src=x onerror=evil><b>safe</b><script>evil()</script>",
    ) == ("<b>safe</b>", "safe")
    @test W.sanitize_rich_text("<a href='javascript:evil()'>link</a>") ==
          ("<a>link</a>", "link")
    safe, plain = W.sanitize_rich_text(
        "<p style='text-align: center; background: url(javascript:evil)'>a<br>b</p><a href='https://example.com/?x=1&amp;y=2'>link</a>",
    )
    @test occursin("text-align: center", safe)
    @test !occursin("background", safe)
    @test occursin("noopener noreferrer", safe)
    @test plain == "a\nblink"
    @test W.sanitize_rich_text(
        "<svg><script>evil()</script></svg><math>x</math><strong>yes</strong>",
    ) == ("<strong>yes</strong>", "yes")
    @test W.sanitize_rich_text(
        "<action-text-attachment content='&lt;b&gt;Alice&lt;/b&gt;'></action-text-attachment>",
    ) == ("<b>Alice</b>", "Alice")
    @test !W.safe_link("//evil.test")
    @test !W.safe_link("java\nscript:evil")
    @test W.safe_link("/rooms/1")
    @test_throws ArgumentError W.sanitize_rich_text(String(UInt8[0xff]))
    @test W.message_sound("/play bell").url == "/assets/bell.mp3"
    @test W.message_sound("/play deeper").image_url == "/assets/sounds/top.webp"
    @test W.message_sound("/play unknown") === nothing
    @test W.message_sound("/play bell followed by text") === nothing
    @test W.blob_checksum(UInt8[]) == "1B2M2Y8AsgTpgAmY7PhCfg=="

    mktempdir() do directory
        app = W.WebApp(joinpath(directory, "db.sqlite3"); secret = repeat("a", 64))
        try
            timestamp = "2026-10-12 12:00:00.000"
            W.execute!(
                app,
                "INSERT INTO accounts(id,name,join_code,created_at,updated_at) VALUES(1,'Test','join',?,?)",
                (timestamp, timestamp),
            )
            for (id, role, name, token) in (
                (1, 1, "Admin", nothing),
                (2, 0, "Member", nothing),
                (3, 2, "Robot", "bot-token"),
                (4, 0, "Outsider", nothing),
            )
                W.execute!(
                    app,
                    "INSERT INTO users(id,name,email_address,role,status,bot_token,created_at,updated_at) VALUES(?,?,?,?,0,?,?,?)",
                    (id, name, "$id@example.test", role, token, timestamp, timestamp),
                )
            end
            for room = 1:2
                W.execute!(
                    app,
                    "INSERT INTO rooms(id,name,type,creator_id,created_at,updated_at) VALUES(?,?,'Rooms::Open',1,?,?)",
                    (room, "Room $room", timestamp, timestamp),
                )
            end
            for user = 1:3
                W.execute!(
                    app,
                    "INSERT INTO memberships(user_id,room_id,involvement,created_at,updated_at) VALUES(?,1,'everything',?,?)",
                    (user, timestamp, timestamp),
                )
            end
            account = W.qone(app, "SELECT * FROM accounts WHERE id=1")
            function context(
                method,
                path;
                user = 1,
                parameters = Dict{String,Any}(),
                body = "",
            )
                row =
                    isnothing(user) ? nothing :
                    W.qone(app, "SELECT * FROM users WHERE id=?", (user,))
                return W.Context(
                    app,
                    HTTP.Request(method, path, ["Host"=>"localhost"], body),
                    method,
                    path,
                    Dict{String,Any}(parameters),
                    isnothing(row) ? nothing : W.User(row),
                    account,
                    "http://localhost",
                    "test-csrf",
                    W.Event[],
                )
            end
            function dispatch(method, path; kwargs...)
                ctx = context(method, path; kwargs...)
                W.execute!(app, "BEGIN IMMEDIATE")
                try
                    result = something(W.route_messages(ctx), HTTP.Response(404))
                    W.execute!(app, result.status < 400 ? "COMMIT" : "ROLLBACK")
                    return result
                catch
                    W.execute!(app, "ROLLBACK")
                    rethrow()
                end
            end
            @test dispatch("GET", "/rooms/1/messages").status == 204
            @test dispatch(
                "POST",
                "/rooms/1/messages";
                parameters = Dict("message[body]"=>" "),
            ).status == 422
            @test dispatch(
                "POST",
                "/rooms/2/messages";
                parameters = Dict("message[body]"=>"secret"),
            ).status == 404
            @test dispatch(
                "POST",
                "/rooms/1/messages";
                user = 4,
                parameters = Dict("message[body]"=>"secret"),
            ).status == 404
            posted = dispatch(
                "POST",
                "/rooms/1/messages";
                parameters = Dict(
                    "message[body]"=>"<strong>Coffee &amp; Julia</strong>",
                    "message[client_message_id]"=>"shared-client-id",
                ),
            )
            @test posted.status == 200
            @test HTTP.header(posted, "Content-Type") ==
                  "text/vnd.turbo-stream.html; charset=utf-8"
            @test occursin("action=\"append\"", String(copy(posted.body)))
            @test W.scalar(app, "SELECT body FROM message_search_index WHERE rowid=1") ==
                  "Coffee & Julia"
            @test W.scalar(app, "SELECT messages_count FROM rooms WHERE id=1") == 1
            @test !ismissing(
                W.scalar(
                    app,
                    "SELECT unread_at FROM memberships WHERE room_id=1 AND user_id=2",
                ),
            )
            @test W.scalar(
                app,
                "SELECT count(*) FROM action_text_rich_texts WHERE record_id=1",
            ) == 1
            collision = dispatch(
                "POST",
                "/rooms/1/messages";
                user = 2,
                parameters = Dict(
                    "message[body]"=>"Member text",
                    "message[client_message_id]"=>"shared-client-id",
                ),
            )
            @test collision.status == 200
            @test W.scalar(
                app,
                "SELECT count(*) FROM messages WHERE client_message_id='shared-client-id'",
            ) == 2
            @test occursin("id=\"message_2\"", String(copy(collision.body)))
            @test dispatch(
                "PATCH",
                "/rooms/1/messages/1";
                user = 2,
                parameters = Dict("message[body]"=>"hijack"),
            ).status == 403
            @test dispatch(
                "PATCH",
                "/rooms/1/messages/2";
                parameters = Dict("message[body]"=>"Edited coffee ☕"),
            ).status == 303
            @test W.scalar(app, "SELECT body FROM message_search_index WHERE rowid=2") ==
                  "Edited coffee ☕"
            @test dispatch("GET", "/rooms/1/messages/2/edit").status == 200
            @test occursin(
                "Edit message",
                String(dispatch("GET", "/rooms/1/messages/2/edit").body),
            )
            @test dispatch("GET", "/rooms/2/messages/1").status == 404
            @test dispatch(
                "GET",
                "/rooms/1/messages";
                parameters = Dict("before"=>"999"),
            ).status == 404
            @test dispatch("GET", "/rooms/1/messages"; user = 3).status == 403
            @test dispatch("GET", "/rooms/1/3-invalid/messages"; user = nothing).status ==
                  303
            @test dispatch("GET", "/rooms/1/1-/messages"; user = nothing).status == 303
            @test dispatch(
                "POST",
                "/rooms/1/3-bot-token/messages";
                user = nothing,
                body = "Robot coffee",
            ).status == 201
            botlist = dispatch("GET", "/rooms/1/3-bot-token/messages"; user = nothing)
            @test botlist.status == 200
            @test HTTP.header(botlist, "X-Total-Count") == "3"
            parsed = JSON3.read(String(botlist.body))
            @test parsed[end].creator.role == "bot"
            @test parsed[end].body.plain_text == "Robot coffee"
            @test dispatch(
                "PATCH",
                "/rooms/1/3-bot-token/messages/3";
                user = nothing,
                body = "Robot updated",
            ).status == 200
            @test dispatch(
                "PATCH",
                "/rooms/1/3-bot-token/messages/1";
                user = nothing,
                body = "hijack",
            ).status == 403
            @test dispatch(
                "POST",
                "/rooms/2/3-bot-token/messages";
                user = nothing,
                body = "invisible",
            ).status == 404
            @test dispatch(
                "POST",
                "/rooms/1/3-bot-token/messages";
                user = nothing,
                body = " ",
            ).status == 422
            W.execute!(
                app,
                "UPDATE rooms SET updated_at='2000-01-01 00:00:00.000' WHERE id=1",
            )
            boost = dispatch(
                "POST",
                "/messages/1/boosts";
                user = 2,
                parameters = Dict("boost[content]"=>"👍"),
            )
            @test boost.status == 303
            @test W.scalar(app, "SELECT updated_at FROM rooms WHERE id=1") >=
                  W.scalar(app, "SELECT updated_at FROM messages WHERE id=1")
            boost_index = dispatch("GET", "/messages/1/boosts"; user = 2)
            @test boost_index.status == 200
            @test occursin(
                "data-turbo-streaming-target=\"container\"",
                String(boost_index.body),
            )
            W.execute!(
                app,
                "UPDATE rooms SET updated_at='2000-01-01 00:00:00.000' WHERE id=1",
            )
            @test dispatch("DELETE", "/messages/1/boosts/1").status == 404
            @test dispatch("DELETE", "/messages/1/boosts/1"; user = 2).status == 204
            @test W.scalar(app, "SELECT updated_at FROM rooms WHERE id=1") >=
                  W.scalar(app, "SELECT updated_at FROM messages WHERE id=1")
            botboost = dispatch(
                "POST",
                "/rooms/1/3-bot-token/messages/1/boosts";
                user = nothing,
                body = "Nice!",
            )
            @test botboost.status == 201
            @test JSON3.read(String(botboost.body)).booster.id == 3
            @test dispatch(
                "POST",
                "/messages/1/boosts";
                parameters = Dict("boost[content]"=>" "),
            ).status == 422
            @test dispatch("GET", "/searches"; parameters = Dict("q"=>"coffee")).status ==
                  200
            @test occursin(
                "Edited coffee",
                String(dispatch("GET", "/searches"; parameters = Dict("q"=>"coffee")).body),
            )
            @test !occursin(
                "data-message-id=",
                String(
                    dispatch(
                        "GET",
                        "/searches";
                        user = 4,
                        parameters = Dict("q"=>"coffee"),
                    ).body,
                ),
            )
            @test dispatch("GET", "/searches"; parameters = Dict("q"=>"AND OR NEAR")).status ==
                  200
            @test dispatch("POST", "/searches"; parameters = Dict("q"=>"coffee")).status ==
                  303
            @test dispatch("POST", "/searches"; parameters = Dict("q"=>"coffee")).status ==
                  303
            @test W.scalar(app, "SELECT count(*) FROM searches") == 1
            @test dispatch("DELETE", "/searches/clear").status == 303
            @test W.scalar(app, "SELECT count(*) FROM searches") == 0
            @test dispatch("DELETE", "/rooms/1/3-bot-token/messages/3"; user = nothing).status ==
                  204
            @test W.scalar(
                app,
                "SELECT count(*) FROM message_search_index WHERE rowid=3",
            ) == 0

            # The timestamp predicate, rather than IDs, defines the page boundary.
            page_time = now(UTC) + Hour(1)
            for id = 1:45
                body = "Page $id"
                created = Dates.format(
                    page_time + Second(id),
                    dateformat"yyyy-mm-dd HH:MM:SS.sss",
                )
                W.execute!(
                    app,
                    "INSERT INTO messages(room_id,creator_id,client_message_id,created_at,updated_at) VALUES(1,1,?,?,?)",
                    ("page-$id", created, created),
                )
                message_id = SQLite.last_insert_rowid(app.db)
                W.execute!(
                    app,
                    "INSERT INTO action_text_rich_texts(name,record_type,record_id,body,created_at,updated_at) VALUES('body','Message',?,?,?,?)",
                    (message_id, body, created, created),
                )
                W.execute!(
                    app,
                    "INSERT INTO message_search_index(rowid,body) VALUES(?,?)",
                    (message_id, body),
                )
            end
            lastpage = W.query_messages(context("GET", "/"), 1)
            @test length(lastpage) == 40
            @test last(lastpage).plain_text == "Page 45"
            @test length(
                W.query_messages(context("GET", "/"), 1; before = first(lastpage).id),
            ) == 7
            @test length(
                W.query_messages(context("GET", "/"), 1; after = last(lastpage).id),
            ) == 0
            @test length(
                W.query_messages(context("GET", "/"), 1; around = lastpage[20].id),
            ) == 47
            @test occursin(
                "rel=\"next\"",
                HTTP.header(
                    dispatch("GET", "/rooms/1/3-bot-token/messages"; user = nothing),
                    "Link",
                ),
            )

            mention_ctx = context("POST", "/rooms/1/messages")
            W.execute!(
                app,
                "UPDATE memberships SET connections=5,connected_at='2000-01-01 00:00:00',unread_at=NULL WHERE user_id=2 AND room_id=1",
            )
            ttl_ctx = context(
                "POST",
                "/rooms/1/messages";
                parameters = Dict("message[body]"=>"/play bell"),
            )
            @test W.route_messages(ttl_ctx).status == 200
            @test !ismissing(
                W.scalar(
                    app,
                    "SELECT unread_at FROM memberships WHERE user_id=2 AND room_id=1",
                ),
            )
            @test count(event->event.kind == :unread, ttl_ctx.events) == 1
            sound_message =
                W.get_message(ttl_ctx, W.scalar(app, "SELECT max(id) FROM messages"))
            @test sound_message.sound.name == "bell"
            mention_token = W.mention_token(mention_ctx, 2)
            mention_source = "<p>Hello <action-text-attachment sgid=\"$mention_token\" content-type=\"application/vnd.campfire.mention\" content=\"Forged name\"></action-text-attachment></p>"
            stored, plaintext = W.sanitize_rich_text(
                mention_source;
                ctx = mention_ctx,
                room = 1,
                storage = true,
            )
            @test plaintext == "Hello @Member"
            @test occursin("action-text-attachment", stored)
            @test !occursin("Forged name", stored)
            shown, _ = W.sanitize_rich_text(stored; ctx = mention_ctx)
            @test occursin("class=\"mention\"", shown)
            @test occursin("/users/2/avatar", shown)
            @test !occursin("action-text-attachment", shown)
            _, private_plain = W.sanitize_rich_text(
                mention_source;
                ctx = mention_ctx,
                room = 2,
                storage = true,
            )
            @test private_plain != "Hello @Member"
            @test W.mention_user(mention_ctx, mention_token * "tampered") === nothing
            @test occursin(
                "template type=\"editor\"",
                W.mention_prompt_html(
                    mention_ctx,
                    W.qone(app, "SELECT * FROM users WHERE id=2"),
                ),
            )
            W.execute!(
                app,
                "INSERT INTO webhooks(user_id,url,created_at,updated_at) VALUES(3,'http://127.0.0.1:1',?,?)",
                (timestamp, timestamp),
            )
            bot_mention = W.mention_token(mention_ctx, 3)
            webhook_ctx = context(
                "POST",
                "/rooms/1/messages";
                parameters = Dict(
                    "message[body]"=>"<action-text-attachment sgid=\"$bot_mention\"></action-text-attachment>",
                ),
            )
            @test W.route_messages(webhook_ctx).status == 200
            @test count(event->event.kind == :webhook, webhook_ctx.events) == 1
            @test only(filter(event->event.kind == :webhook, webhook_ctx.events)).id == 3
            webhook_event =
                only(filter(event->event.kind == :webhook, webhook_ctx.events)).payload
            before_reply = W.scalar(app, "SELECT count(*) FROM messages")
            delivered = Ref(false)
            transport = function (url, headers, body; kwargs...)
                @test url == "http://127.0.0.1:1"
                payload = JSON3.read(body)
                @test payload.user.id == 1
                @test payload.room.path == "/rooms/1/3-bot-token/messages"
                @test !occursin("@Robot", payload.message.body.plain)
                delivered[] = true
                return HTTP.Response(
                    200,
                    ["Content-Type"=>"text/plain"],
                    "Webhook replied successfully",
                )
            end
            W.deliver_webhook!(app, 3, webhook_event; transport = transport)
            @test delivered[]
            @test W.scalar(app, "SELECT count(*) FROM messages") == before_reply+1
            @test W.scalar(
                app,
                "SELECT creator_id FROM messages ORDER BY id DESC LIMIT 1",
            ) == 3
            @test W.scalar(
                app,
                "SELECT body FROM message_search_index ORDER BY rowid DESC LIMIT 1",
            ) == "Webhook replied successfully"

            upload = W.UploadedFile(
                "notes.txt",
                "text/plain",
                Vector{UInt8}(codeunits("Actual file bytes, not a placeholder.")),
            )
            uploaded = dispatch(
                "POST",
                "/rooms/1/messages";
                parameters = Dict("message[attachment]"=>upload),
            )
            @test uploaded.status == 200
            message_id = W.scalar(app, "SELECT max(id) FROM messages")
            blob = W.attachment_blob(app, "Message", message_id, "attachment")
            @test W.read_blob(app, blob) == upload.data
            @test W.scalar(
                app,
                "SELECT body FROM message_search_index WHERE rowid=?",
                (message_id,),
            ) == "notes.txt"
            url = W.blob_presentation(context("GET", "/"), blob).url
            downloaded = W.route_media(context("GET", url; user = nothing))
            @test downloaded.status == 200
            @test downloaded.body == upload.data
            @test startswith(HTTP.header(downloaded, "Content-Disposition"), "attachment;")
            range_ctx = context("GET", url)
            HTTP.setheader(range_ctx.req, "Range"=>"bytes=0-5")
            partial = W.route_media(range_ctx)
            @test partial.status == 206
            @test partial.body == upload.data[1:6]
            @test HTTP.header(partial, "Content-Range") ==
                  "bytes 0-5/$(length(upload.data))"
            HTTP.setheader(range_ctx.req, "Range"=>"bytes=-5")
            @test W.route_media(range_ctx).body == upload.data[(end-4):end]
            HTTP.setheader(range_ctx.req, "Range"=>"bytes=10000-")
            @test W.route_media(range_ctx).status == 416
            @test W.route_media(
                context("GET", replace(url, "/redirect/"=>"/redirect/broken")),
            ).status == 404
            # Possession of a signed blob URL grants read access, matching Rails;
            # room membership is still required for creating/replacing its link.
            @test W.route_media(context("GET", url; user = 4)).body == upload.data
            @test dispatch(
                "PATCH",
                "/rooms/1/messages/$message_id";
                user = 4,
                parameters = Dict("message[attachment]"=>upload),
            ).status == 404
            replacement =
                W.UploadedFile("replacement.txt", "text/plain", UInt8[0x61, 0x00, 0xff])
            @test dispatch(
                "PATCH",
                "/rooms/1/messages/$message_id";
                parameters = Dict("message[attachment]"=>replacement),
            ).status == 303
            @test W.read_blob(
                app,
                W.attachment_blob(app, "Message", message_id, "attachment"),
            ) == replacement.data
            @test W.scalar(
                app,
                "SELECT body FROM message_search_index WHERE rowid=?",
                (message_id,),
            ) == "replacement.txt"
            @test W.route_media(context("GET", url)).status == 404
            replacement_blob = W.attachment_blob(app, "Message", message_id, "attachment")
            replacement_path = W.blob_path(app, replacement_blob.key)
            replacement_url = W.blob_presentation(context("GET", "/"), replacement_blob).url
            # An aborted delete must preserve both authorization and file bytes,
            # even if cleanup is attempted after its transaction rolled back.
            W.execute!(app, "BEGIN IMMEDIATE")
            aborted = context("DELETE", "/rooms/1/messages/$message_id")
            @test W.route_messages(aborted).status == 200
            keys = only(filter(event->event.kind == :purge_storage, aborted.events)).payload
            W.execute!(app, "ROLLBACK")
            W.purge_storage!(app, keys)
            @test isfile(replacement_path)
            @test W.route_media(context("GET", replacement_url)).status == 200
            W.execute!(app, "BEGIN IMMEDIATE")
            deleted = context("DELETE", "/rooms/1/messages/$message_id")
            @test W.route_messages(deleted).status == 200
            W.execute!(app, "COMMIT")
            keys = only(filter(event->event.kind == :purge_storage, deleted.events)).payload
            W.purge_storage!(app, keys)
            @test !isfile(replacement_path)
            @test W.route_media(context("GET", replacement_url)).status == 404
            @test_throws ArgumentError W.blob_path(app, "../../outside")
            avatar = W.UploadedFile(
                "moon.jpg",
                "image/jpeg",
                read(joinpath(@__DIR__, "fixtures/files/moon.jpg")),
            )
            @test dispatch(
                "POST",
                "/rooms/1/messages";
                parameters = Dict("message[attachment]"=>avatar),
            ).status == 200
            photo = W.get_message(
                context("GET", "/"),
                W.scalar(app, "SELECT max(id) FROM messages"),
            )
            @test photo.attachment.preview_url !== nothing
            thumbnail = W.route_media(context("GET", photo.attachment.preview_url))
            @test HTTP.header(thumbnail, "Content-Type") == "image/webp"
            @test String(copy(thumbnail.body[1:4])) == "RIFF"
            broken = W.UploadedFile("broken.webp", "image/webp", UInt8[1, 2, 3, 4])
            @test dispatch(
                "POST",
                "/rooms/1/messages";
                parameters = Dict("message[attachment]"=>broken),
            ).status == 200
            damaged = W.get_message(
                context("GET", "/"),
                W.scalar(app, "SELECT max(id) FROM messages"),
            )
            @test damaged.attachment.preview_url === nothing
            @test W.route_media(context("GET", damaged.attachment.url)).body == broken.data
            movie = W.UploadedFile(
                "space.mov",
                "video/quicktime",
                read(joinpath(@__DIR__, "fixtures/files/alpha-centuri.mov")),
            )
            @test dispatch(
                "POST",
                "/rooms/1/messages";
                parameters = Dict("message[attachment]"=>movie),
            ).status == 200
            video = W.get_message(
                context("GET", "/"),
                W.scalar(app, "SELECT max(id) FROM messages"),
            )
            @test video.attachment.preview_url !== nothing
            @test W.route_media(context("GET", video.attachment.preview_url)).status == 200
            svg = W.UploadedFile(
                "not-a-bitmap.jpg",
                "image/jpeg",
                Vector{UInt8}(
                    codeunits(
                        "<svg xmlns='http://www.w3.org/2000/svg'><image href='file:///etc/passwd'/></svg>",
                    ),
                ),
            )
            W.attach_upload!(
                context(
                    "PATCH",
                    "/users/me/profile";
                    parameters = Dict("user[avatar]"=>svg),
                ),
                "User",
                2,
                "avatar",
                "user[avatar]",
            )
            @test W.avatar_variant(app, W.attachment_blob(app, "User", 2, "avatar")) ===
                  nothing
            W.attach_upload!(app, "User", 1, "avatar", avatar)
            avatar_url = "/users/$(W.signed_token(app, "avatar", "1"))/avatar"
            image = W.route_media(context("GET", avatar_url))
            @test image.status == 200
            @test HTTP.header(image, "Content-Type") == "image/webp"
            @test length(image.body) > 100
            @test String(copy(image.body[1:4])) == "RIFF"
            @test W.route_media(context("DELETE", avatar_url)).status == 303
            initials = W.route_media(context("GET", avatar_url))
            @test HTTP.header(initials, "Content-Type") == "image/svg+xml"
            @test occursin("<svg", String(initials.body))
            @test W.route_media(context("GET", "/users/tampered/avatar")).status == 404
            @test W.route_media(context("GET", "/users/1/avatar"; user = nothing)).status ==
                  404
            @test W.route_media(context("GET", "/users/1/avatar")).status == 200
            logo = W.route_media(context("GET", "/account/logo"; user = nothing))
            @test HTTP.header(logo, "Content-Type") == "image/png"
            @test logo.body[1:8] == UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        finally
            close(app)
        end
    end
end
