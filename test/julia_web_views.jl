using Test, HTTP, Dates, JSON3, SHA

# Keep the rendering contract independently runnable while avoiding database and
# HTTP-server setup. These are the same view files used by Campfire.Web.
module JuliaWebViewsTests
using HTTP, Dates, JSON3
include(joinpath(@__DIR__, "../julia/src/web/Assets.jl"))
include(joinpath(@__DIR__, "../julia/src/web/Views.jl"))
signed_token(app, purpose, text) = "$purpose:$text"
nowstr() = "2026-10-12 12:00:00.000"
qrows(app, sql, args = ()) = []
sanitize_rich_text(body; kwargs...) = (body, "")
end

@testset "Julia browser assets and views" begin
    V = JuliaWebViewsTests
    user = (
        id = 1,
        name = "Alice <Admin>",
        email_address = "alice@example.test",
        bio = "Profile",
        role = 1,
    )
    account =
        (name = "Campfire", custom_styles = "body { --brand: blue; }", join_code = "invite")
    ctx = (
        app = nothing,
        user = user,
        account = account,
        base_url = "http://localhost:3000",
        csrf = "safe&token",
        path = "/session/transfers/token",
    )
    room = (
        id = 4,
        name = "General <room>",
        type = "Rooms::Open",
        updated_at = "2026-10-12 12:00:00.000",
    )
    message = (
        id = 8,
        room_id = 4,
        creator_id = 1,
        author = user.name,
        client_message_id = "client&1",
        body = "<strong>Safe</strong>",
        created_at = "2026-10-12 12:00:00.000",
        room_name = room.name,
        boosts = [],
        attachment = nothing,
    )

    @test V.value(nothing, :key, "fallback") == "fallback"
    @test V.value((key = missing,), :key, "fallback") == "fallback"
    @test V.value(Dict("key" => 4), :key) == 4
    @test V.h("<script>'&\"") == "&lt;script&gt;&#39;&amp;&quot;"
    @test V.timestamp_ms("2026-10-12 12:00:00.000") == 1791806400000
    @test V.timestamp_ms("2026-10-12 12:00:00.123456") == 1791806400123
    @test V.timestamp_ms("2026-10-12T12:00:00.123Z") == 1791806400123

    asset = V.asset_response("/assets/controllers/messages_controller.js")
    @test asset.status == 200
    @test String(asset.body) == read(
        joinpath(@__DIR__, "../app/javascript/controllers/messages_controller.js"),
        String,
    )
    @test HTTP.header(asset, "Content-Type") == "text/javascript; charset=utf-8"
    @test V.asset_response("/assets/controllers/messages_controller.js").body === asset.body
    @test !isempty(asset.body)
    @test asset.body isa Base.CodeUnits
    @test V.asset_response("/assets/../../Gemfile").status == 404
    @test V.asset_response("/assets/%2e%2e/Gemfile").status == 404
    @test V.asset_response("/other") === nothing
    worker = V.serve_pwa(merge(ctx, (method = "GET", path = "/service-worker")))
    @test worker.status == 200
    @test String(worker.body) ==
          read(joinpath(@__DIR__, "../app/views/pwa/service_worker.js"), String)
    manifest_response =
        V.serve_pwa(merge(ctx, (method = "GET", path = "/webmanifest.json")))
    manifest = JSON3.read(manifest_response.body)
    @test manifest.name == "Campfire"
    @test manifest.start_url == "/"
    @test manifest.shortcuts[1].url == "/rooms/opens/new"
    @test V.serve_pwa(merge(ctx, (method = "POST", path = "/webmanifest"))) === nothing
    @test all(haskey(V.ASSET_PATHS, url[9:end]) for url in values(V.BROWSER_IMPORTS))
    @test haskey(V.BROWSER_IMPORTS, "lexxy")
    @test V.BROWSER_IMPORTS["controllers/rooms_list_controller"] ==
          "/assets/controllers/rooms_list_controller.js"

    rendered = V.message_html(ctx, message)
    @test occursin("id=\"message_8\"", rendered)
    @test occursin("id=\"edit_message_8\"", rendered)
    @test occursin("<strong>Safe</strong>", rendered)
    @test occursin("Alice &lt;Admin&gt;", rendered)
    @test occursin("http://localhost:3000/rooms/4/@8", rendered)
    @test occursin("data-client-message-id=\"client&amp;1\"", rendered)
    @test !occursin("name=\"authenticity_token\"", rendered)
    @test occursin("/users/avatar:1/avatar", rendered)
    @test occursin("aria-label=\"Edit message\"", V.edit_message_html(ctx, message))
    image_message = merge(
        message,
        (
            attachment = (
                url = "/file?a=1&b=2",
                filename = "image.png",
                content_type = "image/png",
                preview_url = "/file?a=1&b=2",
            ),
        ),
    )
    @test occursin("src=\"/file?a=1&amp;b=2\"", V.message_html(ctx, image_message))
    file_message = merge(
        message,
        (
            attachment = (
                url = "/file",
                filename = "report.txt",
                content_type = "text/plain",
            ),
        ),
    )
    @test occursin("download=\"report.txt\"", V.message_html(ctx, file_message))
    boosted = merge(message, (boosts = [(id = 1, content = "👍", author = "Bob")],))
    @test occursin("id=\"boost_1\"", V.message_html(ctx, boosted))
    boost_frame = V.boosts_html(ctx, boosted)
    @test occursin("data-controller=\"reply turbo-streaming\"", rendered)
    @test occursin("popup#close turbo:submit-start->turbo-streaming#unsubscribe", rendered)
    @test occursin("data-turbo-streaming-target=\"container\"", boost_frame)
    @test occursin("turbo:submit-start->turbo-streaming#unsubscribe", boost_frame)
    @test occursin("id=\"boost_1\"", boost_frame)
    @test occursin("turbo:submit-start->boost-delete#perform:stop", boost_frame)

    for name in (
        :first_run,
        :join,
        :session,
        :profile,
        :account,
        :styles,
        :bots,
        :bot_form,
        :room_form,
        :room_settings,
        :transfer,
    )
        page = V.view(
            ctx,
            name;
            room,
            user,
            join_code = "invite",
            transfer_url = "http://localhost:3000/session/transfers/token",
            qr_url = "/qr_code/example",
        )
        @test startswith(page, "<!DOCTYPE html>")
        @test occursin("import \"application\"", page)
        @test count("<form", page) == count("</form>", page)
    end
    @test occursin("data-controller=\"auto-submit\"", V.view(ctx, :transfer))
    @test occursin("Set up chat bots", V.view(ctx, :account))
    member = merge(ctx, (user = merge(user, (role = 0,)),))
    @test !occursin("Set up chat bots", V.view(member, :account))
    room_page = V.view(ctx, :room; room, messages = [message])
    @test occursin("id=\"messages_room_4\"", room_page)
    @test occursin("channel=\"RoomMessagesChannel\"", room_page)
    @test occursin("room-id=\"4\"", room_page)
    @test occursin("<lexxy-editor id=\"message_body\"", room_page)
    @test occursin("\$clientMessageId\$", room_page)
    @test occursin("data-controller=\"messages presence drop-target\"", room_page)
    @test occursin("id=\"user_sidebar\"", V.view(ctx, :sidebar; rooms = [room]))
    @test occursin(
        "data-autocomplete-url-value=\"/autocompletable/users\"",
        V.view(ctx, :direct_new),
    )
    @test occursin("id=\"search-results\"", V.search_page_html(ctx, [message], "Safe"))
    malicious_account = merge(
        ctx,
        (account = merge(account, (custom_styles = "</style><script>alert(1)</script>",)),),
    )
    @test !occursin("</style><script>alert", V.view(malicious_account, :account))
    bob = (id = 2, name = "Bob", role = 0, status = 0, selected = 1)
    account_page = V.view(ctx, :account; users = [user, bob])
    @test occursin("name=\"account[logo]\"", account_page)
    @test occursin(
        "name=\"account[settings][restrict_room_creation_to_administrators]\"",
        account_page,
    )
    @test occursin("Make Bob an administrator", account_page)
    @test occursin("Delete Bob", account_page)
    @test !occursin("Make Bob an administrator", V.view(member, :account; users = [bob]))
    profile_page = V.view(ctx, :profile)
    @test occursin("name=\"user[avatar]\"", profile_page)
    @test occursin("Log out", profile_page)
    @test occursin("Delete avatar", profile_page)
    @test occursin("Ban Bob", V.view(ctx, :user; user = bob))
    @test !occursin("name=\"user[password]\"", V.view(ctx, :user; user = bob))
    closed = V.view(ctx, :room_form; room, kind = "closeds", users = [bob])
    @test occursin("value=\"2\" checked", closed)
    @test occursin("Give everyone access", closed)
    @test occursin("Delete General", closed)
    direct = merge(room, (type = "Rooms::Direct", display_name = "Ping with Bob"))
    @test !occursin("Ping with Ping with", V.view(ctx, :room; room = direct))
    @test occursin("Delete Ping", V.view(ctx, :room_settings; room = direct))
    @test occursin(
        "data-sorted-list-name=\"General &lt;room&gt;\"",
        V.sidebar_room_html(ctx, room),
    )
    @test occursin("data-sorted-list-number=", V.sidebar_room_html(ctx, direct))
    bot = (id = 9, name = "News", bot_token = "token", rooms = [room])
    @test occursin("/rooms/4/token/messages", V.view(ctx, :bots; bots = [bot]))
    @test occursin("Generate a new key", V.view(ctx, :bot_form; bot))
    @test occursin("Delete this chat bot", V.view(ctx, :bot_form; bot))
    keyed = merge(
        ctx,
        (app = (vapid_public_key = "public-key", vapid_private_key = "private-key"),),
    )
    keyed_room = V.view(keyed, :room; room)
    @test occursin("name=\"vapid-public-key\" content=\"public-key\"", keyed_room)
    @test !occursin("private-key", keyed_room)
    @test occursin("data-controller=\"notifications\"", keyed_room)
    @test occursin("data-notifications-target=\"bell\"", keyed_room)
    sound_message = merge(
        message,
        (
            sound = (
                name = "bell",
                url = "/assets/bell.mp3",
                image_url = nothing,
                text = "Bell",
            ),
        ),
    )
    @test occursin("data-controller=\"sound\"", V.message_html(ctx, sound_message))
    @test occursin(
        "data-sound-url-value=\"/assets/bell.mp3\"",
        V.message_html(ctx, sound_message),
    )
