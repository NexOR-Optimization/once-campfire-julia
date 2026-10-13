using SHA, Random, Base64, Libdl

# Cryptographic work belongs on the infrequent authentication path, not in
# rendering. RandomDevice reads the OS CSPRNG; default Julia RNGs are unsuitable
# for credentials. libxcrypt provides bcrypt compatible with Rails passwords.
const BCRYPT_COST = 12
const CRYPT_LIBRARY = Libdl.find_library(["crypt", "libcrypt.so.1", "libcrypt.so.2"])
const QRENCODE_LIBRARY = Libdl.find_library(["qrencode", "libqrencode.so.4"])
const CRYPTO_LIBRARY = Libdl.find_library(["crypto", "libcrypto.so.3"])

function secure_equal(a::AbstractString, b::AbstractString)
    ncodeunits(a) == ncodeunits(b) || return false
    difference = UInt8(0)
    for i in 1:ncodeunits(a)
        difference |= codeunit(a, i) ⊻ codeunit(b, i)
    end
    return difference == 0
end

urlbase64(bytes) = replace(base64encode(bytes), '+' => '-', '/' => '_', "=" => "")

function unurlbase64(encoded)
    text = replace(encoded, '-' => '+', '_' => '/')
    return base64decode(text * repeat("=", mod(-ncodeunits(text), 4)))
end

random_token(bytes = 32) = urlbase64(rand(RandomDevice(), UInt8, bytes))

function token_hmac(secret, message)
    # OpenSSL uses the CPU's SHA extensions where available. Each call owns its
    # output; request tasks never share mutable digest state.
    output = Vector{UInt8}(undef, 32)
    output_length = Ref{Cuint}(0)
    digest = ccall((:EVP_sha256, CRYPTO_LIBRARY), Ptr{Cvoid}, ())
    result = ccall(
        (:HMAC, CRYPTO_LIBRARY),
        Ptr{UInt8},
        (Ptr{Cvoid}, Ptr{UInt8}, Cint, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Ref{Cuint}),
        digest,
        secret,
        ncodeunits(secret),
        message,
        ncodeunits(message),
        output,
        output_length,
    )
    result != C_NULL && output_length[] == 32 || error("Token HMAC failed")
    return output
end

function secure_equal_hex(signature, digest)
    ncodeunits(signature) == 2length(digest) || return false
    difference = UInt8(0)
    for index in eachindex(digest)
        byte = digest[index]
        difference |=
            codeunit(signature, 2index - 1) ⊻
            codeunit("0123456789abcdef", Int(byte >> 4) + 1)
        difference |=
            codeunit(signature, 2index) ⊻ codeunit("0123456789abcdef", Int(byte & 0x0f) + 1)
    end
    return difference == 0
end

const TOKEN_BASE64_VALUES = ntuple(256) do index
    byte = UInt8(index - 1)
    0x41 <= byte <= 0x5a && return byte - 0x41
    0x61 <= byte <= 0x7a && return byte - 0x61 + 0x1a
    0x30 <= byte <= 0x39 && return byte - 0x30 + 0x34
    byte == 0x2d && return 0x3e
    byte == 0x5f && return 0x3f
    return 0xff
end

function decode_token_payload(payload)
    # Native tokens always contain canonical, unpadded Base64URL. Decode into
    # one buffer instead of allocating replacements, padding, and an IO pipe.
    count = ncodeunits(payload)
    rem(count, 4) == 1 && return nothing
    output = Vector{UInt8}(undef, div(3count, 4))
    state = UInt32(0)
    available = 0
    index = 1
    for byte in codeunits(payload)
        value = TOKEN_BASE64_VALUES[Int(byte)+1]
        value == 0xff && return nothing
        state = (state << 6) | value
        available += 6
        if available >= 8
            available -= 8
            output[index] = (state >> available) % UInt8
            index += 1
        end
    end
    state & ((UInt32(1) << available) - UInt32(1)) == 0 || return nothing
    decoded = String(output)
    return isvalid(decoded) ? decoded : nothing
end

function signed_token(app, purpose, value)
    payload = urlbase64(string(value))
    signature = bytes2hex(token_hmac(app.secret, purpose * ":" * payload))
    return payload * "." * signature
end

function verify_token(app, purpose, token)
    token isa AbstractString || return nothing
    ncodeunits(token) <= 8192 || return nothing
    delimiter = findfirst('.', token)
    delimiter === nothing && return nothing
    payload = SubString(token, firstindex(token), prevind(token, delimiter))
    signature = SubString(token, nextind(token, delimiter))
    ncodeunits(signature) == 64 || return nothing
    expected = token_hmac(app.secret, purpose * ":" * payload)
    secure_equal_hex(signature, expected) || return nothing
    return decode_token_payload(payload)
end

