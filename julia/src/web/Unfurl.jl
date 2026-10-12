using LibCURL, Sockets

const UNFURL_MAX_BYTES = 5 * 1024^2
const UNFURL_MAX_HEADERS = 64 * 1024
const UNFURL_DEADLINE = 10.0
const UNFURL_IMAGE_TYPES = Set(["image/jpeg", "image/png", "image/gif", "image/webp"])
const UNFURL_MEDIA_PATH =
    r"(?i)\.(?:zip|tar|gz|bz2|xz|rar|7z|dmg|exe|msi|pkg|deb|iso|jpg|jpeg|png|gif|bmp|mp4|mov|avi|mkv|wmv|flv|heic|heif|mp3|wav|ogg|aac|wma|webm|ogv|mpg|mpeg)(?:$|[/?#])"

function public_address(ip::IPv4)
    n = ip.host
    blocked = (
        (0x00000000, 8),
        (0x0a000000, 8),
        (0x64400000, 10),
        (0x7f000000, 8),
        (0xa9fe0000, 16),
        (0xac100000, 12),
        (0xc0000000, 24),
        (0xc0000200, 24),
        (0xc0586300, 24),
        (0xc0a80000, 16),
        (0xc6120000, 15),
        (0xc6336400, 24),
        (0xcb007100, 24),
        (0xe0000000, 3),
    )
    return all(pair -> n >> (32 - pair[2]) != pair[1] >> (32 - pair[2]), blocked)
end

function public_address(ip::IPv6)
    n = ip.host
    # Only global unicast is eligible. Exclude documentation, transition and
    # special-purpose prefixes within it, including mapped IPv4 and NAT64 by
    # virtue of their being outside 2000::/3.
    return n >> 125 == 1 &&
           n >> 96 != 0x20010db8 &&
           n >> 105 != 0x100080 &&
           n >> 112 != 0x2002 &&
           n >> 108 != 0x3fff0
end
public_address(::Any) = false

function parse_address(type, text)
    try
        return parse(type, text)
    catch
        return nothing
    end
end

function unfurl_uri(url)
    url isa AbstractString || return nothing
    1 <= ncodeunits(url) <= 8192 || return nothing
    any(c -> Int(c) <= 0x20 || c == '\\' || Int(c) == 0x7f, url) && return nothing
    uri = try
        HTTP.URI(url)
    catch
        return nothing
    end
    uri.scheme in ("http", "https") || return nothing
    isempty(uri.userinfo) || return nothing
    host = String(uri.host)
    isempty(host) && return nothing
    if occursin(':', host)
        parse_address(IPv6, host) === nothing && return nothing
    else
        occursin(r"^[A-Za-z0-9.-]+$", host) || return nothing
        # curl recognizes octal, hex and short numeric forms as IP literals.
        # Refuse them so its URL interpretation cannot bypass CURLOPT_RESOLVE.
        if occursin(r"^(?i:[0-9.]+|0x[0-9a-f.]+)$", host)
            literal = parse_address(IPv4, host)
            (literal === nothing || string(literal) != host) && return nothing
        end
        any(label -> startswith(lowercase(label), "0x"), split(host, '.')) && return nothing
    end
    if !isempty(uri.port)
        port = tryparse(Int, uri.port)
        (port === nothing || !(1 <= port <= 65535)) && return nothing
    end
    return uri
end

function public_resolution(uri, deadline; resolver = Sockets.getalladdrinfo)
    uri === nothing && return nothing
    time() < deadline || return nothing
    task = @async try
        resolver(String(uri.host))
    catch
        IPAddr[]
    end
    timedwait(() -> istaskdone(task), max(0.001, deadline - time()); pollint = 0.01) ==
    :ok || return nothing
    addresses = fetch(task)
    isempty(addresses) && return nothing
    all(public_address, addresses) || return nothing
    return first(addresses)
end

mutable struct UnfurlCapture
    body::IOBuffer
    headers::IOBuffer
    deadline::Float64
    failed::Bool
end

