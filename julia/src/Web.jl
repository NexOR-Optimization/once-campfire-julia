module Web

using Base64,
    CodecZlib, Dates, DBInterface, HTTP, JSON3, Random, SHA, SQLite, UUIDs, Sockets
using ..Rendering: Buffer, reset!, escape_html!, append_integer!, finish
import ..Rendering: append!

export WebApp, start_server, handle_request

struct User
    id::Int64
    name::String
    email_address::String
    bio::String
    role::Int
    status::Int
end

function User(row)
    text(key) = string(coalesce(getproperty(row, key), ""))
    return User(
        row.id,
        text(:name),
        text(:email_address),
        text(:bio),
        Int(row.role),
        Int(row.status),
    )
end

struct UploadedFile
    filename::String
    content_type::String
    data::Vector{UInt8}
end

const UnreadEventPayload = NamedTuple{(:roomId, :at),Tuple{Int64,Float64}}
const WebhookEventPayload = NamedTuple{(:message_id, :base_url),Tuple{Int64,String}}
const EventPayload =
    Union{Nothing,String,Vector{String},UnreadEventPayload,WebhookEventPayload}

struct Event
    kind::Symbol
    id::Int64
    payload::EventPayload
end

struct Subscription
    channel::String
    room_id::Int64
    stream::String
end

mutable struct Client
    id::UUID
    user_id::Int64
    request::HTTP.Request
    socket::HTTP.WebSockets.WebSocket
    outgoing::Channel{String}
    subscriptions::Dict{String,Subscription}
    present::Set{Int64}
end

mutable struct Broker
    clients::Dict{UUID,Client}
    lock::ReentrantLock
end
Broker() = Broker(Dict{UUID,Client}(), ReentrantLock())

struct CachedPage
    body::Base.CodeUnits{UInt8,String}
    compressed::Base.CodeUnits{UInt8,String}
    headers::Vector{Pair{String,String}}
end

include("web/Readers.jl")

mutable struct WebApp
    db::SQLite.DB
    observer::SQLite.DB
    observer_statement::SQLite.Stmt
    statements::Dict{String,SQLite.Stmt}
    storage_root::String
    secret::String
    signing_keys::Dict{String,Vector{UInt8}}
    vapid_public_key::String
    vapid_private_key::String
    lock::ReentrantLock
    storage_lock::ReentrantLock
    broker::Broker
    jobs::Set{Task}
    closing::Bool
    login_attempts::Dict{String,Tuple{Float64,Int}}
    cache::Dict{Tuple{Int64,String,String},CachedPage}
    cache_bytes::Int
    cache_budget::Int
    cache_entries::Int
    generation::Int64
    origin::String
    readers::Union{Nothing,ReadPool{WebApp}}
end

const Account = @NamedTuple{
    id::Int64,
    created_at::String,
    custom_styles::Union{Missing,String},
    join_code::String,
    name::String,
    settings::Union{Missing,String},
    singleton_guard::Int64,
    updated_at::String,
}

mutable struct Context
    app::WebApp
    req::HTTP.Request
    method::String
    path::String
    params::Dict{String,Any}
    user::Union{Nothing,User}
    account::Account
    base_url::String
    csrf::String
    events::Vector{Event}
end

const EMPTY_ACCOUNT = Account((0, "", "", "", "Campfire", "{}", 0, ""))
nowstr() = Dates.format(now(UTC), dateformat"yyyy-mm-dd HH:MM:SS.sss")
param(ctx, key, default = "") = get(ctx.params, key, default)
function allparams(ctx, key)
    value = get(ctx.params, key, get(ctx.params, key * "[]", String[]))
    return value isa AbstractVector ? value : [value]
end

function prepared_statement(app::WebApp, sql::AbstractString)
    return get!(app.statements, String(sql)) do
        return SQLite.Stmt(app.db, sql)
    end
end