function rails_signing_key(app, salt)
    return get!(app.signing_keys, String(salt)) do
        # Rails KeyGenerator uses PBKDF2-SHA256, 1,000 rounds and 64 bytes.
        key = Vector{UInt8}(undef, 64)
        digest = ccall((:EVP_sha256, CRYPTO_LIBRARY), Ptr{Cvoid}, ())
        result = ccall(
            (:PKCS5_PBKDF2_HMAC, CRYPTO_LIBRARY),
            Cint,
            (Cstring, Cint, Cstring, Cint, Cint, Ptr{Cvoid}, Cint, Ptr{UInt8}),
            app.secret,
            ncodeunits(app.secret),
            salt,
            ncodeunits(salt),
            1000,
            digest,
            length(key),
            key,
        )
        result == 1 || error("Rails signing-key derivation failed")
        return key
    end
end

function verify_rails_message(app, salt, purpose, token; digest = :sha256)
    token isa AbstractString && ncodeunits(token) <= 8192 || return nothing
    parts = rsplit(token, "--"; limit = 2)
    length(parts) == 2 || return nothing
    payload, signature = parts
    key = rails_signing_key(app, salt)
    mac =
        digest == :sha1 ? hmac_sha1(key, codeunits(payload)) :
        hmac_sha256(key, codeunits(payload))
    secure_equal(signature, bytes2hex(mac)) || return nothing
    try
        decoded = JSON3.read(unurlbase64(payload))
        if decoded isa JSON3.Object && haskey(decoded, :_rails)
            metadata = decoded[:_rails]
            get(metadata, :pur, nothing) == purpose || return nothing
            expiry = get(metadata, :exp, nothing)
            if expiry !== nothing
                expiry isa AbstractString && endswith(expiry, "Z") || return nothing
                DateTime(chop(expiry; tail = 1)) > now(UTC) || return nothing
            end
            if haskey(metadata, :data)
                return metadata[:data]
            elseif haskey(metadata, :message)
                return JSON3.read(base64decode(metadata[:message]))
            end
        elseif purpose === nothing
            return decoded
        end
    catch error
        error isa InterruptException && rethrow()
    end
    return nothing
end

function verify_rails_signed_id(app, purpose, token)
    value = verify_rails_message(app, "active_record/signed_id", "user/" * purpose, token)
    return value isa Integer && !(value isa Bool) && 0 < value <= typemax(Int64) ?
           Int64(value) : nothing
end

function session_token(app, req)
    cookie = request_cookie(req, "session_token")
    native = verify_token(app, "session", cookie)
    native !== nothing && return native
    legacy = verify_rails_message(
        app,
        "signed cookie",
        "cookie.session_token",
        cookie;
        digest = :sha1,
    )
    legacy === nothing && (
        legacy =
            verify_rails_message(app, "signed cookie", nothing, cookie; digest = :sha1)
    )
    return legacy isa AbstractString ? String(legacy) : nothing
end

function password_crypt(password::AbstractString, salt::AbstractString)
    # crypt_rn takes the buffer's size and rejects an incompatible ABI safely.
    # It avoids crypt()'s process-global buffer, so concurrent logins are safe.
    state = zeros(UInt8, 32768)
    result = ccall(
        (:crypt_rn, CRYPT_LIBRARY),
        Ptr{UInt8},
        (Cstring, Cstring, Ptr{UInt8}, Cint),
        password,
        salt,
        state,
        length(state),
    )
    result == C_NULL && throw(ArgumentError("unsupported password digest"))
    return GC.@preserve state unsafe_string(result)
end

function password_digest(password::AbstractString; cost::Integer = BCRYPT_COST)
    1 <= ncodeunits(password) <= 72 ||
        throw(ArgumentError("password must contain 1–72 bytes"))
    occursin('\0', password) && throw(ArgumentError("password contains a NUL byte"))
    4 <= cost <= 16 || throw(ArgumentError("invalid bcrypt cost"))
    entropy = rand(RandomDevice(), UInt8, 16)
    salt = Vector{UInt8}(undef, 192)
    result = ccall(
        (:crypt_gensalt_rn, CRYPT_LIBRARY),
        Ptr{UInt8},
        (Cstring, Culong, Ptr{UInt8}, Cint, Ptr{UInt8}, Cint),
        raw"$2b$",
        cost,
        entropy,
        length(entropy),
        salt,
        length(salt),
    )
    result == C_NULL && error("libcrypt cannot generate bcrypt salts")
    setting = GC.@preserve salt unsafe_string(result)
    return password_crypt(password, setting)
end

function password_matches(password::AbstractString, digest)
    digest isa AbstractString || return false
    1 <= ncodeunits(password) <= 72 || return false
    occursin('\0', password) && return false
    occursin(r"^\$2[aby]\$(0[4-9]|1[0-6])\$[./A-Za-z0-9]{53}$", digest) || return false
    return secure_equal(password_crypt(password, digest), digest)
end

function request_cookie(req, name)
    for field in eachsplit(HTTP.header(req, "Cookie", ""), ';')
        field = strip(field)
        delimiter = findfirst('=', field)
        delimiter === nothing && continue
        SubString(field, firstindex(field), prevind(field, delimiter)) == name || continue
        return HTTP.unescapeuri(SubString(field, nextind(field, delimiter)))
    end
    return ""
end

