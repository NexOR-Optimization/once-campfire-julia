# Keep sockets and HTTP parsing on the interactive pool: Julia's libuv I/O lock
# is shared across threads. Dispatch application work to the default pool and
# wait for its result before advancing that connection to its next request.
# The internal Listener, Server, and handle_connection signatures used here must
# be checked when upgrading HTTP.jl; no HTTP methods are replaced globally.

function request_on_worker(f::F, args::Vararg{Any,N}) where {F,N}
    # The HTTP connection awaits its worker. Bounded connection admission thus
    # also bounds outstanding request tasks; there is no detached request queue.
    return fetch(Threads.@spawn :default f(args...))
end

const MAX_COALESCED_RESPONSE_BYTES = 64 * 1024

# Each HTTP connection runs on one interactive task. That task lends its
# private scratch to its awaited worker, then owns it again until the complete
# synchronous socket write returns. No other request can reuse it meanwhile.
const RESPONSE_SCRATCH_KEY = gensym(:campfire_response_scratch)

mutable struct ResponseScratch
    wire::Union{Nothing,IOBuffer}
end
ResponseScratch() = ResponseScratch(nothing)

function response_scratch()
    return get!(
        ResponseScratch,
        task_local_storage(),
        RESPONSE_SCRATCH_KEY,
    )::ResponseScratch
end

# HTTP.Messages.writeheaders emits its complete serialized header block with
# one write. Check that block before touching the connection-owned wire buffer.
# This avoids copying the serialized headers through another temporary IOBuffer.
struct ResponseHeaderSink <: IO
    scratch::ResponseScratch
    body_bytes::Int
end

function Base.unsafe_write(sink::ResponseHeaderSink, pointer::Ptr{UInt8}, n::UInt)
    n <= MAX_COALESCED_RESPONSE_BYTES - sink.body_bytes || return 0
    buffer = sink.scratch.wire
    if buffer === nothing
        buffer = IOBuffer(;
            maxsize = MAX_COALESCED_RESPONSE_BYTES,
            sizehint = Int(n) + sink.body_bytes,
        )
        sink.scratch.wire = buffer
    end
    truncate(buffer, 0)
    seekstart(buffer)
    return unsafe_write(buffer, pointer, n)
end

struct PreparedResponse
    wire::Union{Nothing,IOBuffer}
    response::HTTP.Response
    body_bytes::Int
end

function prepare_response(
    app::WebApp,
    request::HTTP.Request,
    scratch::ResponseScratch = ResponseScratch(),
)
    return prepare_response(request, handle_request(app, request), scratch)
end

function prepare_response(
    request::HTTP.Request,
    response::HTTP.Response,
    scratch::ResponseScratch = ResponseScratch(),
)
    # The connection task awaits this worker, so request metadata has one owner.
    # Append to HTTP.jl's existing response to preserve Connection: close.
    request.response.status = response.status
    for header in response.headers
        HTTP.appendheader(request.response, header)
    end
    body = response.body
    supported_body =
        body isa Union{String,SubString{String},Vector{UInt8},Base.CodeUnits{UInt8}}
    bytes = supported_body ? (body isa AbstractString ? ncodeunits(body) : length(body)) : 0
    body_allowed =
        request.method != "HEAD" && response.status >= 200 && response.status ∉ (204, 304)
    chunked = HTTP.hasheader(request.response, "Transfer-Encoding")
    if body_allowed && supported_body && !chunked
        HTTP.setheader(request.response, "Content-Length" => string(bytes))
    end
    if body_allowed &&
       supported_body &&
       bytes <= MAX_COALESCED_RESPONSE_BYTES &&
       !chunked &&
       !HTTP.hasheader(request.response, "Upgrade")
        # Keep HTTP.jl's serializer. The sink accepts the entire header block
        # only when headers and body fit, leaving scratch untouched on fallback.
        header_bytes =
            HTTP.Messages.writeheaders(ResponseHeaderSink(scratch, bytes), request.response)
        if header_bytes > 0
            buffer = scratch.wire::IOBuffer
            write(buffer, body)
            seekstart(buffer)
            return PreparedResponse(buffer, response, bytes)
        end
    end
    return PreparedResponse(nothing, response, bytes)