function withquery(f::F, app::WebApp, sql::AbstractString, parameters = ()) where {F}
    statement = prepared_statement(app, sql)
    # strict=false selects this concrete query type, independently of SQL schema.
    rows = DBInterface.execute(statement, parameters)::SQLite.Query{false}
    try
        return f(rows)
    finally
        DBInterface.close!(rows)
    end
end

# SQLite.Stmt owns/finalizes the handle. Its wrapper is abstractly declared in
# SQLite.jl; narrow its concrete RefValue without caching a pointer past close().
function statement_handle(statement::SQLite.Stmt)
    wrapper = statement.stmt_wrapper::Base.RefValue{SQLite.StmtHandle}
    handle = wrapper[]
    handle == C_NULL && throw(SQLite.SQLiteException("Statement is closed"))
    return handle
end

# Fixed-schema reads and parameterless commands do not need Query metadata.
# These statements share the same lock/reader lease as ordinary DBInterface use.
# Text bindings are copied by SQLite, so no borrowed Julia buffer outlives a call.
function with_statement(
    f::F,
    statement::SQLite.Stmt,
    parameters::Tuple{Vararg{Union{AbstractString,Int64}}} = (),
) where {F}
    handle = statement_handle(statement)
    GC.@preserve statement begin
        SQLite.C.sqlite3_reset(handle)
        try
            length(parameters) == SQLite.C.sqlite3_bind_parameter_count(handle) ||
                throw(SQLite.SQLiteException("values required for every SQL placeholder"))
            for index in eachindex(parameters)
                value = parameters[index]
                status = if value isa Int64
                    SQLite.C.sqlite3_bind_int64(handle, index, value)
                else
                    # Other AbstractStrings may use a different code-unit encoding.
                    value isa Union{String,SubString{String}} || (value = String(value))
                    SQLite.C.sqlite3_bind_text(
                        handle,
                        index,
                        value,
                        ncodeunits(value),
                        SQLite.C.SQLITE_TRANSIENT,
                    )
                end
                status == SQLite.C.SQLITE_OK || throw(SQLite.sqliteexception(statement.db))
            end
            status = SQLite.C.sqlite3_step(handle)
            status in (SQLite.C.SQLITE_ROW, SQLite.C.SQLITE_DONE) ||
                throw(SQLite.sqliteexception(statement.db))
            return f(handle, status)
        finally
            SQLite.C.sqlite3_reset(handle)
            SQLite.C.sqlite3_clear_bindings(handle)
        end
    end
end

copyrow(row) = NamedTuple{Tuple(propertynames(row))}(
    Tuple(row[i] for i in 1:length(propertynames(row))),
)
qrows(app, sql, parameters = ()) =
    withquery(rows -> [copyrow(row) for row in rows], app, sql, parameters)
function qone(app, sql, parameters = ())
    return withquery(app, sql, parameters) do rows
        for row in rows
            return copyrow(row)
        end
        return nothing
    end
end
function scalar(app, sql, parameters = (); default = nothing)
    return withquery(app, sql, parameters) do rows
        for row in rows
            return row[1]
        end
        return default
    end
end
function execute!(app::WebApp, sql, parameters = ())
    statement = prepared_statement(app, sql)
    if isempty(parameters)
        return with_statement((_, _) -> nothing, statement)
    end
    # Retain SQLite.jl's generic parameter binding, including blobs and NULLs,
    # while avoiding column names/types/dictionaries for discarded results.
    try
        SQLite.execute(statement, parameters)
    finally
        SQLite.C.sqlite3_reset(statement_handle(statement))
    end
    return nothing
end

function execute_db!(db, sql, parameters = ())
    statement = SQLite.Stmt(db, sql)
    try
        result = DBInterface.execute(statement, parameters)
        DBInterface.close!(result)
    finally
        DBInterface.close!(statement)
    end
    return nothing
end