function row_user(row)
    row === nothing && return nothing
    return User(
        Int64(row.id),
        String(row.name),
        coalesce(row.email_address, ""),
        coalesce(row.bio, ""),
        Int(row.role),
        Int(row.status),
    )
end

function authenticate(app, req)
    token = session_token(app, req)
    token === nothing && return nothing
    return withquery(
        app,
        """
SELECT u.*, s.id AS session_id,
    datetime(s.last_active_at) <= datetime('now', '-1 hour') AS refresh_due
FROM users u JOIN sessions s ON s.user_id = u.id
WHERE s.token = ? AND u.status = 0 AND u.role != 2
""",
        (token,),
    ) do rows
        for row in rows
            mark_session_activity!(req, row)
            return row_user(row)::User
        end
        return nothing
    end
end

function cached_identity(app, token, room_id::Union{Nothing,AbstractString} = nothing)
    # Cache hits still authorize against the current database snapshot. Fixed
    # fields keep this hot path concrete without copying a dynamic SQL row.
    sql, parameters = if room_id === nothing
        (
            """SELECT u.id AS user_id,s.id AS session_id,
COALESCE(datetime(s.last_active_at)<=datetime('now','-1 hour'),0) AS refresh_due,
1 AS room_access
FROM users u JOIN sessions s ON s.user_id=u.id
WHERE s.token=? AND u.status=0 AND u.role!=2""",
            (token,),
        )
    else
        (
            """SELECT u.id AS user_id,s.id AS session_id,
COALESCE(datetime(s.last_active_at)<=datetime('now','-1 hour'),0) AS refresh_due,
EXISTS(SELECT 1 FROM memberships m WHERE m.user_id=u.id AND m.room_id=?) AS room_access
FROM users u JOIN sessions s ON s.user_id=u.id
WHERE s.token=? AND u.status=0 AND u.role!=2""",
            (room_id, token),
        )
    end
    return with_statement(prepared_statement(app, sql), parameters) do handle, status
        status == SQLite.C.SQLITE_DONE && return nothing
        return (
            id = SQLite.C.sqlite3_column_int64(handle, 0),
            session_id = SQLite.C.sqlite3_column_int64(handle, 1),
            refresh_due = SQLite.C.sqlite3_column_int64(handle, 2) != 0,
            room_access = SQLite.C.sqlite3_column_int64(handle, 3) != 0,
        )
    end
end

function mark_session_activity!(req, row)
    row.refresh_due == 1 && (req.context[:session_activity] = Int64(row.session_id))
    return nothing
end

function refresh_session_activity!(app, req)
    id = pop!(req.context, :session_activity, nothing)
    id === nothing && return nothing
    lock(app.lock) do
        if app.closing
            return nothing
        end
        timestamp = nowstr()
        return execute!(
            app,
            """
  UPDATE sessions SET last_active_at = ?, user_agent = ?,
      ip_address = ?, updated_at = ?
  WHERE id = ? AND datetime(last_active_at) <= datetime('now', '-1 hour')
  """,
            (timestamp, HTTP.header(req, "User-Agent", ""), client_ip(req), timestamp, id),
        )
    end
    return nothing
end

function safe_return_path(path)
    return path isa AbstractString &&
           1 <= ncodeunits(path) <= 2048 &&
           startswith(path, "/") &&
           !startswith(path, "//") &&
           !any(c -> Int(c) <= 0x20 || Int(c) == 0x7f || c == '\\', path)
end

function authentication_redirect(ctx)
    response = redirect("/session/new"; status = 302)
    path = String(ctx.req.target)
    if ctx.method == "GET" &&
       safe_return_path(path) &&
       !(ctx.path in ("/session/new", "/session"))
        token = signed_token(ctx.app, "return-to", "$(floor(Int, time()) + 3600)\n$path")
        cookie = "return_to=" * token * "; Path=/; HttpOnly; SameSite=Lax; Max-Age=3600"
        startswith(ctx.base_url, "https://") && (cookie *= "; Secure")
        HTTP.setheader(response, "Set-Cookie" => cookie)
    end
    return response
end

function post_authenticating_path(ctx)
    decoded = verify_token(ctx.app, "return-to", request_cookie(ctx.req, "return_to"))
    decoded === nothing && return "/"
    parts = split(decoded, '\n'; limit = 2)
    length(parts) == 2 || return "/"
    expiry = tryparse(Int64, parts[1])
    expiry !== nothing && expiry > floor(Int, time()) && safe_return_path(parts[2]) ||
        return "/"
    return String(parts[2])
end

function client_ip(req)
    # The HTTP server records the peer; forwarding headers are untrusted unless
    # a deployment explicitly validates them at its proxy boundary.
    return string(get(req.context, :client_ip, "127.0.0.1"))
end

