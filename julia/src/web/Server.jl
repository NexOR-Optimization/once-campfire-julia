# Leave room for multipart framing around a 100 MiB attachment.
const MAX_REQUEST_BYTES = 101 * 1024^2
bot_route(path) = occursin(r"^/rooms/\d+/[^/]+/messages(?:/|$)", path)

function dispatch(ctx)
    response = route_media(ctx)
    response !== nothing && return response
    response = route_auth(ctx)
    response !== nothing && return response
    # Bot credentials are checked by the message handler against current DB state.
    bot = bot_route(ctx.path)
    if ctx.user === nothing && !bot
        ctx.account.id == 0 && return redirect("/first_run"; status = 302)
        return authentication_redirect(ctx)
    end
    for handler in (route_messages, route_rooms, route_search)
        response = handler(ctx)
        response !== nothing && return response
    end
    return html_response("Not found"; status = 404)
end

function gzip_accepted(req)
    HTTP.header(req, "Accept-Encoding") == "gzip" && return true
    accepted = false
    for entry in split(lowercase(HTTP.header(req, "Accept-Encoding")), ',')
        fields = strip.(split(entry, ';'))
        fields[1] in ("gzip", "*") || continue
        quality = 1.0
        for field in fields[2:end]
            startswith(field, "q=") &&
                (quality = something(tryparse(Float64, field[3:end]), 0.0))
        end
        fields[1] == "gzip" && return quality > 0
        accepted = quality > 0
    end
    return accepted
end

cache_route(method, path) =
    method == "GET" && (
        occursin(r"^/rooms/\d+(?:/messages)?$", path) ||
        path in ("/users/me/sidebar", "/searches")
    )
cacheable(ctx) = ctx.user !== nothing && cache_route(ctx.method, ctx.path)

function response_cache_key(app, req, user_id)
    return (
        Int64(user_id),
        String(req.target),
        request_origin(app, req) * "\n" * HTTP.header(req, "Cookie"),
    )
end

function cached_page(app, req, path, generation)
    isempty(app.cache) && return nothing
    token = session_token(app, req)
    token === nothing && return nothing
    # A cache hit needs fresh identity and access, but no display fields or
    # template context. Read only the fields needed to authorize this response.
    room = match(r"^/rooms/(\d+)", path)
    identity = cached_identity(app, token, room === nothing ? nothing : room[1])
    identity === nothing && return nothing
    mark_session_activity!(req, identity)
    id = identity.id
    page = get(app.cache, response_cache_key(app, req, id), nothing)
    page === nothing && return nothing
    identity.room_access || return nothing
    return generation == cache_generation!(app) ? page : nothing
end

function cached_response(ctx, page)
    return cached_response(ctx.req, page)
end
function cached_response(req::HTTP.Request, page)
    compressed = gzip_accepted(req)
    body = compressed ? page.compressed : page.body
    response = HTTP.Response(200, copy(page.headers), body)
    HTTP.setheader(response, "Vary"=>"Accept-Encoding")
    compressed && HTTP.setheader(response, "Content-Encoding"=>"gzip")
    return response
end

function cache_access(ctx)
    m = match(r"^/rooms/(\d+)", ctx.path)
    return m === nothing || reachable_room(ctx, m[1])
end

function security_headers!(response)
    HTTP.setheader(response, "X-Content-Type-Options"=>"nosniff")
    HTTP.setheader(response, "X-Frame-Options"=>"SAMEORIGIN")
    HTTP.setheader(response, "Referrer-Policy"=>"strict-origin-when-cross-origin")
    return response
end

function handle_request(app::WebApp, req::HTTP.Request)
    ncodeunits(req.target) <= 8192 ||
        return html_response("Request target too large"; status = 414)
    length(req.body) <= MAX_REQUEST_BYTES ||
        return html_response("Request too large"; status = 413)
    path, parameters = try
        uri = HTTP.URI(req.target)
        (String(uri.path), request_parameters(req, uri))
    catch error
        @debug "Invalid request parameters" exception=error
        return html_response("Invalid request"; status = 400)
    end
    original_method = uppercase(req.method)
    head = original_method == "HEAD"
    # Assign once so the reader callback captures a String, not a Core.Box.
    method = if head
        "GET"
    elseif original_method == "POST" && haskey(parameters, "_method")
        override = uppercase(string(parameters["_method"])::String)
        override in ("PATCH", "PUT", "DELETE") ? override : original_method
    else
        original_method
    end
    if method == "GET"
        response = asset_response(path)
        if response !== nothing
            head && (response.body=UInt8[])
            return security_headers!(response)
        end
        path == "/up" && return html_response(
            head ? "" :
            "<!doctype html><html><body style=\"background-color: green\"></body></html>",
        )
    end
    token_request =
        bot_route(path) &&
        isempty(HTTP.header(req, "Origin")) &&
        isempty(HTTP.header(req, "Sec-Fetch-Site"))
    if method ∉ ("GET", "OPTIONS") && !token_request && !same_origin_request(app, req)
        return html_response("Forbidden request origin"; status = 403)
    end
    events = Event[]
    response = if cache_route(method, path)
        with_reader(app) do reader
            reader_response =
                request_response(reader, req, parameters, path, method, events)
            # Finish writer effects before returning the lease, so pool shutdown
            # cannot close the writer while an in-flight read still needs it.
            refresh_session_activity!(app, req)
            publish_events!(app, events)
            return reader_response
        end
    else
        result = request_response(app, req, parameters, path, method, events)
        refresh_session_activity!(app, req)
        publish_events!(app, events)
        result
    end
    # External previews have their own DNS, redirect, size and time limits. They
    # must yield without holding the application database lock.
    response isa Context && (response = route_unfurl(response))
    head && (response.body = UInt8[])
    return security_headers!(response)
