using Test, HTTP, Sockets
if !isdefined(@__MODULE__, :Campfire)
    include(joinpath(@__DIR__, "../julia/src/Campfire.jl"))
end

mutable struct TransportCountingIO <: IO
    output::IOBuffer
    writes::Int
    open::Bool
end
TransportCountingIO() = TransportCountingIO(IOBuffer(), 0, true)
Base.isopen(io::TransportCountingIO) = io.open
Base.close(io::TransportCountingIO) = (io.open = false; nothing)
function Base.unsafe_write(io::TransportCountingIO, pointer::Ptr{UInt8}, bytes::UInt)
    isopen(io) || throw(Base.IOError("closed transport", Base.UV_EPIPE))
    io.writes += 1
    return unsafe_write(io.output, pointer, bytes)
end

function transport_response_stream(body; method = "GET", status = 200, headers = nothing)
    io = TransportCountingIO()
    request = HTTP.Request(method, "/")
    request.response.status = status
    if headers === nothing
        bytes = body isa AbstractString ? ncodeunits(body) : length(body)
        HTTP.setheader(request.response, "Content-Length" => string(bytes))
    else
        for header in headers
            HTTP.appendheader(
                request.response,
                SubString(first(header)) => SubString(last(header)),
            )
        end
    end
    connection = HTTP.Connections.Connection(io)
    return HTTP.Stream(request, connection), io
end

function prepare_transport_response(stream, body, scratch = Campfire.Web.ResponseScratch())
    response = HTTP.Response(stream.message.response.status)
    response.body = body
    return Campfire.Web.prepare_response(stream.message, response, scratch)
end

mutable struct TransportGatedIO <: IO
    output::IOBuffer
    entered::Channel{Nothing}
    release::Channel{Nothing}
end
Base.isopen(::TransportGatedIO) = true
function Base.unsafe_write(io::TransportGatedIO, pointer::Ptr{UInt8}, bytes::UInt)
    put!(io.entered, nothing)
    take!(io.release)
    return unsafe_write(io.output, pointer, bytes)
end

function response_preparation_bytes(body, scratch)
    request = HTTP.Request("GET", "/")
    response = HTTP.Response(200, body)
    return @allocated Campfire.Web.prepare_response(request, response, scratch)
end