function session_response(ctx, user_id; location = "/")
    token = random_token()
    timestamp = nowstr()
    execute!(
        ctx.app,
        """
INSERT INTO sessions (user_id, token, user_agent, ip_address,
    last_active_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)
""",
        (
            user_id,
            token,
            HTTP.header(ctx.req, "User-Agent", ""),
            client_ip(ctx.req),
            timestamp,
            timestamp,
            timestamp,
        ),
    )
    response = redirect(location; status = 302)
    cookie =
        "session_token=" *
        signed_token(ctx.app, "session", token) *
        "; Path=/; HttpOnly; SameSite=Lax; Max-Age=630720000"
    startswith(ctx.base_url, "https://") && (cookie *= "; Secure")
    HTTP.setheader(response, "Set-Cookie" => cookie)
    if !isempty(request_cookie(ctx.req, "return_to"))
        push!(
            response.headers,
            "Set-Cookie" => "return_to=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0",
        )
    end
    return response
end

function transfer_url(ctx, user; expires_at = floor(Int, time()) + 4 * 3600)
    token = signed_token(ctx.app, "transfer", "$(user.id):$expires_at")
    return ctx.base_url * "/session/transfers/" * token
end

qr_url(url) = "/qr_code/" * urlbase64(url)

function transfer_user(app, token; at = floor(Int, time()))
    decoded = verify_token(app, "transfer", token)
    if decoded === nothing
        id = verify_rails_signed_id(app, "transfer", token)
        id === nothing && return nothing
        return qone(
            app,
            "SELECT * FROM users WHERE id = ? AND status = 0 AND role != 2",
            (id,),
        )
    end
    parts = split(decoded, ':'; limit = 2)
    length(parts) == 2 || return nothing
    id, expires = tryparse(Int64, parts[1]), tryparse(Int64, parts[2])
    (id === nothing || expires === nothing || expires <= at) && return nothing
    return qone(app, "SELECT * FROM users WHERE id = ? AND status = 0 AND role != 2", (id,))
end

# The C object owns its bitmap. Read it while alive, then release in finally;
# only the final SVG string escapes this function.
struct NativeQRCode
    version::Cint
    width::Cint
    data::Ptr{UInt8}
end

function qr_svg(text::AbstractString)
    1 <= ncodeunits(text) <= 2048 || throw(ArgumentError("invalid QR payload length"))
    occursin('\0', text) && throw(ArgumentError("invalid QR payload"))
    pointer = ccall(
        (:QRcode_encodeString8bit, QRENCODE_LIBRARY),
        Ptr{NativeQRCode},
        (Cstring, Cint, Cint),
        text,
        0,
        1,
    )
    pointer == C_NULL && throw(ArgumentError("QR payload cannot be encoded"))
    try
        code = unsafe_load(pointer)
        width = Int(code.width)
        output = IOBuffer()
        print(
            output,
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"",
            (width + 8) * 6,
            "\" height=\"",
            (width + 8) * 6,
            "\" viewBox=\"0 0 ",
            width + 8,
            ' ',
            width + 8,
            "\" shape-rendering=\"crispEdges\"><rect width=\"100%\" height=\"100%\" fill=\"white\"/><path fill=\"black\" d=\"",
        )
        for y in 0:(width-1), x in 0:(width-1)
            if unsafe_load(code.data, y * width + x + 1) & 0x01 != 0
                print(output, 'M', x + 4, ' ', y + 4, "h1v1h-1z")
            end
        end
        print(output, "\"/></svg>")
        return String(take!(output))
    finally
        ccall((:QRcode_free, QRENCODE_LIBRARY), Cvoid, (Ptr{NativeQRCode},), pointer)
    end
end

function new_join_code()
    alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    text = String(rand(RandomDevice(), collect(alphabet), 12))
    return text[1:4] * "-" * text[5:8] * "-" * text[9:12]
end

function grant_open_rooms!(app, user_id)
    timestamp = nowstr()
    execute!(
        app,
        """
INSERT INTO memberships (room_id, user_id, created_at, updated_at)
SELECT id, ?, ?, ? FROM rooms WHERE type = 'Rooms::Open'
ON CONFLICT DO NOTHING
""",
        (user_id, timestamp, timestamp),
    )
    return nothing
end

function signup_user!(ctx; role = 0)
    name = strip(string(param(ctx, "user[name]")))
    email = strip(string(param(ctx, "user[email_address]")))
    password = string(param(ctx, "user[password]"))
    isempty(name) && throw(ArgumentError("name is required"))
    isempty(email) && throw(ArgumentError("email address is required"))
    digest = password_digest(password)
    timestamp = nowstr()
    execute!(
        ctx.app,
        """
INSERT INTO users (name, email_address, password_digest, role, status,
    created_at, updated_at) VALUES (?, ?, ?, ?, 0, ?, ?)
""",
        (name, email, digest, role, timestamp, timestamp),
    )
    id = Int64(scalar(ctx.app, "SELECT last_insert_rowid()"))
    grant_open_rooms!(ctx.app, id)
    attach_auth_upload!(ctx, "User", id, "avatar", "user[avatar]")
    return id
end

function attach_auth_upload!(ctx, record_type, record_id, name, key)
    upload = get(ctx.params, key, nothing)
    upload isa UploadedFile && attach_upload!(ctx, record_type, record_id, name, key)
    return nothing
end

