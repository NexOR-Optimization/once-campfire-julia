module Campfire

using Dates, DBInterface, HTTP, SQLite, UUIDs

include("Rendering.jl")
using .Rendering: Buffer, reset!, escape_html!, append_integer!, finish
import .Rendering: append!

export Store, handle, serve, seed!

# A deliberately small vertical slice. SQL keeps filtering/pagination next to
# the data; Julia owns routing, authorization, rendering and response caching.
const MESSAGE_COLUMNS = """
    SELECT m.id, u.name AS author, COALESCE(idx.body, '') AS body
    FROM messages m JOIN users u ON u.id = m.creator_id
    LEFT JOIN message_search_index idx ON idx.rowid = m.id
    """
const QUERIES = (
    begin_read = "BEGIN",
    begin_write = "BEGIN IMMEDIATE",
    commit = "COMMIT",
    rollback = "ROLLBACK",
    auth = """
        SELECT u.id FROM sessions s JOIN users u ON u.id = s.user_id
        WHERE s.token = ? AND u.status = 0 AND u.role != 2
        """,
    access = "SELECT 1 FROM memberships WHERE user_id = ? AND room_id = ?",
    room = "SELECT name FROM rooms WHERE id = ?",
    messages = MESSAGE_COLUMNS * """
        WHERE m.room_id = ? ORDER BY m.created_at DESC, m.id DESC LIMIT 40
        """,
    before = MESSAGE_COLUMNS * """
        WHERE m.room_id = ? AND m.created_at <
          (SELECT created_at FROM messages WHERE id = ? AND room_id = ?)
        ORDER BY m.created_at DESC, m.id DESC LIMIT 40
        """,
    search = """
        SELECT m.id, u.name AS author, idx.body
        FROM message_search_index idx
        JOIN messages m ON m.id = idx.rowid
        JOIN users u ON u.id = m.creator_id
        JOIN memberships mm ON mm.room_id = m.room_id AND mm.user_id = ?
        WHERE idx.body MATCH ? ORDER BY m.id DESC LIMIT 100
        """,
    sidebar = """
        SELECT r.id, r.name FROM rooms r
        JOIN memberships mm ON mm.room_id = r.id
        WHERE mm.user_id = ? AND mm.involvement != 'invisible'
          AND r.type = 'Rooms::Open' ORDER BY lower(r.name), r.id
        """,
)

mutable struct Store
    db::SQLite.DB
    observer::SQLite.DB
    statements::Dict{Symbol,SQLite.Stmt}
    version_query::SQLite.Stmt
    buffer::Buffer
    cache::Dict{Tuple{Int64,String},Vector{UInt8}}
    cache_bytes::Int
    cache_budget::Int
    generation::Int64
    lock::ReentrantLock
end

function Store(path::AbstractString; cache_budget::Int = 64 * 1024^2)
    isfile(path) ||
        throw(ArgumentError("database must already exist; use seed! for a demo"))
    cache_budget >= 0 || throw(ArgumentError("cache_budget must be nonnegative"))
    db = SQLite.DB(path)
    observer = SQLite.DB(path)
    try
        execute!(db, "PRAGMA busy_timeout = 5000")
        execute!(db, "PRAGMA foreign_keys = ON")
        execute!(observer, "PRAGMA query_only = ON")
        statements = Dict(name => SQLite.Stmt(db, sql) for (name, sql) in pairs(QUERIES))
        return Store(
            db,
            observer,
            statements,
            SQLite.Stmt(observer, "PRAGMA data_version"),
            Buffer(64 * 1024),
            Dict{Tuple{Int64,String},Vector{UInt8}}(),
            0,
            cache_budget,
            -1,
            ReentrantLock(),
        )
    catch
        SQLite.close(db)
        SQLite.close(observer)
        rethrow()
    end
end

function Base.close(store::Store)
    lock(store.lock) do
        for statement in values(store.statements)
            DBInterface.close!(statement)
        end
        DBInterface.close!(store.version_query)
        SQLite.close(store.db)
        return SQLite.close(store.observer)
    end
    return nothing
end

function execute!(statement::SQLite.Stmt, parameters = ())
    DBInterface.close!(DBInterface.execute(statement, parameters))
    return nothing
end

function execute!(db::SQLite.DB, sql, parameters = ())
    statement = SQLite.Stmt(db, sql)
    try
        return execute!(statement, parameters)
    finally
        DBInterface.close!(statement)
    end
end

function withrows(f::F, statement::SQLite.Stmt, parameters = ()) where {F}
    rows = DBInterface.execute(statement, parameters)
    try
        return f(rows)
    finally
        DBInterface.close!(rows)
    end
