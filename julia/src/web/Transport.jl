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
        HTTP.Servers.handle_connection(
            handler,
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