@testset "Reusable response buffer ownership" begin
    W = Campfire.Web
    scratch = W.ResponseScratch()
    @test scratch.wire === nothing
    retained = nothing
    for body in (repeat("large response", 3000), "small", "x", "")
        stream, io = transport_response_stream(body)
        prepared = prepare_transport_response(stream, body, scratch)
        @test prepared.wire === scratch.wire
        @test prepared.wire isa IOBuffer
        @test prepared.wire.maxsize == W.MAX_COALESCED_RESPONSE_BYTES
        if retained === nothing
            retained = prepared.wire
        else
            @test prepared.wire === retained
        end
        @test position(prepared.wire) == 0
        W.write_prepared_response(stream, prepared)
        expected = IOBuffer()
        HTTP.Messages.writeheaders(expected, stream.message.response)
        write(expected, body)
        @test take!(io.output) == take!(expected)
        @test eof(prepared.wire)
    end

    for existing in (false, true)
        skipped = existing ? scratch : W.ResponseScratch()
        before = skipped.wire
        for oversized_headers in (false, true)
            body =
                oversized_headers ? "small" :
                repeat("b", W.MAX_COALESCED_RESPONSE_BYTES + 1)
            stream, io = transport_response_stream(body)
            if oversized_headers
                HTTP.setheader(
                    stream,
                    "X-Large" => repeat("h", W.MAX_COALESCED_RESPONSE_BYTES),
                )
            end
            before_position = before === nothing ? nothing : position(before)
            prepared = prepare_transport_response(stream, body, skipped)
            @test prepared.wire === nothing
            @test skipped.wire === before
            before === nothing || @test position(before) == before_position
            before === nothing || @test before.maxsize == W.MAX_COALESCED_RESPONSE_BYTES
            W.write_prepared_response(stream, prepared)
            @test endswith(String(take!(io.output)), body)
        end
        stream, io = transport_response_stream("after oversized response")
        prepared = prepare_transport_response(stream, "after oversized response", skipped)
        W.write_prepared_response(stream, prepared)
        @test endswith(String(take!(io.output)), "after oversized response")
        @test prepared.wire.maxsize == W.MAX_COALESCED_RESPONSE_BYTES
    end

    # Each connection lends its holder to an awaited worker. Concurrent I/O
    # threads must retain separate holders even when another connection reuses
    # its buffer while a socket write is still waiting for completion.
    holders = Channel{Any}(2)
    entered = Channel{Nothing}(2)
    release = Channel{Nothing}(2)
    rendezvous = Threads.Atomic{Int}(0)
    pending =
        [TransportGatedIO(IOBuffer(), Channel{Nothing}(1), Channel{Nothing}(1)) for _ = 1:2]
    connections = [
        Threads.@spawn :interactive begin
            local holder = W.response_scratch()
            local io_thread = Threads.threadid()
            local io_pool = Threads.threadpool()
            if Threads.nthreads(:interactive) > 1
                # This bounded rendezvous requires two threads to run without
                # fixing either task to a thread or assuming it cannot migrate.
                Threads.atomic_add!(rendezvous, 1)
                local deadline = time_ns() + UInt64(2_000_000_000)
                while rendezvous[] < 2 && time_ns() < deadline
                end
            end
            put!(holders, (; holder, io_thread, io_pool))
            local body = repeat("connection $index λ\0", index * 100)
            local request = HTTP.Request("GET", "/")
            local stream =
                HTTP.Stream(request, HTTP.Connections.Connection(pending[index]))
            local prepared, worker_pool =
                W.request_on_worker(holder, request, body) do holder, request, body
                    put!(entered, nothing)
                    take!(release)
                    local response = HTTP.Response(200, body)
                    return W.prepare_response(request, response, holder),
                    Threads.threadpool()
                end
            local same_holder = holder === W.response_scratch()
            local expected = IOBuffer()
            HTTP.Messages.writeheaders(expected, request.response)
            write(expected, body)
            W.write_prepared_response(stream, prepared)
            local first_bytes = take!(pending[index].output)

            local next_body = "reused connection $index"
            local next_stream, next_io = transport_response_stream(next_body)
            local next_prepared = W.request_on_worker(
                holder,
                next_stream,
                next_body,
            ) do holder, next_stream, next_body
                return prepare_transport_response(next_stream, next_body, holder)
            end
            same_holder &= holder === W.response_scratch()
            W.write_prepared_response(next_stream, next_prepared)
            return (;
                same_holder,
                holder,
                prepared,
                worker_pool,
                reused = next_prepared.wire === prepared.wire,
                first_bytes,
                expected = take!(expected),
                next_bytes = String(take!(next_io.output)),
                next_body,
            )
        end for index = 1:2
    ]
    first_owner, second_owner = take!(holders), take!(holders)
    take!(entered)
    take!(entered)
    @test first_owner.holder !== second_owner.holder
    io_pool = Threads.nthreads(:interactive) > 0 ? :interactive : :default
    @test first_owner.io_pool == second_owner.io_pool == io_pool
    if Threads.nthreads(:interactive) > 1
        @test first_owner.io_thread != second_owner.io_thread
    end
    put!(release, nothing)
    put!(release, nothing)
    try
        take!(pending[1].entered)
        take!(pending[2].entered)
        @test all(!istaskdone(task) for task in connections)
        put!(pending[1].release, nothing)
        first_connection = fetch(connections[1])
        @test !istaskdone(connections[2])
        put!(pending[2].release, nothing)
        second_connection = fetch(connections[2])
        @test first_connection.prepared.wire !== second_connection.prepared.wire
        for connection in (first_connection, second_connection)
            @test connection.same_holder
            @test connection.worker_pool == :default
            @test connection.prepared.wire === connection.holder.wire
            @test connection.reused
            @test connection.first_bytes == connection.expected
            @test endswith(connection.next_bytes, connection.next_body)
        end
    finally
        close(release)
        foreach(io -> close(io.release), pending)
        foreach(wait, connections)
    end

    # A socket write can yield. Other connections must not change the bytes
    # referenced by that pending write, and reuse starts only after it returns.
    slow = TransportGatedIO(IOBuffer(), Channel{Nothing}(1), Channel{Nothing}(1))
    request = HTTP.Request("GET", "/")
    stream = HTTP.Stream(request, HTTP.Connections.Connection(slow))
    slow_scratch = W.ResponseScratch()
    body = repeat("pending bytes", 1000)
    prepared = W.prepare_response(request, HTTP.Response(200, body), slow_scratch)
    writing = @async W.write_prepared_response(stream, prepared)
    take!(slow.entered)
    @test !istaskdone(writing)
    other_stream, other_io = transport_response_stream("independent connection")
    other_prepared =
        prepare_transport_response(other_stream, "independent connection", scratch)
    W.write_prepared_response(other_stream, other_prepared)
    @test endswith(String(take!(other_io.output)), "independent connection")
    put!(slow.release, nothing)
    wait(writing)
    @test endswith(String(take!(slow.output)), body)
    next_stream, next_io = transport_response_stream("next")
    next_prepared = prepare_transport_response(next_stream, "next", slow_scratch)
    @test next_prepared.wire === prepared.wire
    W.write_prepared_response(next_stream, next_prepared)
    @test endswith(String(take!(next_io.output)), "next")

    # Once capacity is warm, increasing the body must not allocate another wire
    # buffer. Allow small metadata differences without relying on exact counts.
    allocation_scratch = W.ResponseScratch()
    small, large = fill(UInt8('x'), 32), fill(UInt8('y'), 32_000)
    response_preparation_bytes(large, allocation_scratch)
    response_preparation_bytes(small, allocation_scratch)
    small_bytes = response_preparation_bytes(small, allocation_scratch)
    large_bytes = response_preparation_bytes(large, allocation_scratch)
    @test large_bytes < 8192
    @test large_bytes <= small_bytes + 2048