function deactivate_user!(ctx, user)
    timestamp = nowstr()
    email =
        ismissing(user.email_address) ? missing :
        replace(user.email_address, "@" => "-deactivated-$(random_token(12))@")
    execute!(
        ctx.app,
        "UPDATE users SET status = 1, email_address = ?, updated_at = ? WHERE id = ?",
        (email, timestamp, user.id),
    )
    execute!(
        ctx.app,
        "DELETE FROM memberships WHERE user_id = ? AND room_id IN (SELECT id FROM rooms WHERE type != 'Rooms::Direct')",
        (user.id,),
    )
    for table in ("sessions", "searches", "push_subscriptions")
        execute!(ctx.app, "DELETE FROM $table WHERE user_id = ?", (user.id,))
    end
    disconnect_user!(ctx, user.id)
    broadcast_sidebar!(ctx)
    return nothing
end

function auth_page(ctx, name; status = 200, kwargs...)
    return html_response(view(ctx, name; kwargs...); status = status)
end

function admin_denied(ctx)
    ctx.user === nothing && return authentication_redirect(ctx)
    return ctx.user.role == 1 ? nothing : html_response("Forbidden"; status = 403)
end

function update_profile!(ctx)
    for column in ("name", "email_address", "bio")
        key = "user[$column]"
        haskey(ctx.params, key) || continue
        text = string(param(ctx, key))
        column == "name" && isempty(strip(text)) && throw(ArgumentError("name is required"))
        execute!(
            ctx.app,
            "UPDATE users SET $column = ?, updated_at = ? WHERE id = ?",
            (text, nowstr(), ctx.user.id),
        )
    end
    password = string(param(ctx, "user[password]"))
    if !isempty(password)
        execute!(
            ctx.app,
            "UPDATE users SET password_digest = ?, updated_at = ? WHERE id = ?",
            (password_digest(password), nowstr(), ctx.user.id),
        )
    end
    attach_auth_upload!(ctx, "User", ctx.user.id, "avatar", "user[avatar]")
    return redirect("/users/me/profile")
end

function bot_rows(app)
    bots = qrows(
        app,
        """
SELECT u.*, w.url AS webhook_url FROM users u
LEFT JOIN webhooks w ON w.user_id = u.id
WHERE u.role = 2 AND u.status = 0 ORDER BY lower(u.name), u.id
""",
    )
    return [
        merge(
            bot,
            (
                rooms = qrows(
                    app,
                    """
        SELECT r.* FROM rooms r JOIN memberships m ON r.id = m.room_id
        WHERE m.user_id = ? AND r.type != 'Rooms::Direct' ORDER BY lower(r.name)
        """,
                    (bot.id,),
                ),
            ),
        ) for bot in bots
    ]
end

function update_bot!(ctx, bot_id)
    name = strip(string(param(ctx, "user[name]")))
    isempty(name) && throw(ArgumentError("name is required"))
    timestamp = nowstr()
    if bot_id === nothing
        execute!(
            ctx.app,
            """
INSERT INTO users (name, bot_token, role, status, created_at, updated_at)
VALUES (?, ?, 2, 0, ?, ?)
""",
            (name, random_token(18), timestamp, timestamp),
        )
        bot_id = Int64(scalar(ctx.app, "SELECT last_insert_rowid()"))
        grant_open_rooms!(ctx.app, bot_id)
    else
        execute!(
            ctx.app,
            "UPDATE users SET name = ?, updated_at = ? WHERE id = ?",
            (name, timestamp, bot_id),
        )
    end
    if haskey(ctx.params, "user[webhook_url]")
        execute!(ctx.app, "DELETE FROM webhooks WHERE user_id = ?", (bot_id,))
        url = strip(string(param(ctx, "user[webhook_url]")))
        if !isempty(url)
            execute!(
                ctx.app,
                "INSERT INTO webhooks (user_id, url, created_at, updated_at) VALUES (?, ?, ?, ?)",
                (bot_id, url, timestamp, timestamp),
            )
        end
    end
    attach_auth_upload!(ctx, "User", bot_id, "avatar", "user[avatar]")
    broadcast_sidebar!(ctx)
    return redirect("/account/bots")
end

