# Serve the application's actual JavaScript and styles directly. Only browser
# dependencies supplied by Ruby gems are vendored; no Ruby runtime is needed.
const WEB_ROOT = normpath(joinpath(@__DIR__, "../../.."))
const WEB_VENDOR = joinpath(WEB_ROOT, "julia/assets/vendor")
const ASSET_PATHS = let paths = Dict{String,String}()
    for directory in (
        "app/javascript",
        "vendor/javascript",
        "app/assets/stylesheets",
        "app/assets/images",
        "app/assets/sounds",
        "julia/assets/vendor",
    )
        root = joinpath(WEB_ROOT, directory)
        isdir(root) || continue
        for (folder, _, files) in walkdir(root), file in files
            path = joinpath(folder, file)
            paths[replace(relpath(path, root), '\\' => '/')] = path
        end
    end
    paths
end

const ASSET_MIME_TYPES = Dict(
    ".js" => "text/javascript; charset=utf-8",
    ".css" => "text/css; charset=utf-8",
    ".svg" => "image/svg+xml",
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp",
    ".mp3" => "audio/mpeg",
    ".woff2" => "font/woff2",
)

# A fixed, bounded set of immutable deployment assets. Each response owns its
# headers but shares these bytes. Restart after changing frontend source files.
const ASSET_CONTENT =
    let content = Dict{String,Tuple{String,Base.CodeUnits{UInt8,String}}}()
        for (name, file) in ASSET_PATHS
            Base.include_dependency(file)
            mime = get(
                ASSET_MIME_TYPES,
                lowercase(splitext(file)[2]),
                "application/octet-stream",
            )
            content[name] = (mime, codeunits(read(file, String)))
        end
        content
    end

const BROWSER_IMPORTS =
    let imports = Dict(
            "application" => "/assets/application.js",
            "@hotwired/stimulus" => "/assets/stimulus.min-4b1e420e.js",
            "@hotwired/stimulus-loading" => "/assets/stimulus-loading-1fc53fe7.js",
            "@hotwired/turbo-rails" => "/assets/turbo-a1e3a50a.js",
            "@rails/actioncable" => "/assets/actioncable.esm-e0ec9819.js",
            "@rails/request.js" => "/assets/@rails--request.js",
            "lexxy" => "/assets/lexxy-a21f41d4.js",
            "highlight.js" => "/assets/highlight.js/core.js",
        )
        for name in keys(ASSET_PATHS)
            endswith(name, ".js") || continue
            any(
                startswith(name, prefix * "/") for prefix in
                ("initializers", "controllers", "helpers", "models", "lib", "languages")
            ) || continue
            key = replace(name[1:(end-3)], r"/index$" => "")
            imports[key] = "/assets/" * name
        end
        imports
    end

const BROWSER_IMPORTMAP =
    "{\"imports\":{" *
    join(
        [
            "\"" * key * "\":\"" * BROWSER_IMPORTS[key] * "\"" for
            key in sort!(collect(keys(BROWSER_IMPORTS)))
        ],
        ",",
    ) *
    "}}"

const STYLESHEET_TAGS = join(
    [
        "<link rel=\"stylesheet\" href=\"/assets/" *
        name *
        "\" data-turbo-track=\"reload\">" for
        name in sort!(collect(keys(ASSET_PATHS))) if endswith(name, ".css")
    ],
    "\n",
)

function asset_response(path::AbstractString)
    startswith(path, "/assets/") || return nothing
    key = String(path[9:end])
    content = get(ASSET_CONTENT, key, nothing)
    content === nothing && return HTTP.Response(404)
    content_type, body = content
    return HTTP.Response(
        200,
        [
            "Content-Type" => content_type,
            "Cache-Control" => "public, max-age=3600",
            "X-Content-Type-Options" => "nosniff",
        ],
        body,
    )
end

serve_asset(ctx) = asset_response(ctx.path)

function serve_pwa(ctx)
    ctx.method == "GET" || return nothing
    if ctx.path in ("/service-worker", "/service-worker.js")
        return HTTP.Response(
            200,
            [
                "Content-Type" => "text/javascript; charset=utf-8",
                "Service-Worker-Allowed" => "/",
                "Cache-Control" => "no-cache",
            ],
            read(joinpath(WEB_ROOT, "app/views/pwa/service_worker.js")),
        )
    elseif ctx.path in ("/webmanifest", "/webmanifest.json")
        manifest = (
            name = value(ctx.account, :name, "Campfire"),
            icons = [
                (src = "/account/logo?size=small", type = "image/png", sizes = "192x192"),
                (src = "/account/logo", type = "image/png", sizes = "512x512"),
                (
                    src = "/account/logo",
                    type = "image/png",
                    sizes = "512x512",
                    purpose = "maskable",
                ),
            ],
            start_url = "/",
            display = "standalone",
            scope = "/",
            description = "A chat app from the makers of Basecamp and HEY.",
            categories = ["social", "business", "productivity"],
            theme_color = "#ffffff",
            background_color = "#ffffff",
            shortcuts = [
                (
                    name = "New chat room",
                    description = "Open Campfire and start a new chat room",
                    url = "/rooms/opens/new",
                    icons = [(src = "/assets/add.svg", sizes = "any")],
                ),
                (
                    name = "My profile",
                    description = "Open Campfire and view your profile",
                    url = "/users/me/profile",
                    icons = [(src = "/assets/person.svg", sizes = "any")],
                ),
            ],
            screenshots = [
                (
                    src = "/assets/screenshots/android-chat.png",
                    sizes = "1080x2400",
                    form_factor = "narrow",
                    label = "Campfire is an installable, self-hosted group chat system.",
                ),
                (
                    src = "/assets/screenshots/android-sidebar.png",
                    sizes = "1080x2400",
                    form_factor = "narrow",
                    label = "Easily invite people. Make rooms. @mentions, DMs, and mobile support.",
                ),
                (
                    src = "/assets/screenshots/android-dark-mode.png",
                    sizes = "1080x2400",
                    form_factor = "narrow",
                    label = "Full support for dark mode, customizable to your brand.",
                ),
            ],
        )
        return HTTP.Response(
            200,
            [
                "Content-Type" => "application/manifest+json; charset=utf-8",
                "Cache-Control" => "no-cache",
            ],
            JSON3.write(manifest),
        )
    end
    return nothing
end