end

@testset "Bounded response coalescing" begin
    W = Campfire.Web
    bodies = ("Julia λ\0", SubString("<λ>", 2, 2), UInt8[0x00, 0xff, 0x80], codeunits("λ"))
    for body in bodies
        stream, io = transport_response_stream(body)
        HTTP.appendheader(
            stream.message.response,
            SubString("Set-Cookie") => SubString("first=1"),
        )
        HTTP.appendheader(
            stream.message.response,
            SubString("Set-Cookie") => SubString("second=2"),
        )
        expected = IOBuffer()
        HTTP.Messages.writeheaders(expected, stream.message.response)
        write(expected, body)
        W.write_prepared_response(stream, prepare_transport_response(stream, body))
        @test take!(io.output) == take!(expected)
        @test io.writes == 1
        @test stream.nwritten == (body isa AbstractString ? ncodeunits(body) : length(body))
        @test !stream.writechunked
        @test iswritable(stream)
        @test position(stream.stream.writebuffer) == 0
    end

    # Bound the entire wire response, including headers. These lengths have
    # the same five-digit Content-Length, so the header size stays constant.
    stream, _ = transport_response_stream(zeros(UInt8, 60_000))
    header = IOBuffer()
    HTTP.Messages.writeheaders(header, stream.message.response)
    exact_body_bytes = W.MAX_COALESCED_RESPONSE_BYTES - position(header)
    for (bytes, expected_writes) in (
        (exact_body_bytes - 1, 1),
        (exact_body_bytes, 1),
        (exact_body_bytes + 1, 2),
        (W.MAX_COALESCED_RESPONSE_BYTES + 1, 2),
    )
        body = fill(UInt8(0xa5), bytes)
        stream, io = transport_response_stream(body)
        W.write_prepared_response(stream, prepare_transport_response(stream, body))
        @test io.writes == expected_writes
        @test stream.nwritten == bytes
        wire = take!(io.output)
        @test wire[(end-bytes+1):end] == body
    end

    # Oversized headers also take the ordinary HTTP.jl write path.
    stream, io = transport_response_stream("body")
    HTTP.setheader(stream, "X-Large" => repeat("x", W.MAX_COALESCED_RESPONSE_BYTES))
    W.write_prepared_response(stream, prepare_transport_response(stream, "body"))
    @test io.writes == 2
    @test count("HTTP/1.1 200", String(take!(io.output))) == 1

    for (method, status) in (("HEAD", 200), ("GET", 204), ("GET", 304))
        stream, io = transport_response_stream(""; method, status)
        W.write_prepared_response(stream, prepare_transport_response(stream, ""))
        @test io.writes == 1
        @test stream.nwritten == 0
        @test !stream.writechunked
    end

    stream, io =
        transport_response_stream("abc"; headers = ["Transfer-Encoding" => "chunked"])
    prepared = prepare_transport_response(stream, "abc")
    @test prepared.wire === nothing
    @test !HTTP.hasheader(stream.message.response, "Content-Length")
    W.write_prepared_response(stream, prepared)
    HTTP.Streams.closebody(stream)
    wire = String(take!(io.output))
    @test endswith(wire, "\r\n\r\n3\r\nabc\r\n0\r\n\r\n")
    @test occursin("Transfer-Encoding: chunked", wire)
    @test io.writes > 1

    stream, io = transport_response_stream(
        "abc";
        status = 101,
        headers = ["Upgrade" => "websocket", "Connection" => "Upgrade"],
    )
    W.write_prepared_response(stream, prepare_transport_response(stream, "abc"))
    @test io.writes == 2
    @test occursin("Upgrade: websocket", String(take!(io.output)))

    # An already-started response must not emit a second set of headers.
    stream, io = transport_response_stream("firstsecond")
    HTTP.startwrite(stream)
    write(stream, "first")
    W.write_prepared_response(stream, prepare_transport_response(stream, "second"))
    wire = String(take!(io.output))
    @test count("HTTP/1.1 200", wire) == 1
    @test endswith(wire, "firstsecond")
    @test stream.nwritten == 11

    # Non-byte bodies preserve HTTP.jl's ordinary IO write behavior.
    body = IOBuffer("streamed body")
    stream, io = transport_response_stream("streamed body")
    W.write_prepared_response(stream, prepare_transport_response(stream, body))
    @test endswith(String(take!(io.output)), "streamed body")
    @test io.writes == 2

    stream, io = transport_response_stream("abc")
    HTTP.setheader(stream, "Connection" => "close")
    write(stream.stream.writebuffer, "owned by the connection")
    prepared = W.request_on_worker(stream.message) do request
        response = HTTP.Response(
            200,
            ["X-Preparation-Pool" => string(Threads.threadpool())],
            "abc",
        )
        return W.prepare_response(request, response)
    end
    @test prepared isa W.PreparedResponse
    @test HTTP.header(stream.message.response, "X-Preparation-Pool") == "default"
    @test HTTP.header(stream.message.response, "Connection") == "close"
    @test String(take!(stream.stream.writebuffer)) == "owned by the connection"
    W.write_prepared_response(stream, prepared)
    @test occursin("Connection: close", String(take!(io.output)))
    @test io.writes == 1

    # Failed writes propagate and leave no wire bytes in the reusable buffer.
    stream, io = transport_response_stream("closed peer")
    close(io)
    @test_throws Base.IOError W.write_prepared_response(
        stream,
        prepare_transport_response(stream, "closed peer"),
    )
    @test position(stream.stream.writebuffer) == 0