end

function scalar(statement, parameters = (); default = nothing)
    return withrows(statement, parameters) do rows
        for row in rows
            return row[1]
        end
        return default
    end
end

function invalidate!(store)
    empty!(store.cache)
    store.cache_bytes = 0
    return nothing
end

function generation!(store)
    version = Int64(scalar(store.version_query))
    if version != store.generation
        invalidate!(store)
        store.generation = version
    end
    return version
end

struct Message
    id::Int64
    author::String
    body::String
end

function message!(buffer, message::Message)
    append!(buffer, "<article id=\"message_")
    append_integer!(buffer, message.id)
    append!(buffer, "\" data-message-id=\"")
    append_integer!(buffer, message.id)
    append!(buffer, "\"><b>")
    escape_html!(buffer, message.author)
    append!(buffer, "</b><p>")
    escape_html!(buffer, message.body)
    append!(buffer, "</p></article>")
    return buffer
end

function messages!(buffer, statement, parameters)
    # The query has a strict limit. Copy ephemeral SQLite rows on a cache miss;
    # never retain a row backed by a statement that will be stepped/reset.
    messages = withrows(statement, parameters) do rows
        return [Message(row.id, row.author, row.body) for row in rows]
    end
    for message in Iterators.reverse(messages)
        message!(buffer, message)
    end
    return buffer
end

function document!(buffer, title)
    append!(buffer, "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>")
    escape_html!(buffer, title)
    append!(buffer, "</title></head><body>")
    return buffer
end

function sidebar!(store, user)
    b = store.buffer
    append!(b, "<nav id=\"shared_rooms\">")
    withrows(store.statements[:sidebar], (user,)) do rows
        for row in rows
            append!(b, "<a href=\"/rooms/")
            append_integer!(b, row.id)
            append!(b, "\">")
            escape_html!(b, row.name)
            append!(b, "</a>")
        end
    end
    append!(b, "</nav>")
    return nothing
end

const HTML_HEADERS = [
    "Content-Type" => "text/html; charset=utf-8",
    "Cache-Control" => "no-store",
    "X-Content-Type-Options" => "nosniff",
    "Content-Security-Policy" => "default-src 'none'; frame-ancestors 'none'",
]
response(status, body) = HTTP.Response(status, copy(HTML_HEADERS), body)

# Search terms are literals, matching Rails' FTS policy (AND is a word too).
fts_terms(query) =
    join(("\"" * replace(word, "\"" => "\"\"") * "\"" for word in split(query)), " ")

function route(request)
    uri = HTTP.URI(request.target)
    query = HTTP.queryparams(uri)
    if uri.path == "/users/me/sidebar"
        return (:sidebar, Int64(0), query)
    elseif uri.path == "/searches"
        return (:search, Int64(0), query)
    end
    match = Base.match(r"^/rooms/([1-9][0-9]*)(/messages)?$", uri.path)
    isnothing(match) && return (:missing, Int64(0), query)
    room = tryparse(Int64, match[1])
    isnothing(room) && return (:missing, Int64(0), query)
    return (isnothing(match[2]) ? :room : :messages, room, query)
end

function render!(store, user, kind, room, query)
    b = reset!(store.buffer)
    if kind == :room
        title = scalar(store.statements[:room], (room,); default = "Room")
        document!(b, coalesce(title, "Room"))
        sidebar!(store, user)
        append!(b, "<main id=\"messages_room_")
        append_integer!(b, room)
        append!(b, "\">")
        messages!(b, store.statements[:messages], (room,))
        append!(b, "</main></body></html>")
    elseif kind == :messages
        if haskey(query, "before")
            before = tryparse(Int64, query["before"])
            isnothing(before) && return response(400, "invalid before")
            messages!(b, store.statements[:before], (room, before, room))
        else
            messages!(b, store.statements[:messages], (room,))
        end
    elseif kind == :sidebar
        document!(b, "Rooms")
        sidebar!(store, user)
        append!(b, "</body></html>")
    elseif kind == :search
        document!(b, "Search")
        terms = fts_terms(get(query, "q", ""))
        isempty(terms) || messages!(b, store.statements[:search], (user, terms))
        append!(b, "</body></html>")
    end
    return response(200, finish(b))
end