function route_auth(ctx)
    app, path, method = ctx.app, ctx.path, ctx.method
    if path == "/first_run"
        scalar(app, "SELECT COUNT(*) FROM accounts") > 0 &&
            return redirect("/"; status = 302)
        method == "GET" && return auth_page(ctx, :first_run)
        if method == "POST"
            timestamp = nowstr()
            execute!(
                app,
                "INSERT INTO accounts (name, join_code, settings, created_at, updated_at) VALUES ('Campfire', ?, '{}', ?, ?)",
                (new_join_code(), timestamp, timestamp),
            )
            id = signup_user!(ctx; role = 1)
            execute!(
                app,
                "INSERT INTO rooms (name, type, creator_id, created_at, updated_at) VALUES ('All Talk', 'Rooms::Open', ?, ?, ?)",
                (id, timestamp, timestamp),
            )
            grant_open_rooms!(app, id)
            return session_response(ctx, id)
        end
        return html_response("Method not allowed"; status = 405)
    elseif path == "/session/new" && method == "GET"
        scalar(app, "SELECT COUNT(*) FROM users") == 0 &&
            return redirect("/first_run"; status = 302)
        return auth_page(ctx, :session)
    elseif path == "/session" && method == "POST"
        login_allowed!(ctx) || return auth_page(
            ctx,
            :session;
            status = 429,
            alert = "Too many requests or unauthorized.",
        )
        user = qone(
            app,
            "SELECT * FROM users WHERE email_address = ? AND status = 0 AND role != 2",
            (string(param(ctx, "email_address")),),
        )
        password = string(param(ctx, "password"))
        if user !== nothing && password_matches(password, user.password_digest)
            return session_response(ctx, user.id; location = post_authenticating_path(ctx))
        end
        # Spend the same bcrypt work for unknown accounts; do not reveal whether
        # an email is registered via a fast rejection.
        user === nothing && password_matches(password, DUMMY_PASSWORD_DIGEST)
        return auth_page(
            ctx,
            :session;
            status = 401,
            alert = "Too many requests or unauthorized.",
        )
    elseif startswith(path, "/join/")
        ctx.user !== nothing && return redirect("/"; status = 302)
        code = path[(length("/join/")+1):end]
        account = qone(app, "SELECT * FROM accounts LIMIT 1")
        (account === nothing || !secure_equal(code, account.join_code)) &&
            return html_response("Not found"; status = 404)
        method == "GET" && return auth_page(ctx, :join; join_code = code)
        if method == "POST"
            email = strip(string(param(ctx, "user[email_address]")))
            existing = qone(app, "SELECT id FROM users WHERE email_address = ?", (email,))
            existing !== nothing && return redirect(
                "/session/new?email_address=" * HTTP.escapeuri(email);
                status = 302,
            )
            id = signup_user!(ctx)
            broadcast_sidebar!(ctx)
            return session_response(ctx, id)
        end
        return html_response("Method not allowed"; status = 405)
    elseif (matched = match(r"^/session/transfers/([^/]+)$", path)) !== nothing
        token = matched[1]
        method == "GET" && return auth_page(ctx, :transfer; token = token)
        if method in ("PUT", "PATCH")
            user = transfer_user(app, token)
            user === nothing &&
                return html_response("Invalid or expired transfer"; status = 400)
            return session_response(ctx, user.id; location = post_authenticating_path(ctx))
        end
        return html_response("Method not allowed"; status = 405)
    elseif (matched = match(r"^/qr_code/([^/]+?)(?:\.svg)?$", path)) !== nothing &&
           method == "GET"
        payload = try
            String(unurlbase64(matched[1]))
        catch
            return html_response("Invalid QR code"; status = 400)
        end
        svg = qr_svg(payload)
        return HTTP.Response(
            200,
            [
                "Content-Type" => "image/svg+xml",
                "Cache-Control" => "public, max-age=31536000",
                "X-Content-Type-Options" => "nosniff",
            ],
            svg,
        )
    end

    relevant =
        path == "/session" ||
        startswith(path, "/account") ||
        occursin(r"^/users/[^/]+(?:/(?:profile|ban|push_subscriptions)(?:/.*)?)?$", path)
    relevant || return nothing
    ctx.user === nothing && return authentication_redirect(ctx)

    if path == "/session" && method == "DELETE"
        token = session_token(app, ctx.req)
        token !== nothing && execute!(
            app,
            "DELETE FROM sessions WHERE token = ? AND user_id = ?",
            (token, ctx.user.id),
        )
        endpoint = string(param(ctx, "push_subscription_endpoint"))
        isempty(endpoint) || execute!(
            app,
            "DELETE FROM push_subscriptions WHERE endpoint = ? AND user_id = ?",
            (endpoint, ctx.user.id),
        )
        disconnect_user!(ctx, ctx.user.id)
        response = redirect("/"; status = 302)
        HTTP.setheader(
            response,
            "Set-Cookie" => "session_token=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0",
        )
        return response
    elseif occursin(r"^/users/[^/]+/profile(?:/edit)?$", path)
        if method == "GET"
            url = transfer_url(ctx, ctx.user)
            memberships = qrows(
                app,
                "SELECT r.*, m.involvement FROM rooms r JOIN memberships m ON m.room_id = r.id WHERE m.user_id = ? ORDER BY lower(r.name)",
                (ctx.user.id,),
            )
            return auth_page(
                ctx,
                :profile;
                user = ctx.user,
                transfer_url = url,
                qr_url = qr_url(url),
                memberships = memberships,
            )
        elseif method in ("PATCH", "PUT")
            return update_profile!(ctx)
        end
    elseif path in ("/account/edit", "/account")
        if method == "GET"
            statuses = ctx.user.role == 1 ? "(0, 2)" : "(0)"
            users = qrows(
                app,
                "SELECT * FROM users WHERE status IN $statuses AND role != 2 ORDER BY role DESC, lower(name), id",
            )
            return auth_page(ctx, :account; users = users)
        elseif method in ("PATCH", "PUT")
            denied = admin_denied(ctx)
            denied !== nothing && return denied
            if haskey(ctx.params, "account[name]")
                execute!(
                    app,
                    "UPDATE accounts SET name = ?, updated_at = ? WHERE id = ?",
                    (string(param(ctx, "account[name]")), nowstr(), ctx.account.id),
                )
            end
            setting = "account[settings][restrict_room_creation_to_administrators]"
            if haskey(ctx.params, setting)
                restricted = lowercase(string(param(ctx, setting))) in ("1", "true", "on")
                settings = JSON3.write(
                    Dict("restrict_room_creation_to_administrators" => restricted),
                )
                execute!(
                    app,
                    "UPDATE accounts SET settings = ?, updated_at = ? WHERE id = ?",
                    (settings, nowstr(), ctx.account.id),
                )
            end
            attach_auth_upload!(ctx, "Account", ctx.account.id, "logo", "account[logo]")
            return redirect("/account/edit")
        end
    elseif path == "/account/users" && method == "GET"
        users = qrows(
            app,
            "SELECT * FROM users WHERE status IN (0, ?) AND role = 0 ORDER BY lower(name), id LIMIT 500",
            (ctx.user.role == 1 ? 2 : 0,),
        )
        return auth_page(ctx, :account; users = users)
    elseif (matched = match(r"^/users/(\d+)$", path)) !== nothing && method == "GET"
        user = qone(app, "SELECT * FROM users WHERE id = ?", (tryparse(Int64, matched[1]),))
        user === nothing && return html_response("Not found"; status = 404)
        url =
            ctx.user.role == 1 && user.status == 0 && user.role != 2 ?
            transfer_url(ctx, user) : ""
        return auth_page(
            ctx,
            :user;
            user = user,
            transfer_url = url,
            qr_url = isempty(url) ? "" : qr_url(url),
        )
    elseif occursin(r"^/users/[^/]+/push_subscriptions", path)
        return route_push_subscriptions(ctx)
    end

    admin_route =
        startswith(path, "/account/bots") ||
        startswith(path, "/account/custom_styles") ||
        path == "/account/join_code" ||
        occursin(r"^/account/users/\d+$", path) ||
        occursin(r"^/users/\d+/ban$", path)
    admin_route || return nothing
    denied = admin_denied(ctx)
    denied !== nothing && return denied

    if path == "/account/join_code" && method == "POST"
        execute!(
            app,
            "UPDATE accounts SET join_code = ?, updated_at = ? WHERE id = ?",
            (new_join_code(), nowstr(), ctx.account.id),
        )
        return redirect("/account/edit")
    elseif path in ("/account/custom_styles", "/account/custom_styles/edit")
        method == "GET" && return auth_page(ctx, :styles)
        if method in ("PUT", "PATCH")
            execute!(
                app,
                "UPDATE accounts SET custom_styles = ?, updated_at = ? WHERE id = ?",
                (string(param(ctx, "account[custom_styles]")), nowstr(), ctx.account.id),
            )
            return redirect("/account/custom_styles/edit")
        end
    elseif path == "/account/bots"
        method == "GET" && return auth_page(ctx, :bots; bots = bot_rows(app))
        method == "POST" && return update_bot!(ctx, nothing)
    elseif path == "/account/bots/new" && method == "GET"
        return auth_page(ctx, :bot_form; bot = nothing)
    elseif (matched = match(r"^/account/bots/(\d+)(?:/(edit|key))?$", path)) !== nothing
        id = tryparse(Int64, matched[1])
        bot = qone(
            app,
            "SELECT u.*, w.url AS webhook_url FROM users u LEFT JOIN webhooks w ON w.user_id = u.id WHERE u.id = ? AND u.role = 2 AND u.status = 0",
            (id,),
        )
        bot === nothing && return html_response("Not found"; status = 404)
        if matched[2] == "key" && method in ("PUT", "PATCH")
            execute!(
                app,
                "UPDATE users SET bot_token = ?, updated_at = ? WHERE id = ?",
                (random_token(18), nowstr(), id),
            )
            return redirect("/account/bots")
        elseif matched[2] == "edit" && method == "GET"
            return auth_page(ctx, :bot_form; bot = bot)
        elseif matched[2] === nothing
            method in ("PUT", "PATCH") && return update_bot!(ctx, id)
            if method == "DELETE"
                deactivate_user!(ctx, bot)
                return redirect("/account/bots")
            end
        end
    elseif (matched = match(r"^/account/users/(\d+)$", path)) !== nothing
        user = qone(
            app,
            "SELECT * FROM users WHERE id = ? AND status = 0",
            (tryparse(Int64, matched[1]),),
        )
        user === nothing && return html_response("Not found"; status = 404)
        if method in ("PUT", "PATCH")
            role = param(ctx, "user[role]") == "administrator" ? 1 : 0
            execute!(
                app,
                "UPDATE users SET role = ?, updated_at = ? WHERE id = ?",
                (role, nowstr(), user.id),
            )
            return redirect("/account/edit")
        elseif method == "DELETE"
            deactivate_user!(ctx, user)
            return redirect("/account/edit")
        end
    elseif (matched = match(r"^/users/(\d+)/ban$", path)) !== nothing
        id = tryparse(Int64, matched[1])
        user = qone(app, "SELECT * FROM users WHERE id = ?", (id,))
        user === nothing && return html_response("Not found"; status = 404)
        if method == "POST"
            timestamp = nowstr()
            execute!(
                app,
                "INSERT INTO bans (user_id, ip_address, created_at, updated_at) SELECT DISTINCT user_id, ip_address, ?, ? FROM sessions WHERE user_id = ? AND ip_address IS NOT NULL AND ip_address != ''",
                (timestamp, timestamp, id),
            )
            execute!(
                app,
                "UPDATE users SET status = 2, updated_at = ? WHERE id = ?",
                (timestamp, id),
            )
            execute!(app, "DELETE FROM sessions WHERE user_id = ?", (id,))
            disconnect_user!(ctx, id)
            remove_banned_messages!(ctx, id)
            return redirect("/users/$id")
        elseif method == "DELETE"
            execute!(app, "DELETE FROM bans WHERE user_id = ?", (id,))
            execute!(
                app,
                "UPDATE users SET status = 0, updated_at = ? WHERE id = ?",
                (nowstr(), id),
            )
            return redirect("/users/$id")
        end
    end
    return html_response("Method not allowed"; status = 405)