function unfurl_body_callback(
    data::Ptr{UInt8},
    size::Csize_t,
    count::Csize_t,
    opaque::Ptr{Cvoid},
)::Csize_t
    capture = unsafe_pointer_to_objref(opaque)::UnfurlCapture
    bytes = size * count
    try
        if time() >= capture.deadline || bytes > UNFURL_MAX_BYTES - position(capture.body)
            capture.failed = true
            return 0
        end
        write(capture.body, unsafe_wrap(Vector{UInt8}, data, Int(bytes); own = false))
        return bytes
    catch
        capture.failed = true
        return 0
    end
end

function unfurl_header_callback(
    data::Ptr{UInt8},
    size::Csize_t,
    count::Csize_t,
    opaque::Ptr{Cvoid},
)::Csize_t
    capture = unsafe_pointer_to_objref(opaque)::UnfurlCapture
    bytes = size * count
    try
        if time() >= capture.deadline ||
           bytes > UNFURL_MAX_HEADERS - position(capture.headers)
            capture.failed = true
            return 0
        end
        write(capture.headers, unsafe_wrap(Vector{UInt8}, data, Int(bytes); own = false))
        return bytes
    catch
        capture.failed = true
        return 0
    end
end

struct UnfurlCurlMessage
    message::Cuint
    easy::Ptr{Cvoid}
    result::Cuint
end