end

function write_prepared_response(stream::HTTP.Stream, prepared::PreparedResponse)
    wire = prepared.wire
    if wire !== nothing &&
       stream.stream isa HTTP.Connections.Connection &&
       stream.nwritten < 0
        # HTTP.jl still owns parsing, connection shutdown, and write completion.
        iswritable(stream) || HTTP.startwrite(stream.stream)
        stream.writechunked = false
        stream.nwritten = 0
        write(stream.stream, wire)
        stream.nwritten = prepared.body_bytes
    else
        stream.nwritten < 0 && HTTP.startwrite(stream)
        write(stream, prepared.response.body)
    end
    return nothing
end

function threaded_connection(
    handler,
    connection,
    listener,
    connections,
    connections_lock,
    permits,
    readtimeout,
    access_log,
    verbose,
)
    try
        # The accepted connection already records its socket peer. Keep one
        # string for all its requests, including a later WebSocket upgrade.
        peer = string(connection.peerip)
        connection_handler = stream -> begin
            stream.message.context[:client_ip] = peer
            handler(stream)
        end
        HTTP.Servers.handle_connection(
            connection_handler,
            connection,
            listener,
            readtimeout,
            access_log,
            verbose,
        )
    finally
        lock(connections_lock) do
            return delete!(connections, connection)
        end
        Base.release(permits)
    end
    return nothing
end

function threaded_accept_loop(
    handler,
    listener,
    connections,
    connections_lock,
    ready,
    tcpisvalid,
    max_connections,
    readtimeout,
    access_log,
    verbose,
)
    permits = Base.Semaphore(max_connections)
    verbose >= 0 && @info "Listening on: $(listener.hostname):$(listener.hostport)"
    notify(ready)
    while isopen(listener)
        # Admission happens before accepting or spawning. Idle keepalive and
        # websocket connections count toward the same bounded connection limit.
        Base.acquire(permits)
        io = nothing
        handed_off = false
        try
            isopen(listener) || break
            io = HTTP.Servers.accept(listener)
            io === nothing && continue
            tcpisvalid(io) || continue
            connection = HTTP.Connections.Connection(io)
            connection.state = HTTP.Servers.IDLE
            connection.host, connection.port = listener.hostname, listener.hostport
            admitted = lock(connections_lock) do
                # Do not add a connection after graceful shutdown sees an empty
                # set. The listener closes before Server.close takes this lock.
                isopen(listener) || return false
                push!(connections, connection)
                return true
            end
            admitted || continue
            try
                Threads.@spawn :interactive threaded_connection(
                    handler,
                    connection,
                    listener,
                    connections,
                    connections_lock,
                    permits,
                    readtimeout,
                    access_log,
                    verbose,
                )
                handed_off = true
            catch
                lock(connections_lock) do
                    return delete!(connections, connection)
                end
                rethrow()
            end
        catch error
            if isopen(listener)
                verbose >= 1 && @error "HTTP connection acceptance failed" exception =
                    (error, catch_backtrace())
                sleep(0.05)
            end
        finally
            if !handed_off
                try
                    io === nothing || close(io)
                finally
                    Base.release(permits)
                end
            end
        end
    end
    return nothing
end

"""Serve HTTP streams on the interactive pool with bounded connection admission."""
function threaded_listen!(
    handler,
    args...;
    on_shutdown = nothing,
    tcpisvalid = Returns(true),
    max_connections::Integer = 4096,
    readtimeout::Integer = 0,
    access_log::Union{Function,Nothing} = nothing,
    verbose = false,
    kwargs...,
)
    max_connections > 0 || throw(ArgumentError("max_connections must be positive"))
    listener = HTTP.Servers.Listener(args...; kwargs...)
    connections = Set{HTTP.Connections.Connection}()
    connections_lock = ReentrantLock()
    ready = Threads.Event()
    task = Threads.@spawn :interactive threaded_accept_loop(
        handler,
        listener,
        connections,
        connections_lock,
        ready,
        tcpisvalid,
        max_connections,
        readtimeout,
        access_log,
        verbose,
    )
    wait(ready)
    return HTTP.Servers.Server(listener, on_shutdown, connections, task, connections_lock)
end