function initialize_schema!(db)
    execute_db!(db, "PRAGMA journal_mode=WAL")
    execute_db!(db, "PRAGMA foreign_keys=ON")
    execute_db!(db, "PRAGMA busy_timeout=5000")
    execute_db!(db, "PRAGMA recursive_triggers=ON")
    execute_db!(db, "BEGIN IMMEDIATE")
    try
        # Older reference fixtures predate the single-account invariant.
        existing = DBInterface.execute(db, "PRAGMA table_info(accounts)")
        columns = [String(row.name) for row in existing]
        DBInterface.close!(existing)
        if !isempty(columns) && "singleton_guard" ∉ columns
            execute_db!(
                db,
                "ALTER TABLE accounts ADD COLUMN singleton_guard INTEGER NOT NULL DEFAULT 0",
            )
        end
        for sql in split(read(joinpath(@__DIR__, "web/schema.sql"), String), ';')
            isempty(strip(sql)) || execute_db!(db, sql)
        end
        columns = DBInterface.execute(db, "PRAGMA table_info(rooms)")
        has_count = any(row -> row.name == "messages_count", columns)
        DBInterface.close!(columns)
        has_count || execute_db!(
            db,
            "ALTER TABLE rooms ADD COLUMN messages_count INTEGER NOT NULL DEFAULT 0",
        )
        for (name, event, body) in (
            (
                "messages_ai_rooms_messages_count",
                "AFTER INSERT ON messages",
                "UPDATE rooms SET messages_count=messages_count+1 WHERE id=NEW.room_id;",
            ),
            (
                "messages_ad_rooms_messages_count",
                "AFTER DELETE ON messages",
                "UPDATE rooms SET messages_count=messages_count-1 WHERE id=OLD.room_id;",
            ),
            (
                "messages_au_rooms_messages_count",
                "AFTER UPDATE OF room_id ON messages WHEN OLD.room_id IS NOT NEW.room_id",
                "UPDATE rooms SET messages_count=messages_count-1 WHERE id=OLD.room_id; UPDATE rooms SET messages_count=messages_count+1 WHERE id=NEW.room_id;",
            ),
        )
            execute_db!(db, "CREATE TRIGGER IF NOT EXISTS $name $event BEGIN $body END")
        end
        execute_db!(
            db,
            "UPDATE rooms SET messages_count=(SELECT count(*) FROM messages WHERE room_id=rooms.id)",
        )
        execute_db!(db, "COMMIT")
    catch
        execute_db!(db, "ROLLBACK")
        rethrow()
    end
    return nothing
end

function WebApp(
    path::AbstractString;
    storage_root = joinpath(dirname(abspath(path)), "storage"),
    secret = get(ENV, "SECRET_KEY_BASE", ""),
    cache_budget = 64 * 1024^2,
    origin = "",
    readers::Integer = min(Threads.nthreads(:default), 4),
    synchronous::AbstractString = get(ENV, "DATABASE_SYNCHRONOUS", "FULL"),
)
    cache_budget >= 0 || throw(ArgumentError("negative cache budget"))
    readers >= 0 || throw(ArgumentError("negative reader count"))
    synchronous in ("FULL", "NORMAL") ||
        throw(ArgumentError("DATABASE_SYNCHRONOUS must be FULL or NORMAL"))
    initialize_media!()
    mkpath(dirname(abspath(path)))
    mkpath(storage_root)
    if isempty(secret)
        secret_path = joinpath(storage_root, "secret_key_base")
        if isfile(secret_path)
            secret = strip(read(secret_path, String))
        else
            secret = bytes2hex(rand(RandomDevice(), UInt8, 64))
            open(secret_path, "w"; lock = false) do io
                chmod(secret_path, 0o600)
                return write(io, secret)
            end
        end
    end
    length(secret) >= 32 ||
        throw(ArgumentError("SECRET_KEY_BASE must contain at least 32 characters"))
    vapid_public, vapid_private = ensure_vapid_keys!(storage_root)
    db = SQLite.DB(path)
    observer = nothing
    observer_statement = nothing
    try
        execute_db!(db, "PRAGMA synchronous=" * synchronous)
        initialize_schema!(db)
        observer = SQLite.DB(path)
        execute_db!(observer, "PRAGMA query_only=ON")
        observer_statement = SQLite.Stmt(observer, "PRAGMA data_version")
        app = WebApp(
            db,
            observer,
            observer_statement,
            Dict{String,SQLite.Stmt}(),
            abspath(storage_root),
            secret,
            Dict{String,Vector{UInt8}}(),
            vapid_public,
            vapid_private,
            ReentrantLock(),
            ReentrantLock(),
            Broker(),
            Set{Task}(),
            false,
            Dict{String,Tuple{Float64,Int}}(),
            Dict{Tuple{Int64,String,String},CachedPage}(),
            0,
            cache_budget,
            512,
            -1,
            origin,
            nothing,
        )
        # One worker gains no concurrency from extra database handles. Callers
        # can still request a pool explicitly for deterministic ownership tests.
        if readers > 1 && path != ":memory:"
            app.readers = open_readers(app, path, readers)
        end
        return app
    catch
        observer_statement === nothing || DBInterface.close!(observer_statement)
        observer === nothing || SQLite.close(observer)
        SQLite.close(db)
        rethrow()
    end