function curl_unfurl_fetch(
    uri,
    ip,
    deadline;
    method = "GET",
    body = UInt8[],
    headers = Pair{String,String}[],
)
    time() < deadline || return nothing
    easy, multi = LibCURL.curl_easy_init(), LibCURL.curl_multi_init()
    (easy == C_NULL || multi == C_NULL) && error("cannot initialize curl")
    resolutions = Ptr{Cvoid}(C_NULL)
    request_headers = Ptr{Cvoid}(C_NULL)
    capture = UnfurlCapture(IOBuffer(), IOBuffer(), deadline, false)
    try
        host = String(uri.host)
        port = isempty(uri.port) ? (uri.scheme == "https" ? "443" : "80") : String(uri.port)
        address = ip isa IPv6 ? "[$ip]" : string(ip)
        resolutions = LibCURL.curl_slist_append(resolutions, "$host:$port:$address")
        resolutions == C_NULL && error("cannot pin curl resolution")
        setopt(option, value) =
            LibCURL.curl_easy_setopt(easy, option, value) == LibCURL.CURLE_OK ||
            error("cannot configure curl")
        setopt(LibCURL.CURLOPT_URL, string(uri))
        setopt(LibCURL.CURLOPT_RESOLVE, resolutions)
        setopt(LibCURL.CURLOPT_PROXY, "")
        setopt(LibCURL.CURLOPT_NOPROXY, "*")
        setopt(LibCURL.CURLOPT_PROTOCOLS, LibCURL.CURLPROTO_HTTP | LibCURL.CURLPROTO_HTTPS)
        setopt(LibCURL.CURLOPT_FOLLOWLOCATION, 0)
        setopt(LibCURL.CURLOPT_SSL_VERIFYPEER, 1)
        setopt(LibCURL.CURLOPT_SSL_VERIFYHOST, 2)
        setopt(LibCURL.CURLOPT_CAINFO, LibCURL.cacert)
        setopt(LibCURL.CURLOPT_NOSIGNAL, 1)
        setopt(
            LibCURL.CURLOPT_CONNECTTIMEOUT_MS,
            min(7000, max(1, ceil(Int, (deadline - time()) * 1000))),
        )
        setopt(LibCURL.CURLOPT_TIMEOUT_MS, max(1, ceil(Int, (deadline - time()) * 1000)))
        setopt(LibCURL.CURLOPT_MAXFILESIZE_LARGE, UNFURL_MAX_BYTES)
        setopt(LibCURL.CURLOPT_ACCEPT_ENCODING, "identity")
        setopt(LibCURL.CURLOPT_USERAGENT, "Campfire Julia link preview")
        setopt(LibCURL.CURLOPT_NOBODY, method == "HEAD" ? 1 : 0)
        if method == "POST"
            setopt(LibCURL.CURLOPT_POST, 1)
            setopt(LibCURL.CURLOPT_POSTFIELDSIZE, length(body))
            setopt(LibCURL.CURLOPT_POSTFIELDS, body)
        elseif !(method in ("GET", "HEAD"))
            throw(ArgumentError("unsupported restricted HTTP method"))
        end
        for (name, value) in headers
            occursin(r"[\r\n]", name * value) && throw(ArgumentError("invalid HTTP header"))
            request_headers =
                LibCURL.curl_slist_append(request_headers, name * ": " * value)
            request_headers == C_NULL && error("cannot allocate HTTP headers")
        end
        request_headers == C_NULL || setopt(LibCURL.CURLOPT_HTTPHEADER, request_headers)
        setopt(
            LibCURL.CURLOPT_WRITEFUNCTION,
            @cfunction(
                unfurl_body_callback,
                Csize_t,
                (Ptr{UInt8}, Csize_t, Csize_t, Ptr{Cvoid})
            )
        )
        setopt(
            LibCURL.CURLOPT_HEADERFUNCTION,
            @cfunction(
                unfurl_header_callback,
                Csize_t,
                (Ptr{UInt8}, Csize_t, Csize_t, Ptr{Cvoid})
            )
        )
        GC.@preserve capture body begin
            setopt(LibCURL.CURLOPT_WRITEDATA, pointer_from_objref(capture))
            setopt(LibCURL.CURLOPT_HEADERDATA, pointer_from_objref(capture))
            LibCURL.curl_multi_add_handle(multi, easy) == LibCURL.CURLM_OK || return nothing
            running = Cint[1]
            while running[1] > 0
                time() < deadline || return nothing
                LibCURL.curl_multi_perform(multi, running) == LibCURL.CURLM_OK ||
                    return nothing
                running[1] > 0 && sleep(min(0.01, max(0.001, deadline - time())))
            end
            info = LibCURL.curl_multi_info_read(multi, Cint[0])
            info == C_NULL && return nothing
            message = unsafe_load(Ptr{UnfurlCurlMessage}(info))
            (
                message.message == LibCURL.CURLMSG_DONE &&
                message.result == LibCURL.CURLE_OK &&
                !capture.failed
            ) || return nothing
        end
        status = Clong[0]
        LibCURL.curl_easy_getinfo(easy, LibCURL.CURLINFO_RESPONSE_CODE, status)
        headers = Dict{String,String}()
        for line in split(String(take!(capture.headers)), "\r\n")
            if startswith(line, "HTTP/")
                empty!(headers)
            elseif occursin(':', line)
                key, value = split(line, ':'; limit = 2)
                headers[lowercase(strip(key))] = strip(value)
            end
        end
        return (status = Int(status[1]), headers = headers, body = take!(capture.body))
    finally
        LibCURL.curl_multi_remove_handle(multi, easy)
        LibCURL.curl_easy_cleanup(easy)
        LibCURL.curl_multi_cleanup(multi)
        resolutions == C_NULL || LibCURL.curl_slist_free_all(resolutions)
        request_headers == C_NULL || LibCURL.curl_slist_free_all(request_headers)
    end
end

function restricted_fetch(
    url,
    deadline;
    method = "GET",
    resolver = Sockets.getalladdrinfo,
    fetcher = curl_unfurl_fetch,
)
    current = url
    for _ in 1:10
        uri = unfurl_uri(current)
        uri === nothing && return nothing
        ip = public_resolution(uri, deadline; resolver = resolver)
        ip === nothing && return nothing
        response = fetcher(uri, ip, deadline; method = method)
        response === nothing && return nothing
        if 300 <= response.status <= 399
            # Rails rejects relative redirects, and every absolute redirect is
            # resolved and validated again before opening the next connection.
            current = get(response.headers, "location", "")
        else
            return response
        end
    end
    return nothing
end