end

function request_response(app, req, parameters, path, method, events)
    return lock(app.lock) do
        app.closing && return html_response("Server shutting down"; status = 503)
        generation = cache_generation!(app)
        execute!(app, method == "GET" ? "BEGIN" : "BEGIN IMMEDIATE")
        active_transaction = true
        try
            if cache_route(method, path)
                page = cached_page(app, req, path, generation)
                if page !== nothing
                    execute!(app, "COMMIT")
                    active_transaction = false
                    return cached_response(req, page)
                end
            end
            ctx = current_context(app, req, parameters, path, method)
            pwa = method == "GET" ? serve_pwa(ctx) : nothing
            if pwa !== nothing
                execute!(app, "COMMIT")
                active_transaction = false
                return pwa
            end
            if method != "GET" &&
               scalar(
                app,
                "SELECT 1 FROM bans WHERE ip_address=? LIMIT 1",
                (client_ip(req),),
            ) !== nothing
                execute!(app, "ROLLBACK")
                active_transaction = false
                return html_response("Too many requests"; status = 429)
            end
            if path == "/unfurl_link"
                execute!(app, "COMMIT")
                active_transaction = false
                return ctx
            end
            use_cache = cacheable(ctx) && cache_access(ctx)
            key = response_cache_key(app, req, ctx.user === nothing ? 0 : ctx.user.id)
            # The observer epoch predates auth. Never admit a page whose snapshot
            # overlaps an external commit, even if the response itself is valid.
            cached =
                use_cache && generation == cache_generation!(app) ?
                get(app.cache, key, nothing) : nothing
            if cached !== nothing
                execute!(app, "COMMIT")
                active_transaction = false
                return cached_response(ctx, cached)
            end
            result = dispatch(ctx)
            if result.status < 400
                execute!(app, "COMMIT")
                active_transaction = false
                append!(events, ctx.events)
            else
                execute!(app, "ROLLBACK")
                active_transaction = false
            end
            if use_cache &&
               result.status == 200 &&
               !HTTP.hasheader(result, "Set-Cookie") &&
               generation == cache_generation!(app)
                body = Vector{UInt8}(result.body)
                compressed = transcode(GzipCompressor, body)
                bytes = length(body)+length(compressed)+sizeof(key[2])+sizeof(key[3])
                if bytes <= app.cache_budget && app.cache_entries > 0
                    if app.cache_bytes + bytes > app.cache_budget ||
                       length(app.cache) >= app.cache_entries
                        empty!(app.cache)
                        app.cache_bytes = 0
                    end
                    page = CachedPage(
                        codeunits(String(body)),
                        codeunits(String(compressed)),
                        copy(result.headers),
                    )
                    app.cache[key] = page
                    app.cache_bytes += bytes
                    result = cached_response(ctx, page)
                end
            end
            return result
        catch error
            active_transaction && execute!(app, "ROLLBACK")
            if error isa ArgumentError || error isa InexactError || error isa OverflowError
                return html_response("Invalid request"; status = 422)
            elseif error isa SQLite.SQLiteException &&
                   occursin("constraint", lowercase(sprint(showerror, error)))
                return html_response("Invalid or conflicting request"; status = 422)
            end
            @error "Request failed" method path exception=(error, catch_backtrace())
            return html_response("Internal server error"; status = 500)
        end
    end
end

function start_server(app::WebApp; host = "127.0.0.1", port = 3001, kwargs...)
    return threaded_listen!(
        host,
        port;
        verbose = false,
        readtimeout = 60,
        kwargs...,
    ) do stream
        req = stream.message
        if HTTP.WebSockets.isupgrade(req) && HTTP.URI(req.target).path == "/cable"
            return serve_cable(app, stream)
        end
        # Limit both fixed and chunked uploads before accumulating the full body.
        declared = tryparse(Int64, HTTP.header(req, "Content-Length", "0"))
        if declared === nothing || declared > MAX_REQUEST_BYTES || declared < 0
            HTTP.setstatus(stream, 413)
            HTTP.setheader(stream, "Connection"=>"close")
            HTTP.startwrite(stream)
            return
        end
        body = UInt8[]
        while !eof(stream)
            chunk = readavailable(stream)
            if length(body)+length(chunk) > MAX_REQUEST_BYTES
                HTTP.setstatus(stream, 413)
                HTTP.setheader(stream, "Connection"=>"close")
                HTTP.startwrite(stream)
                return
            end
            Base.append!(body, chunk)
        end
        req.body = body
        # The connection task keeps ownership while its worker borrows scratch.
        scratch = response_scratch()
        prepared = request_on_worker(prepare_response, app, req, scratch)
        write_prepared_response(stream, prepared)
        return nothing
    end
end