end

@testset "Production response preparation" begin
    W = Campfire.Web
    mktempdir() do directory
        app = W.WebApp(
            joinpath(directory, "transport.sqlite3");
            storage_root = joinpath(directory, "storage"),
            secret = repeat("t", 64),
            readers = 0,
        )
        listener = listen(ip"127.0.0.1", 0)
        server = W.start_server(app; server = listener)
        base = "http://127.0.0.1:$(HTTP.Servers.port(server))"
        try
            response = HTTP.get(base * "/up", ["Connection" => "close"]; retry = false)
            @test response.status == 200
            @test HTTP.header(response, "Connection") == "close"
            @test parse(Int, HTTP.header(response, "Content-Length")) ==
                  length(response.body)
            @test occursin("background-color: green", String(response.body))
            @test isempty(HTTP.request("HEAD", base * "/up"; retry = false).body)
        finally
            # HEAD headers can reach the client before its handler returns.
            # Drain the handler before closing its application database.
            close(server)
            @test isempty(server.connections)
            close(app)
        end
    end
end

function read_transport_response(connection; head = false)
    status = parse(Int, split(readline(connection))[2])
    headers = Pair{String,String}[]
    while true
        line = readline(connection)
        isempty(line) && break
        name, value = split(line, ':'; limit = 2)
        push!(headers, lowercase(name) => strip(value))
    end
    bytes = if head || status < 200 || status in (204, 304)
        0
    else
        parse(
            Int,
            only(last(header) for header in headers if first(header) == "content-length"),
        )
    end
    return (; status, headers, body = read(connection, bytes))