end

function Base.close(app::WebApp)
    # Drain leases before shutting down the writer used by deferred activity.
    app.readers === nothing || close(app.readers)
    clients = lock(app.lock) do
        app.closing = true
        return collect(values(app.broker.clients))
    end
    for client in clients
        isopen(client.outgoing) && close(client.outgoing)
        close(client.socket)
    end
    jobs = lock(app.lock) do
        return collect(app.jobs)
    end
    foreach(wait, jobs)
    lock(app.lock) do
        return close_database!(app)
    end
    return nothing
end

function launch_job!(f::F, app::WebApp) where {F}
    lock(app.lock) do
        app.closing && return
        task = @async try
            f()
        catch error
            # Provider request exceptions may contain bearer-capability URLs.
            @warn "Background delivery failed" exception_type=typeof(error)
        finally
            lock(app.lock) do
                delete!(app.jobs, current_task())
            end
        end
        return push!(app.jobs, task)
    end
    return nothing
end

function html_response(body; status = 200, headers = Pair{String,String}[])
    response = HTTP.Response(
        status,
        ["Content-Type" => "text/html; charset=utf-8", "Cache-Control" => "no-store"],
        body,
    )
    foreach(header -> HTTP.setheader(response, header), headers)
    return response
end
function json_response(body; status = 200, headers = Pair{String,String}[])
    return HTTP.Response(
        status,
        [
            "Content-Type" => "application/json; charset=utf-8";
            "Cache-Control" => "no-store";
            headers
        ],
        JSON3.write(body),
    )
end
redirect(path; status = 303) =
    HTTP.Response(status, ["Location" => String(path), "Cache-Control" => "no-store"], "")

function broadcast_room!(ctx, room, html)
    push!(ctx.events, Event(:room, Int64(room), html))
    return nothing
end
function broadcast_sidebar!(ctx, user_ids = Int[])
    if isempty(user_ids)
        push!(ctx.events, Event(:sidebar, 0, nothing))
    else
        for id in user_ids
            push!(ctx.events, Event(:sidebar, Int64(id), nothing))
        end
    end
    return nothing
end
disconnect_user!(ctx, id) = push!(ctx.events, Event(:disconnect, Int64(id), nothing))

function addparam!(parameters, key, value)
    if haskey(parameters, key)
        old = parameters[key]
        parameters[key] = old isa Vector ? [old; value] : [old, value]
    else
        parameters[key] = value
    end
    return nothing
