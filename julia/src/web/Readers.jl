# A lease belongs to a task, not a thread: Julia tasks can migrate while yielding.
# Each reader owns its SQLite handles, statements, observer epoch and cache.
mutable struct ReadPool{T}
    readers::Vector{T}
    available::Vector{T}
    condition::Threads.Condition
    active::Int
    closing::Bool
end

function with_reader(f::F, app) where {F}
    pool = app.readers
    pool === nothing && return f(app)
    reader = lock(pool.condition) do
        while isempty(pool.available) && !pool.closing
            wait(pool.condition)
        end
        pool.closing && return nothing
        pool.active += 1
        return pop!(pool.available)
    end
    reader === nothing && return html_response("Server shutting down"; status = 503)
    try
        reader.origin = app.origin
        return f(reader)
    finally
        lock(pool.condition) do
            push!(pool.available, reader)
            pool.active -= 1
            return notify(pool.condition; all = pool.closing)
        end
    end
end

function close_database!(app)
    foreach(DBInterface.close!, values(app.statements))
    empty!(app.statements)
    DBInterface.close!(app.observer_statement)
    SQLite.close(app.db)
    SQLite.close(app.observer)
    return nothing
end

function Base.close(pool::ReadPool)
    lock(pool.condition) do
        pool.closing = true
        notify(pool.condition; all = true)
        while pool.active > 0
            wait(pool.condition)
        end
        foreach(close_database!, pool.readers)
        return empty!(pool.available)
    end
    return nothing
end

function open_reader(app, path, budget, entries)
    db = SQLite.DB(path)
    observer = nothing
    try
        execute_db!(db, "PRAGMA query_only=ON")
        execute_db!(db, "PRAGMA busy_timeout=5000")
        observer = SQLite.DB(path)
        execute_db!(observer, "PRAGMA query_only=ON")
        return WebApp(
            db,
            observer,
            SQLite.Stmt(observer, "PRAGMA data_version"),
            Dict{String,SQLite.Stmt}(),
            app.storage_root,
            app.secret,
            Dict{String,Vector{UInt8}}(),
            app.vapid_public_key,
            app.vapid_private_key,
            ReentrantLock(),
            app.storage_lock,
            app.broker,
            Set{Task}(),
            false,
            Dict{String,Tuple{Float64,Int}}(),
            Dict{Tuple{Int64,String,String},CachedPage}(),
            0,
            budget,
            entries,
            -1,
            app.origin,
            nothing,
        )
    catch
        observer === nothing || SQLite.close(observer)
        SQLite.close(db)
        rethrow()
    end
end

function open_readers(app, path, count)
    readers = WebApp[]
    try
        for index in 1:count
            # Remainders preserve the aggregate limits, including small budgets.
            budget = div(app.cache_budget, count) + (index <= rem(app.cache_budget, count))
            entries =
                div(app.cache_entries, count) + (index <= rem(app.cache_entries, count))
            push!(readers, open_reader(app, path, budget, entries))
        end
    catch
        foreach(close_database!, readers)
        rethrow()
    end
    return ReadPool(readers, copy(readers), Threads.Condition(), 0, false)
end