end

@testset "Coalesced HTTP framing and keepalive" begin
    W = Campfire.Web
    socket = listen(ip"127.0.0.1", 0)
    port = Int(last(getsockname(socket)))
    base = "http://127.0.0.1:$port"
    binary = repeat(UInt8[0x00, 0x0d, 0x0a, 0x80, 0xff], 20)
    large = repeat(binary, 1000)
    compressed = transcode(W.GzipCompressor, large)
    server = W.threaded_listen!(socket; readtimeout = 10, verbose = -1) do stream
        request = stream.message
        uploaded = read(stream)
        status =
            request.target == "/empty" ? 204 : request.target == "/unchanged" ? 304 : 200
        body = if request.method == "HEAD" || status in (204, 304)
            UInt8[]
        elseif request.target == "/large"
            large
        elseif request.target == "/gzip"
            compressed
        elseif request.target == "/echo"
            uploaded
        elseif request.target == "/chunked"
            codeunits("chunked response")
        else
            binary
        end
        scratch = W.response_scratch()
        prepared = W.request_on_worker(
            request,
            status,
            body,
            scratch,
        ) do request, status, body, scratch
            local response = HTTP.Response(
                status,
                ["Set-Cookie" => "one=1", "Set-Cookie" => "two=2"],
                body,
            )
            HTTP.setheader(response, "X-Preparation-Pool" => string(Threads.threadpool()))
            if request.target == "/chunked"
                HTTP.setheader(response, "Transfer-Encoding" => "chunked")
            elseif request.method == "HEAD"
                HTTP.setheader(response, "Content-Length" => string(length(binary)))
            end
            request.target == "/gzip" &&
                HTTP.setheader(response, "Content-Encoding" => "gzip")
            return W.prepare_response(request, response, scratch)
        end
        W.write_prepared_response(stream, prepared)
        return nothing
    end
    try
        connection = connect(ip"127.0.0.1", port)
        try
            # Send all five requests before reading any responses. Bodyless
            # responses must not shift the framing of the following response.
            write(
                connection,
                "HEAD /binary HTTP/1.1\r\nHost: localhost\r\n\r\n" *
                "GET /empty HTTP/1.1\r\nHost: localhost\r\n\r\n" *
                "GET /unchanged HTTP/1.1\r\nHost: localhost\r\n\r\n" *
                "GET /binary HTTP/1.1\r\nHost: localhost\r\n\r\n" *
                "GET /large HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
            )
            head = read_transport_response(connection; head = true)
            @test head.status == 200
            @test isempty(head.body)
            @test ("content-length" => string(length(binary))) in head.headers
            @test read_transport_response(connection).status == 204
            @test read_transport_response(connection).status == 304
            response = read_transport_response(connection)
            @test response.status == 200
            @test response.body == binary
            @test count(header -> first(header) == "set-cookie", response.headers) == 2
            @test ("x-preparation-pool" => "default") in response.headers
            response = read_transport_response(connection)
            @test response.body == large
            @test ("connection" => "close") in response.headers
            @test eof(connection)
        finally
            close(connection)
        end

        connection = connect(ip"127.0.0.1", port)
        try
            # A chunked upload must be completely consumed before the next
            # request, including its terminal chunk and trailers.
            write(
                connection,
                "POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" *
                "3\r\nabc\r\n2\r\nde\r\n0\r\nX-Trailer: done\r\n\r\n" *
                "GET /binary HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
            )
            @test String(read_transport_response(connection).body) == "abcde"
            @test read_transport_response(connection).body == binary
            @test eof(connection)
        finally
            close(connection)
        end

        connection = connect(ip"127.0.0.1", port)
        try
            write(
                connection,
                "POST /echo HTTP/1.1\r\nHost: localhost\r\n" *
                "Expect: 100-continue\r\nContent-Length: 5\r\n\r\n",
            )
            @test read_transport_response(connection).status == 100
            write(
                connection,
                "abcde" *
                "GET /binary HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
            )
            response = read_transport_response(connection)
            @test response.status == 200
            @test String(response.body) == "abcde"
            @test read_transport_response(connection).body == binary
            @test eof(connection)
        finally
            close(connection)
        end

        @test HTTP.get(base * "/gzip"; decompress = false, retry = false).body == compressed
        @test HTTP.get(base * "/gzip"; retry = false).body == large
        @test String(HTTP.get(base * "/chunked"; retry = false).body) == "chunked response"
    finally
        HTTP.forceclose(server)
    end
