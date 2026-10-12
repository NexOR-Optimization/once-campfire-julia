using Test, HTTP, Sockets
if !isdefined(@__MODULE__, :Campfire)
    include(joinpath(@__DIR__, "../julia/src/Campfire.jl"))
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
    response_gate = Channel{Nothing}(1)
    response_entered = Channel{Nothing}(1)
    server = W.threaded_listen!(
        socket;
        readtimeout = 10,
        verbose = -1,
        on_shutdown = () -> Threads.atomic_add!(shutdowns, 1),
    ) do stream
        request = stream.message
        if HTTP.WebSockets.isupgrade(request)
            HTTP.WebSockets.upgrade(stream) do websocket
                HTTP.WebSockets.send(websocket, HTTP.WebSockets.receive(websocket))
            end
            return nothing
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
        elseif request.target == "/finish"
            W.request_on_worker() do
                put!(response_entered, nothing)
                take!(response_gate)
                return "finished"
            end
        else
            String(read(stream))
        end
        HTTP.setstatus(stream, 200)
        HTTP.appendheader(request.response, SubString("Set-Cookie")=>SubString("first=1"))
        HTTP.appendheader(request.response, SubString("Set-Cookie")=>SubString("second=2"))
        HTTP.setheader(stream, "Content-Length"=>string(ncodeunits(body)))
        HTTP.startwrite(stream)
        write(stream, body)
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
            @test all(identity[1] == identity[3] for identity in identities)
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
        try
            for body in ("first transaction", "second transaction")
                write(
                    connection,
                    "POST /echo HTTP/1.1\r\nHost: localhost\r\n" *
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
            end
        finally
            close(connection)
        end

        HTTP.WebSockets.open("ws://127.0.0.1:$port/cable") do websocket
            HTTP.WebSockets.send(websocket, "worker websocket")
            @test HTTP.WebSockets.receive(websocket) == "worker websocket"
        end

        finish = @async HTTP.get(base*"/finish"; retry = false)
        take!(response_entered)
        closing = @async close(server)
        @test timedwait(() -> !isopen(server), 5.0) == :ok
        @test !istaskdone(closing)
        put!(response_gate, nothing)
        @test String(fetch(finish).body) == "finished"
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