function post!(store, user, room, request)
    lowercase(strip(first(split(HTTP.header(request, "Content-Type"), ';')))) ==
    "text/plain" || return response(415, "prototype writes require text/plain")
    length(request.body) <= 64 * 1024 || return response(413, "message too large")
    body = String(copy(request.body))
    isvalid(body) || return response(400, "invalid UTF-8")
    isempty(strip(body)) && return response(422, "empty message")
    client_id = string(uuid4())
    db = store.db
    execute!(
        db,
        """
INSERT INTO messages (room_id, creator_id, client_message_id, created_at, updated_at)
VALUES (?, ?, ?, strftime('%Y-%m-%d %H:%M:%f','now'), strftime('%Y-%m-%d %H:%M:%f','now'))
""",
        (room, user, client_id),
    )
    id = SQLite.last_insert_rowid(db)
    escaped = finish(escape_html!(reset!(store.buffer), body))
    execute!(
        db,
        """
INSERT INTO action_text_rich_texts
  (name, record_type, record_id, body, created_at, updated_at)
VALUES ('body', 'Message', ?, ?, strftime('%Y-%m-%d %H:%M:%f','now'),
  strftime('%Y-%m-%d %H:%M:%f','now'))
""",
        (id, String(escaped)),
    )
    execute!(db, "INSERT INTO message_search_index(rowid, body) VALUES (?, ?)", (id, body))
    execute!(
        db,
        """
UPDATE rooms SET updated_at = strftime('%Y-%m-%d %H:%M:%f','now') WHERE id = ?
""",
        (room,),
    )
    execute!(
        db,
        """
UPDATE memberships SET unread_at = strftime('%Y-%m-%d %H:%M:%f','now'),
  updated_at = strftime('%Y-%m-%d %H:%M:%f','now')
WHERE room_id = ? AND user_id != ? AND connections = 0
  AND involvement != 'invisible' AND (unread_at IS NULL OR
    (SELECT type FROM rooms WHERE id = ?) = 'Rooms::Direct')
""",
        (room, user, room),
    )
    invalidate!(store)
    return HTTP.Response(
        201,
        [
            "Location" => "/rooms/$room/messages#message_$id",
            "Content-Type" => "text/plain; charset=utf-8",
            "Cache-Control" => "no-store",
        ],
        string(id),
    )
end

function authorized_response(store, request, user, kind, room, query, version)
    if room != 0 && isnothing(scalar(store.statements[:access], (user, room)))
        return response(404, "room not found")
    end
    if request.method == "POST" && kind == :messages
        return post!(store, user, room, request)
    elseif request.method != "GET"
        return response(405, "method not allowed")
    end
    key = (Int64(user), request.target)
    # The observer is separate from the reader/writer, so local commits and
    # other processes' commits both invalidate cached bodies.
    if generation!(store) == version && haskey(store.cache, key)
        return response(200, store.cache[key])
    end
    result = render!(store, user, kind, room, query)
    if result.status == 200 &&
       store.cache_budget > 0 &&
       generation!(store) == version &&
       length(result.body) <= store.cache_budget
        if store.cache_bytes + length(result.body) > store.cache_budget ||
           length(store.cache) >= 512
            invalidate!(store)
        end
        store.cache[key] = result.body
        store.cache_bytes += length(result.body)
    end
    return result
end

function handle(store::Store, request::HTTP.Request)
    request.target == "/up" &&
        request.method == "GET" &&
        return response(200, "<html><body style=\"background-color: green\"></body></html>")
    ncodeunits(request.target) <= 2048 || return response(414, "target too long")
    auth = HTTP.header(request, "Authorization")
    startswith(auth, "Bearer ") || return response(401, "Bearer session token required")
    token = SubString(auth, 8)
    isempty(token) && return response(401, "invalid session")
    kind, room, query = try
        route(request)
    catch error
        error isa ArgumentError || rethrow()
        return response(400, "invalid target")
    end
    kind == :missing && return response(404, "route not implemented")
    return lock(store.lock) do
        version = generation!(store)
        # One consistent SQLite snapshot covers auth, access and rendering.
        execute!(store.statements[request.method == "POST" ? :begin_write : :begin_read])
        try
            user = scalar(store.statements[:auth], (token,))
            result =
                isnothing(user) ? response(401, "invalid session") :
                authorized_response(store, request, user, kind, room, query, version)
            execute!(store.statements[:commit])
            return result
        catch
            execute!(store.statements[:rollback])
            rethrow()
        end
    end
end

function serve(store; host = "127.0.0.1", port = 3001, kwargs...)
    return HTTP.serve!(
        request -> handle(store, request),
        host,
        port;
        verbose = false,
        kwargs...,
    )
end

include("seed.jl")
include("Web.jl")

end
