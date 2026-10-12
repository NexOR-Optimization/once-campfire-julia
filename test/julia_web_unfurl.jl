using Test, HTTP, Sockets, LibCURL

if !isdefined(@__MODULE__, :Campfire)
    include("../julia/src/Campfire.jl")
end
if !isdefined(Campfire, :Web)
    Base.include(Campfire, joinpath(@__DIR__, "../julia/src/Web.jl"))
end
if !isdefined(Campfire.Web, :unfurl_metadata)
    Base.include(Campfire.Web, joinpath(@__DIR__, "../julia/src/web/Unfurl.jl"))
end
const UnfurlWeb = Campfire.Web

@testset "Julia link previews and SSRF boundaries" begin
    @testset "route authorization and rejected locations" begin
        user = UnfurlWeb.User(1, "Tester", "tester@example.test", "", 0, 0)
        ctx = (
            path = "/unfurl_link",
            user = user,
            method = "POST",
            params = Dict{String,Any}("url" => "file:///etc/passwd"),
        )
        @test UnfurlWeb.route_unfurl(ctx).status == 204
        @test UnfurlWeb.route_unfurl(merge(ctx, (user = nothing,))).status == 302
        @test UnfurlWeb.route_unfurl(merge(ctx, (method = "GET",))).status == 405
        @test UnfurlWeb.route_unfurl(merge(ctx, (params = Dict{String,Any}(),))).status ==
              400
        @test UnfurlWeb.route_unfurl(merge(ctx, (path = "/unknown",))) === nothing
    end
    @testset "public address policy" begin
        for address in (
            "0.1.2.3",
            "10.0.0.1",
            "100.64.0.1",
            "100.127.255.255",
            "127.0.0.1",
            "169.254.169.254",
            "172.16.0.1",
            "172.31.255.255",
            "192.0.0.1",
            "192.0.2.4",
            "192.88.99.1",
            "192.168.1.1",
            "198.18.0.1",
            "198.19.255.255",
            "198.51.100.1",
            "203.0.113.1",
            "224.0.0.1",
            "240.0.0.1",
            "255.255.255.255",
            "::",
            "::1",
            "::ffff:127.0.0.1",
            "64:ff9b::7f00:1",
            "fe80::1",
            "fc00::1",
            "ff02::1",
            "2001:db8::1",
            "2001::1",
            "2002:7f00:1::",
            "3fff::1",
        )
            @test !UnfurlWeb.public_address(parse(IPAddr, address))
        end
        for address in (
            "1.1.1.1",
            "8.8.8.8",
            "100.63.255.255",
            "100.128.0.0",
            "172.15.255.255",
            "172.32.0.1",
            "198.17.255.255",
            "198.20.0.1",
            "2001:4860:4860::8888",
            "2606:4700:4700::1111",
        )
            @test UnfurlWeb.public_address(parse(IPAddr, address))
        end
        @test !UnfurlWeb.public_address("8.8.8.8")
    end

    @testset "URL and DNS validation" begin
        for url in (
            "file:///etc/passwd",
            "ftp://example.test/file",
            "gopher://example.test/",
            "http://user:password@example.test",
            "http://example.test\\@localhost/",
            "http://example.test/\r\ninjected",
            "http://example%2etest/",
            "http://2130706433/",
            "http://0177.0.0.1/",
            "http://127.1/",
            "http://0x7f000001/",
            "http://127.0.0.1./",
            "http://example.test:99999/",
            "http://example.test:0/",
            "//example.test/",
            "",
        )
            @test UnfurlWeb.unfurl_uri(url) === nothing
        end
        @test UnfurlWeb.unfurl_uri("https://example.test/a?q=1") !== nothing
        @test UnfurlWeb.unfurl_uri("https://[2606:4700:4700::1111]/") !== nothing
        uri = UnfurlWeb.unfurl_uri("https://example.test")
        @test UnfurlWeb.public_resolution(uri, time() + 1; resolver = _ -> [ip"1.1.1.1"]) ==
              ip"1.1.1.1"
        @test UnfurlWeb.public_resolution(
            uri,
            time() + 1;
            resolver = _ -> [ip"1.1.1.1", ip"127.0.0.1"],
        ) === nothing
        @test UnfurlWeb.public_resolution(uri, time() + 1; resolver = _ -> IPAddr[]) ===
              nothing
        @test UnfurlWeb.public_resolution(
            uri,
            time() - 1;
            resolver = _ -> error("must not resolve"),
        ) === nothing
        @test UnfurlWeb.public_resolution(
            uri,
            time() + 0.02;
            resolver = _ -> (sleep(0.1); [ip"1.1.1.1"]),
        ) === nothing
    end

    @testset "metadata, providers, image policy and redirect revalidation" begin
        public_dns(host) = host == "private.test" ? [ip"127.0.0.1"] : [ip"1.1.1.1"]
        html = """
            <!doctype html><html><head>
            <meta property="og:title" content="A &lt;b&gt;safe&lt;/b&gt; &amp; useful title ☕">
            <meta name="og:description" content="Some &lt;script&gt;bad()&lt;/script&gt;description">
            <meta property="og:url" content="https://example.test/canonical">
            <meta property="og:image" content="https://images.test/photo.png">
            </head><body></body></html>
            """
        requests = Tuple{String,String}[]
        function fetcher(uri, ip, deadline; method = "GET")
            push!(requests, (string(uri), method))
            @test ip == ip"1.1.1.1"
            if method == "HEAD"
                return (
                    status = 200,
                    headers = Dict("content-type" => "image/png"),
                    body = UInt8[],
                )
            end
            return (
                status = 200,
                headers = Dict("content-type" => "text/html; charset=utf-8"),
                body = Vector{UInt8}(html),
            )
        end
        metadata = UnfurlWeb.unfurl_metadata(
            "https://example.test/original";
            resolver = public_dns,
            fetcher = fetcher,
        )
        @test metadata !== nothing
        @test metadata["title"] == "A safe & useful title ☕"
        @test metadata["description"] == "Some description"
        @test metadata["url"] == "https://example.test/canonical"
        @test metadata["image"] == "https://images.test/photo.png"
        @test requests == [
            ("https://example.test/original", "GET"),
            ("https://images.test/photo.png", "HEAD"),
        ]
        empty!(requests)
        @test UnfurlWeb.unfurl_metadata(
            "https://x.com/user/status/123";
            resolver = public_dns,
            fetcher = fetcher,
        ) !== nothing
        @test requests[1] == ("https://fxtwitter.com/user/status/123", "GET")
        @test UnfurlWeb.unfurl_metadata(
            "https://example.test/archive.zip";
            resolver = public_dns,
            fetcher = fetcher,
        ) === nothing
        @test UnfurlWeb.unfurl_metadata(
            "http://private.test/";
            resolver = public_dns,
            fetcher = fetcher,
        ) === nothing
        no_html(uri, ip, deadline; method = "GET") = (
            status = 200,
            headers = Dict("content-type" => "application/json"),
            body = Vector{UInt8}(html),
        )
        @test UnfurlWeb.unfurl_metadata(
            "https://example.test/";
            resolver = public_dns,
            fetcher = no_html,
        ) === nothing
        missing_title(uri, ip, deadline; method = "GET") = (
            status = 200,
            headers = Dict("content-type" => "text/html"),
            body = Vector{UInt8}("<meta property='og:description' content='description'>"),
        )
        @test UnfurlWeb.unfurl_metadata(
            "https://example.test/";
            resolver = public_dns,
            fetcher = missing_title,
        ) === nothing
        function denied_image(uri, ip, deadline; method = "GET")
            method == "HEAD" && return (
                status = 200,
                headers = Dict("content-type" => "image/svg+xml"),
                body = UInt8[],
            )
            return fetcher(uri, ip, deadline; method = method)
        end
        metadata = UnfurlWeb.unfurl_metadata(
            "https://example.test/";
            resolver = public_dns,
            fetcher = denied_image,
        )
        @test metadata["image"] === nothing
        unsafe_canonical(uri, ip, deadline; method = "GET") = (
            status = 200,
            headers = Dict("content-type" => "text/html"),
            body = Vector{UInt8}(
                replace(html, "https://example.test/canonical" => "http://private.test/"),
            ),
        )
        metadata = UnfurlWeb.unfurl_metadata(
            "https://example.test/original";
            resolver = public_dns,
            fetcher = unsafe_canonical,
        )
        @test metadata["url"] == "https://example.test/original"
        redirect_count = Ref(0)
        function redirect_private(uri, ip, deadline; method = "GET")
            redirect_count[] += 1
            return (
                status = 302,
                headers = Dict("location" => "http://private.test/internal"),
                body = UInt8[],
            )
        end
        @test UnfurlWeb.restricted_fetch(
            "https://example.test/",
            time() + 1;
            resolver = public_dns,
            fetcher = redirect_private,
        ) === nothing
        @test redirect_count[] == 1
        redirect_count[] = 0
        function redirect_forever(uri, ip, deadline; method = "GET")
            redirect_count[] += 1
            return (
                status = 302,
                headers = Dict("location" => "https://example.test/again"),
                body = UInt8[],
            )
        end
        @test UnfurlWeb.restricted_fetch(
            "https://example.test/",
            time() + 2;
            resolver = public_dns,
            fetcher = redirect_forever,
        ) === nothing
        @test redirect_count[] == 10
        function relative_redirect(uri, ip, deadline; method = "GET")
            return (status = 302, headers = Dict("location" => "/internal"), body = UInt8[])
        end
        @test UnfurlWeb.restricted_fetch(
            "https://example.test/",
            time() + 1;
            resolver = public_dns,
            fetcher = relative_redirect,
        ) === nothing
        oversized(uri, ip, deadline; method = "GET") = (
            status = 200,
            headers = Dict("content-type" => "text/html"),
            body = zeros(UInt8, UnfurlWeb.UNFURL_MAX_BYTES + 1),
        )
        @test UnfurlWeb.unfurl_metadata(
            "https://example.test/";
            resolver = public_dns,
            fetcher = oversized,
        ) === nothing
    end

    @testset "bounded native transport and pinned address" begin
        # The lower-level transport accepts an already-validated address. The
        # fake hostname must resolve only through its explicit CURLOPT_RESOLVE
        # entry, while the HTTP Host header still identifies the original URL.
        listener = Sockets.listen(ip"127.0.0.1", 0)
        port = Sockets.getsockname(listener)[2]
        server = HTTP.serve!(listener; verbose = false) do request
            if request.target == "/large"
                return HTTP.Response(
                    200,
                    ["Content-Type" => "text/html"],
                    repeat("x", UnfurlWeb.UNFURL_MAX_BYTES + 1),
                )
            elseif request.target == "/echo"
                return HTTP.Response(
                    200,
                    [
                        "X-Seen-Method" => request.method,
                        "X-Seen-Encoding" => HTTP.header(request, "Content-Encoding"),
                    ],
                    request.body,
                )
            end
            return HTTP.Response(
                200,
                [
                    "Content-Type" => "text/html",
                    "X-Seen-Host" => HTTP.header(request, "Host"),
                ],
                "<html>native transport</html>",
            )
        end
        try
            uri = HTTP.URI("http://never-resolve-this.test:$port/")
            response = UnfurlWeb.curl_unfurl_fetch(uri, ip"127.0.0.1", time() + 2)
            @test response !== nothing
            @test response.status == 200
            @test response.headers["x-seen-host"] == "never-resolve-this.test:$port"
            @test String(response.body) == "<html>native transport</html>"
            head =
                UnfurlWeb.curl_unfurl_fetch(uri, ip"127.0.0.1", time() + 2; method = "HEAD")
            @test head !== nothing
            @test isempty(head.body)
            encrypted_bytes = UInt8[0x00, 0x01, 0x7f, 0x80, 0xff]
            posted = UnfurlWeb.curl_unfurl_fetch(
                HTTP.URI("http://never-resolve-this.test:$port/echo"),
                ip"127.0.0.1",
                time() + 2;
                method = "POST",
                body = encrypted_bytes,
                headers = ["Content-Encoding" => "aes128gcm"],
            )
            @test posted !== nothing
            @test posted.headers["x-seen-method"] == "POST"
            @test posted.headers["x-seen-encoding"] == "aes128gcm"
            @test posted.body == encrypted_bytes
            @test UnfurlWeb.curl_unfurl_fetch(
                HTTP.URI("http://never-resolve-this.test:$port/large"),
                ip"127.0.0.1",
                time() + 2,
            ) === nothing
            @test UnfurlWeb.curl_unfurl_fetch(uri, ip"127.0.0.1", time() - 1) === nothing
        finally
            close(server)
        end
    end
end