end

# This known bcrypt digest is used solely to equalize unknown-user rejection.
const DUMMY_PASSWORD_DIGEST =
    raw"$2b$12$LQv3c1yqBWVHxkd0LHAkCOYb6S7vuR6YQUQpr7bbOHYWVGXqCoaWS"

function login_allowed!(ctx)
    attempts = ctx.app.login_attempts
    timestamp = time()
    ip = client_ip(ctx.req)
    if length(attempts) > 10000
        filter!(pair -> timestamp - pair.second[1] < 180, attempts)
        length(attempts) > 10000 && return false
    end
    started, count = get(attempts, ip, (timestamp, 0))
    timestamp - started >= 180 && ((started, count) = (timestamp, 0))
    attempts[ip] = (started, count + 1)
    return count < 10
end

function route_push_subscriptions(ctx)
    app, method = ctx.app, ctx.method
    notification =
        match(r"^/users/[^/]+/push_subscriptions/(\d+)/test_notifications$", ctx.path)
    if notification !== nothing && method == "POST"
        id = tryparse(Int64, notification[1])
        subscription = qone(
            app,
            "SELECT id FROM push_subscriptions WHERE id = ? AND user_id = ?",
            (id, ctx.user.id),
        )
        subscription === nothing && return html_response("Not found"; status = 404)
        push!(ctx.events, Event(:push_test, id, ctx.base_url))
        return redirect("/users/me/push_subscriptions")
    end
    matched = match(r"^/users/[^/]+/push_subscriptions(?:/(\d+))?$", ctx.path)
    matched === nothing && return nothing
    id = matched[1] === nothing ? nothing : tryparse(Int64, matched[1])
    if method == "GET" && id === nothing
        rows =
            qrows(app, "SELECT * FROM push_subscriptions WHERE user_id = ?", (ctx.user.id,))
        return auth_page(ctx, :push_subscriptions; subscriptions = rows)
    elseif method == "POST" && id === nothing
        endpoint = string(param(ctx, "push_subscription[endpoint]"))
        endpoint_ok = occursin(
            r"^https://(?:[A-Za-z0-9-]+\.)*(?:jmt17\.google\.com|fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|web\.push\.apple\.com|notify\.windows\.com)(?::443)?(?:/|$)",
            endpoint,
        )
        endpoint_ok || return html_response("Invalid push endpoint"; status = 422)
        key, auth = string(param(ctx, "push_subscription[p256dh_key]")),
        string(param(ctx, "push_subscription[auth_key]"))
        existing = qone(
            app,
            "SELECT id FROM push_subscriptions WHERE user_id = ? AND endpoint = ? AND p256dh_key = ? AND auth_key = ?",
            (ctx.user.id, endpoint, key, auth),
        )
        timestamp = nowstr()
        if existing === nothing
            execute!(
                app,
                "INSERT INTO push_subscriptions (user_id, endpoint, p256dh_key, auth_key, user_agent, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                (
                    ctx.user.id,
                    endpoint,
                    key,
                    auth,
                    HTTP.header(ctx.req, "User-Agent", ""),
                    timestamp,
                    timestamp,
                ),
            )
        else
            execute!(
                app,
                "UPDATE push_subscriptions SET updated_at = ? WHERE id = ?",
                (timestamp, existing.id),
            )
        end
        return html_response("")
    elseif method == "DELETE" && id !== nothing
        execute!(
            app,
            "DELETE FROM push_subscriptions WHERE id = ? AND user_id = ?",
            (id, ctx.user.id),
        )
        return redirect("/users/me/push_subscriptions")
    end
    return nothing
end