end

@testset "HTTP I/O ownership and worker dispatch" begin
    W = Campfire.Web
    socket = listen(ip"127.0.0.1", 0)
    port = Int(last(getsockname(socket)))
    base = "http://127.0.0.1:$port"
    entered = Threads.Atomic{Int}(0)
    active = Threads.Atomic{Int}(0)
    peak = Threads.Atomic{Int}(0)
    shutdowns = Threads.Atomic{Int}(0)
    response_gate = [Channel{Nothing}(1) for _ = 1:2]
    response_entered = Channel{Int}(2)
    peer_observations = Channel{Tuple{String,String}}(3)
    server = W.threaded_listen!(
        socket;
        readtimeout = 10,
        verbose = -1,
        on_shutdown = () -> Threads.atomic_add!(shutdowns, 1),
    ) do stream
        request = stream.message
        if HTTP.WebSockets.isupgrade(request)
            HTTP.WebSockets.upgrade(stream) do websocket
                put!(
                    peer_observations,
                    (websocket.request.context[:client_ip], W.client_ip(websocket.request)),
                )
                HTTP.WebSockets.send(websocket, HTTP.WebSockets.receive(websocket))
            end
            return nothing
        end
        if request.target == "/echo"
            put!(peer_observations, (request.context[:client_ip], W.client_ip(request)))
        end
        body = if request.target == "/parallel"
            before = "$(Threads.threadpool()):$(Threads.threadid())"
            result = W.request_on_worker(entered, active, peak) do entered, active, peak
                    count = Threads.atomic_add!(active, 1) + 1
                    Threads.atomic_max!(peak, count)
                    Threads.atomic_add!(entered, 1)
                    # No yield: overlap here requires separate CPU worker threads.
                    deadline = time_ns() + UInt64(2_000_000_000)
                    while entered[] < 2 && time_ns() < deadline
                    end
                    result = "$(Threads.threadpool()):$(Threads.threadid())"
                    Threads.atomic_sub!(active, 1)
                    return result
                end
            after = "$(Threads.threadpool()):$(Threads.threadid())"
            "$before|$result|$after"
        elseif request.target in ("/finish/1", "/finish/2")
            index = parse(Int, last(split(request.target, '/')))
            W.request_on_worker(index) do index
                put!(response_entered, index)
                take!(response_gate[index])
                return "finished $index"
            end
        else
            String(read(stream))
        end
        HTTP.setstatus(stream, 200)
        HTTP.appendheader(request.response, SubString("Set-Cookie")=>SubString("first=1"))
        HTTP.appendheader(request.response, SubString("Set-Cookie")=>SubString("second=2"))
        HTTP.setheader(stream, "Content-Length"=>string(ncodeunits(body)))
        W.write_prepared_response(stream, prepare_transport_response(stream, body))
        return nothing
    end
    try
        @test server isa HTTP.Server
        @test HTTP.Servers.port(server) == port
        if Threads.nthreads(:default) > 1
            clients = [
                @async HTTP.get(base*"/parallel", ["Connection"=>"close"]; retry = false) for _ = 1:8
            ]
            responses = fetch.(clients)
            @test all(response.status == 200 for response in responses)
            identities = split.(String.(getproperty.(responses, :body)), '|')
            io_pool = Threads.nthreads(:interactive) > 0 ? "interactive:" : "default:"
            @test all(startswith(identity[1], io_pool) for identity in identities)
            @test all(startswith(identity[3], io_pool) for identity in identities)
            @test all(startswith(identity[2], "default:") for identity in identities)
            @test length(unique(identity[2] for identity in identities)) > 1
            @test peak[] >= 2
        else
            @test_skip Threads.nthreads(:default) > 1
        end
        @test W.request_on_worker(+, 20, 22) == 42
        @test_throws TaskFailedException W.request_on_worker(error, "worker failure")

        # Both transactions reuse one connection; the adapter must preserve
        # sequential ownership and must not merge independent Set-Cookie fields.
        connection = connect(ip"127.0.0.1", port)
        first_peer = nothing
        try
            real_peer = string(first(getsockname(connection)))
            for body in ("first transaction", "second transaction")
                write(
                    connection,
                    "POST /echo HTTP/1.1\r\nHost: localhost\r\n" *
                    "Forwarded: for=203.0.113.7\r\n" *
                    "X-Forwarded-For: 198.51.100.9\r\nX-Real-IP: 192.0.2.8\r\n" *
                    "Content-Length: $(ncodeunits(body))\r\n\r\n" *
                    body,
                )
                @test occursin("200", readline(connection))
                headers = String[]
                while true
                    line = readline(connection)
                    isempty(line) && break
                    push!(headers, line)
                end
                @test count(startswith("Set-Cookie:"), headers) == 2
                @test String(read(connection, ncodeunits(body))) == body
                cached_peer, resolved_peer = take!(peer_observations)
                @test cached_peer == resolved_peer == real_peer == "127.0.0.1"
                if first_peer === nothing
                    first_peer = cached_peer
                else
                    # Equal bytes alone would not prove the string was reused.
                    @test pointer(cached_peer) == pointer(first_peer)
                end
            end
        finally
            close(connection)
        end

        HTTP.WebSockets.open(
            "ws://127.0.0.1:$port/cable";
            headers = [
                "Forwarded" => "for=203.0.113.7",
                "X-Forwarded-For" => "198.51.100.9",
                "X-Real-IP" => "192.0.2.8",
            ],
        ) do websocket
            HTTP.WebSockets.send(websocket, "worker websocket")
            @test HTTP.WebSockets.receive(websocket) == "worker websocket"
            cached_peer, resolved_peer = take!(peer_observations)
            @test cached_peer == resolved_peer == "127.0.0.1"
        end

        finish = [@async HTTP.get(base*"/finish/$index"; retry = false) for index = 1:2]
        @test sort([take!(response_entered), take!(response_entered)]) == [1, 2]
        closing = @async close(server)
        @test timedwait(() -> !isopen(server), 5.0) == :ok
        @test !istaskdone(closing)
        put!(response_gate[1], nothing)
        @test String(fetch(finish[1]).body) == "finished 1"
        @test !istaskdone(closing)
        put!(response_gate[2], nothing)
        @test String(fetch(finish[2]).body) == "finished 2"
        wait(closing)
        @test shutdowns[] == 1
        @test isempty(server.connections)
    finally
        isopen(server) && HTTP.forceclose(server)
    end