end

@testset "Streaming message HTML byte contract" begin
    V = JuliaWebViewsTests
    ctx = (
        app = nothing,
        user = (
            id = 1,
            name = "Alice <Admin>",
            email_address = "alice@example.test",
            bio = "Profile",
            role = 1,
        ),
        account = (
            name = "Campfire",
            custom_styles = "body { --brand: blue; }",
            join_code = "invite",
        ),
        base_url = "http://localhost:3000",
        csrf = "safe&token",
        path = "/session/transfers/token",
    )
    message = (
        id = 8,
        room_id = 4,
        creator_id = 1,
        author = ctx.user.name,
        client_message_id = "client&1",
        body = "<strong>Safe</strong>",
        created_at = "2026-10-12 12:00:00.000",
        room_name = "General <room>",
        boosts = [],
        attachment = nothing,
    )
    image_attachment = (
        url = "/file?a=1&b=2",
        filename = "image.png",
        content_type = "image/png",
        preview_url = "/file?a=1&b=2",
    )
    sound = (
        name = "Bell <&>",
        url = "/sounds/bell.mp3?a=1&b=2",
        image_url = nothing,
        text = "🔔 Ring <&>",
    )
    cases = (
        plain = message,
        boosts = merge(
            message,
            (
                boosts = [
                    (id = 1, booster_id = 2, content = "👍", author = "Bob <&>"),
                    (id = 2, booster_id = 3, content = "❤️", author = "Chloë"),
                ],
            ),
        ),
        image = merge(message, (attachment = image_attachment,)),
        video = merge(
            message,
            (
                attachment = merge(
                    image_attachment,
                    (filename = "movie.mp4", content_type = "video/mp4"),
                ),
            ),
        ),
        audio = merge(
            message,
            (
                attachment = merge(
                    image_attachment,
                    (filename = "song.mp3", content_type = "audio/mpeg"),
                ),
            ),
        ),
        file = merge(
            message,
            (
                attachment = (
                    url = "/file?a=1&b=2",
                    filename = "report <&>.txt",
                    content_type = "text/plain",
                ),
            ),
        ),
        sound_text = merge(message, (; sound)),
        sound_image = merge(
            message,
            (
                sound = merge(
                    sound,
                    (image_url = "/bell.png?a=1&b=2", width = 32, height = 48),
                ),
            ),
        ),
        attachment_over_sound = merge(message, (attachment = image_attachment, sound)),
        edited = merge(
            message,
            (
                created_at = "2026-10-12T12:00:00.123456Z",
                updated_at = "2026-10-12T12:01:00.123Z",
                avatar_token = "token<&>",
                author = "Chloë <&> \"'",
                body = "<p>日本語 😀</p>",
            ),
        ),
        fallback = merge(
            message,
            (
                created_at = missing,
                updated_at = missing,
                boosts = missing,
                client_message_id = nothing,
            ),
        ),
        string_id = merge(message, (id = "8&<>\"'", room_id = "4&<>\"'")),
    )
    # Digests come from b0d010d and preserve all output bytes,
    # including escaping, ordering, indentation, and trailing newlines.
    expected = (
        plain = "1bfb463b4080544c9e8514aaae03ccb88d595302e9a45fc6027da7d8e0f7e1a5",
        boosts = "ff4fef6098095101e41661bbf1ce93229aea5e1cb098f03e4f4a42f92767b981",
        image = "774dcc0ff399de1a5705fd430d4202f97c7c503d666b3759af93031590baf0e4",
        video = "d657af21709d2d96053be140ca6d184b99e70b80d081371f6594cc5904dee17a",
        audio = "7d258ff43fc0ef8aa0735081f83f9c4e60e92521c4e4234493cf2adbb172d920",
        file = "2cd360a8b401be6905754d918969b1c377310bcd62a68713aba0f91846010329",
        sound_text = "b4e6653e67afdbcb45a48f3ff595a1ea11245ea65533bb61cdd0aeee61ba6c30",
        sound_image = "78e09ec69cf0e1b7ea5f0ad7d5b76deed37528341d6c2cb9e3254264837a5826",
        attachment_over_sound = "774dcc0ff399de1a5705fd430d4202f97c7c503d666b3759af93031590baf0e4",
        edited = "d2c96325078fc815e37ceb8eeb4dc8e2080552968bcf9463678ce398bbf39ee1",
        fallback = "b1fa37c4441ec882445280268737181875c797bd2811f5faa824c65b4b279775",
        string_id = "4d107130b05f4623f9aba70f5825dc506d2b84c68bb4ea638a3f423899444192",
    )
    for (name, row) in pairs(cases)
        rendered = V.message_html(ctx, row)
        @test bytes2hex(sha256(rendered)) == expected[name]
        io = IOBuffer()
        print(io, "prefix|")
        @test V.message_html(io, ctx, row) === nothing
        print(io, "|suffix")
        @test String(take!(io)) == "prefix|" * rendered * "|suffix"
    end
    io = IOBuffer()
    @test V.boosts_html(io, ctx, cases.boosts) === nothing
    @test String(take!(io)) == V.boosts_html(ctx, cases.boosts)
    boost = first(cases.boosts.boosts)
    @test V.boost_html(io, ctx, boost, message.id) === nothing
    @test String(take!(io)) == V.boost_html(ctx, boost, message.id)

    order = Int[]
    JuliaWebViewsTests.@html io "$(push!(order, 1)[end]):$(push!(order, 2)[end])"
    @test order == [1, 2]
    @test String(take!(io)) == "1:2"
    JuliaWebViewsTests.@html io "unchanged<&>"
    @test String(take!(io)) == "unchanged<&>"
    @test_throws ArgumentError macroexpand(JuliaWebViewsTests, :(@html io nonliteral))
end