function opengraph_nodes!(attributes, pointer, depth = 0)
    depth > 128 && return nothing
    while pointer != C_NULL
        node = unsafe_load(Ptr{HTMLNode}(pointer))
        if node.kind == 1
            tag = lowercase(unsafe_string(node.name))
            if tag == "meta"
                name = xml_property(pointer, "property")
                isempty(name) && (name = xml_property(pointer, "name"))
                if name in ("og:title", "og:description", "og:url", "og:image")
                    content = xml_property(pointer, "content")
                    isempty(content) || (attributes[name[4:end]] = content)
                end
            end
            opengraph_nodes!(attributes, node.children, depth + 1)
        end
        pointer = node.next
    end
    return nothing
end

function opengraph_attributes(html)
    length(html) <= UNFURL_MAX_BYTES || return Dict{String,String}()
    document = ccall(
        (:htmlReadMemory, XML_LIBRARY),
        Ptr{Cvoid},
        (Ptr{UInt8}, Cint, Cstring, Cstring, Cint),
        html,
        length(html),
        C_NULL,
        "UTF-8",
        1 | 32 | 64 | 2048,
    )
    document == C_NULL && return Dict{String,String}()
    try
        root =
            ccall((:xmlDocGetRootElement, XML_LIBRARY), Ptr{Cvoid}, (Ptr{Cvoid},), document)
        attributes = Dict{String,String}()
        opengraph_nodes!(attributes, root)
        return attributes
    finally
        ccall((:xmlFreeDoc, XML_LIBRARY), Cvoid, (Ptr{Cvoid},), document)
    end
end

function unfurl_metadata(
    url;
    resolver = Sockets.getalladdrinfo,
    fetcher = curl_unfurl_fetch,
    deadline = time() + UNFURL_DEADLINE,
)
    try
        uri = unfurl_uri(url)
        uri === nothing && return nothing
        occursin(UNFURL_MEDIA_PATH, uri.path) && return nothing
        original = String(url)
        request_url =
            if lowercase(uri.host) in
               ("twitter.com", "www.twitter.com", "x.com", "www.x.com") &&
               !(uri.path in ("", "/"))
                string(HTTP.URI(uri; host = "fxtwitter.com"))
            else
                original
            end
        response =
            restricted_fetch(request_url, deadline; resolver = resolver, fetcher = fetcher)
        response === nothing && return nothing
        response.status == 200 || return nothing
        lowercase(strip(first(split(get(response.headers, "content-type", ""), ';')))) ==
        "text/html" || return nothing
        length(response.body) <= UNFURL_MAX_BYTES || return nothing
        attributes = opengraph_attributes(response.body)
        title = last(sanitize_rich_text(get(attributes, "title", "")))
        description = last(sanitize_rich_text(get(attributes, "description", "")))
        (isempty(title) || isempty(description)) && return nothing
        canonical = get(attributes, "url", "")
        public_resolution(unfurl_uri(canonical), deadline; resolver = resolver) ===
        nothing && (canonical = original)
        image = get(attributes, "image", "")
        image_url = nothing
        if !isempty(image)
            checked = restricted_fetch(
                image,
                deadline;
                method = "HEAD",
                resolver = resolver,
                fetcher = fetcher,
            )
            if checked !== nothing &&
               200 <= checked.status < 300 &&
               lowercase(get(checked.headers, "content-type", "")) in UNFURL_IMAGE_TYPES
                image_url = image
            end
        end
        time() < deadline || return nothing
        return Dict(
            "title" => title,
            "description" => description,
            "url" => canonical,
            "image" => image_url,
        )
    catch error
        error isa InterruptException && rethrow()
        return nothing
    end
end

function route_unfurl(ctx)
    ctx.path == "/unfurl_link" || return nothing
    ctx.user === nothing && return redirect("/session/new"; status = 302)
    ctx.method == "POST" || return html_response("Method not allowed"; status = 405)
    url = param(ctx, "url")
    isempty(url) && return html_response("URL is required"; status = 400)
    metadata = unfurl_metadata(url)
    return metadata === nothing ? HTTP.Response(204) : json_response(metadata)
end