end

@testset "Bounded transport admission and timeout" begin
    W = Campfire.Web
    @test_throws ArgumentError W.threaded_listen!(Returns(nothing); max_connections = 0)
    socket = listen(ip"127.0.0.1", 0)
    port = Int(last(getsockname(socket)))
    entered = Channel{Nothing}(3)
    release = Channel{Nothing}(3)
    accepted = Threads.Atomic{Int}(0)
    server = W.threaded_listen!(
        socket;
        max_connections = 2,
        readtimeout = 10,
        verbose = -1,
        tcpisvalid = socket -> Threads.atomic_add!(accepted, 1) > 0,
    ) do stream
        put!(entered, nothing)
        take!(release)
        HTTP.setstatus(stream, 200)
        write(stream, "ok")
        return nothing
    end
    try
        rejected = connect(ip"127.0.0.1", port)
        @test eof(rejected)
        close(rejected)
        clients = [
            @async HTTP.get(
                "http://127.0.0.1:$port/",
                ["Connection"=>"close"];
                retry = false,
            ) for _ = 1:3
        ]
        take!(entered)
        take!(entered)
        @test !isready(entered)
        @test lock(server.connections_lock) do
            length(server.connections) == 2
        end
        put!(release, nothing)
        take!(entered)
        put!(release, nothing)
        put!(release, nothing)
        @test all(response.status == 200 for response in fetch.(clients))
    finally
        HTTP.forceclose(server)
    end
    @test isempty(server.connections)

    socket = listen(ip"127.0.0.1", 0)
    port = Int(last(getsockname(socket)))
    server = W.threaded_listen!(socket; readtimeout = 1, verbose = -1) do stream
        write(stream, "unexpected")
    end
    client = connect(ip"127.0.0.1", port)
    try
        response = @async String(read(client))
        @test timedwait(() -> istaskdone(response), 5.0) == :ok
        @test startswith(fetch(response), "HTTP/1.1 408")
    finally
        close(client)
        HTTP.forceclose(server)
    end
end