end
function decode_form!(parameters, text)
    for part in split(text, '&'; keepempty = false)
        pair = split(part, '='; limit = 2)
        key = HTTP.unescapeuri(replace(pair[1], '+' => ' '))
        value = length(pair) == 2 ? HTTP.unescapeuri(replace(pair[2], '+' => ' ')) : ""
        addparam!(parameters, key, value)
    end
    return parameters
end
function flatten_json!(parameters, object, prefix = "")
    for (key, value) in pairs(object)
        name = isempty(prefix) ? String(key) : prefix * "[" * String(key) * "]"
        if value isa AbstractDict || value isa JSON3.Object
            flatten_json!(parameters, value, name)
        else
            parameters[name] = value
        end
    end
    return parameters
end
function request_parameters(req, uri::HTTP.URI = HTTP.URI(req.target))
    parameters = Dict{String,Any}()
    isempty(uri.query) || decode_form!(parameters, uri.query)
    if !isempty(req.body)
        content_type = lowercase(first(split(HTTP.header(req, "Content-Type"), ';')))
        if content_type == "application/x-www-form-urlencoded"
            body_parameters = decode_form!(Dict{String,Any}(), String(copy(req.body)))
            merge!(parameters, body_parameters)
        elseif content_type == "application/json"
            flatten_json!(parameters, JSON3.read(req.body))
        elseif content_type == "multipart/form-data"
            for part in something(HTTP.parse_multipart_form(req), HTTP.Multipart[])
                part.filename !== nothing && isempty(part.filename) && continue
                value =
                    isnothing(part.filename) ? read(part.data, String) :
                    UploadedFile(part.filename, part.contenttype, read(part.data))
                addparam!(parameters, part.name, value)
            end
        end
    end
    return parameters
end

function request_origin(app, request)
    isempty(app.origin) || return app.origin
    host = HTTP.header(request, "Host", "localhost")
    # Proxy deployments configure CAMPFIRE_ORIGIN; forwarded headers are not trusted.
    return "http://" * host
end
function same_origin_request(app, req)
    site = lowercase(HTTP.header(req, "Sec-Fetch-Site"))
    site == "cross-site" && return false
    origin = HTTP.header(req, "Origin")
    expected = request_origin(app, req)
    isempty(origin) || return origin == expected
    return !startswith(expected, "https://") || site in ("same-origin", "none")
end

function current_account(app)
    return withquery(app, "SELECT * FROM accounts ORDER BY id LIMIT 1") do rows
        for row in rows
            return Account((
                row.id,
                row.created_at,
                row.custom_styles,
                row.join_code,
                row.name,
                row.settings,
                row.singleton_guard,
                row.updated_at,
            ))
        end
        return EMPTY_ACCOUNT
    end
end

function current_context(app, req, parameters, path, method)
    user = authenticate(app, req)
    account = current_account(app)
    csrf = bytes2hex(
        hmac_sha256(
            Vector{UInt8}(codeunits(app.secret)),
            codeunits("csrf:" * HTTP.header(req, "Cookie")),
        ),
    )
    return Context(
        app,
        req,
        method,
        path,
        parameters,
        user,
        account,
        request_origin(app, req),
        csrf,
        Event[],
    )
end

function cache_generation!(app)
    version = with_statement(app.observer_statement) do handle, status
        status == SQLite.C.SQLITE_ROW ||
            throw(SQLite.SQLiteException("Missing database generation"))
        return SQLite.C.sqlite3_column_int64(handle, 0)
    end
    if version != app.generation
        empty!(app.cache)
        app.cache_bytes = 0
        app.generation = version
    end
    return version
end

include("web/AuthAccounts.jl")
include("web/Assets.jl")
include("web/Views.jl")
include("web/MessagesMedia.jl")
include("web/Unfurl.jl")
include("web/Push.jl")
include("web/Rooms.jl")
include("web/Cable.jl")
include("web/Transport.jl")
include("web/Server.jl")

end
