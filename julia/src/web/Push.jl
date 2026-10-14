# RFC 8291 (message encryption) and RFC 8292 (VAPID), backed by OpenSSL's
# audited P-256, ECDH, ECDSA and AES-GCM implementations. No handwritten curve
# arithmetic, secret-dependent scalar loops, or application PRNG is used.

function with_p256(f; private = nothing, public = nothing)
    curve = ccall((:OBJ_sn2nid, CRYPTO_LIBRARY), Cint, (Cstring,), "prime256v1")
    key = ccall((:EC_KEY_new_by_curve_name, CRYPTO_LIBRARY), Ptr{Cvoid}, (Cint,), curve)
    key == C_NULL && error("cannot allocate P-256 key")
    try
        group = ccall((:EC_KEY_get0_group, CRYPTO_LIBRARY), Ptr{Cvoid}, (Ptr{Cvoid},), key)
        if private !== nothing
            length(private) == 32 ||
                throw(ArgumentError("P-256 private keys contain 32 bytes"))
            scalar = ccall(
                (:BN_bin2bn, CRYPTO_LIBRARY),
                Ptr{Cvoid},
                (Ptr{UInt8}, Cint, Ptr{Cvoid}),
                private,
                length(private),
                C_NULL,
            )
            point = ccall((:EC_POINT_new, CRYPTO_LIBRARY), Ptr{Cvoid}, (Ptr{Cvoid},), group)
            (scalar == C_NULL || point == C_NULL) && error("cannot allocate P-256 values")
            try
                ccall(
                    (:EC_KEY_set_private_key, CRYPTO_LIBRARY),
                    Cint,
                    (Ptr{Cvoid}, Ptr{Cvoid}),
                    key,
                    scalar,
                ) == 1 || throw(ArgumentError("invalid private key"))
                ccall(
                    (:EC_POINT_mul, CRYPTO_LIBRARY),
                    Cint,
                    (
                        Ptr{Cvoid},
                        Ptr{Cvoid},
                        Ptr{Cvoid},
                        Ptr{Cvoid},
                        Ptr{Cvoid},
                        Ptr{Cvoid},
                    ),
                    group,
                    point,
                    scalar,
                    C_NULL,
                    C_NULL,
                    C_NULL,
                ) == 1 || throw(ArgumentError("invalid private key"))
                ccall(
                    (:EC_KEY_set_public_key, CRYPTO_LIBRARY),
                    Cint,
                    (Ptr{Cvoid}, Ptr{Cvoid}),
                    key,
                    point,
                ) == 1 || throw(ArgumentError("invalid public key"))
            finally
                ccall((:BN_clear_free, CRYPTO_LIBRARY), Cvoid, (Ptr{Cvoid},), scalar)
                ccall((:EC_POINT_free, CRYPTO_LIBRARY), Cvoid, (Ptr{Cvoid},), point)
            end
        elseif public !== nothing
            length(public) == 65 && public[1] == 0x04 ||
                throw(ArgumentError("P-256 public keys must be uncompressed points"))
            point = ccall((:EC_POINT_new, CRYPTO_LIBRARY), Ptr{Cvoid}, (Ptr{Cvoid},), group)
            point == C_NULL && error("cannot allocate P-256 point")
            try
                ccall(
                    (:EC_POINT_oct2point, CRYPTO_LIBRARY),
                    Cint,
                    (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Ptr{Cvoid}),
                    group,
                    point,
                    public,
                    length(public),
                    C_NULL,
                ) == 1 || throw(ArgumentError("invalid P-256 point"))
                ccall(
                    (:EC_POINT_is_on_curve, CRYPTO_LIBRARY),
                    Cint,
                    (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                    group,
                    point,
                    C_NULL,
                ) == 1 || throw(ArgumentError("point is not on P-256"))
                ccall(
                    (:EC_POINT_is_at_infinity, CRYPTO_LIBRARY),
                    Cint,
                    (Ptr{Cvoid}, Ptr{Cvoid}),
                    group,
                    point,
                ) == 0 || throw(ArgumentError("point is at infinity"))
                ccall(
                    (:EC_KEY_set_public_key, CRYPTO_LIBRARY),
                    Cint,
                    (Ptr{Cvoid}, Ptr{Cvoid}),
                    key,
                    point,
                ) == 1 || throw(ArgumentError("invalid public key"))
            finally
                ccall((:EC_POINT_free, CRYPTO_LIBRARY), Cvoid, (Ptr{Cvoid},), point)
            end
        else
            ccall((:EC_KEY_generate_key, CRYPTO_LIBRARY), Cint, (Ptr{Cvoid},), key) == 1 ||
                error("cannot generate P-256 key")
        end
        ccall((:EC_KEY_check_key, CRYPTO_LIBRARY), Cint, (Ptr{Cvoid},), key) == 1 ||
            throw(ArgumentError("invalid P-256 key"))
        return f(key)
    finally
        ccall((:EC_KEY_free, CRYPTO_LIBRARY), Cvoid, (Ptr{Cvoid},), key)
    end
end

function p256_public(key)
    group = ccall((:EC_KEY_get0_group, CRYPTO_LIBRARY), Ptr{Cvoid}, (Ptr{Cvoid},), key)
    point = ccall((:EC_KEY_get0_public_key, CRYPTO_LIBRARY), Ptr{Cvoid}, (Ptr{Cvoid},), key)
    bytes = Vector{UInt8}(undef, 65)
    written = ccall(
        (:EC_POINT_point2oct, CRYPTO_LIBRARY),
        Csize_t,
        (Ptr{Cvoid}, Ptr{Cvoid}, Cint, Ptr{UInt8}, Csize_t, Ptr{Cvoid}),
        group,
        point,
        4,
        bytes,
        length(bytes),
        C_NULL,
    )
    written == 65 || error("cannot export P-256 public key")
    return bytes
end

function p256_private(key)
    scalar =
        ccall((:EC_KEY_get0_private_key, CRYPTO_LIBRARY), Ptr{Cvoid}, (Ptr{Cvoid},), key)
    scalar == C_NULL && throw(ArgumentError("missing private key"))
    bytes = Vector{UInt8}(undef, 32)
    ccall(
        (:BN_bn2binpad, CRYPTO_LIBRARY),
        Cint,
        (Ptr{Cvoid}, Ptr{UInt8}, Cint),
        scalar,
        bytes,
        length(bytes),
    ) == 32 || error("cannot export P-256 private key")
    return bytes
end

function generate_vapid_keys()
    return with_p256() do key
        return (urlbase64(p256_public(key)), urlbase64(p256_private(key)))
    end
end

function ensure_vapid_keys!(
    storage_root;
    private_key = get(ENV, "VAPID_PRIVATE_KEY", ""),
    public_key = get(ENV, "VAPID_PUBLIC_KEY", ""),
)
    mkpath(storage_root)
    if isempty(private_key)
        isempty(public_key) ||
            throw(ArgumentError("VAPID_PUBLIC_KEY requires VAPID_PRIVATE_KEY"))
        path = joinpath(storage_root, "vapid_private_key")
        if isfile(path)
            private_key = strip(read(path, String))
        else
            public_key, private_key = generate_vapid_keys()
            # The private key is created with restrictive permissions before
            # any bytes are written, including under permissive process umasks.
            io = Base.Filesystem.open(
                path,
                Base.JL_O_WRONLY | Base.JL_O_CREAT | Base.JL_O_EXCL,
                0o600,
            )
            try
                write(io, private_key)
            finally
                close(io)
            end
        end
    end
    derived = with_p256(; private = unurlbase64(private_key)) do key
        return urlbase64(p256_public(key))
    end
    isempty(public_key) ||
        secure_equal(urlbase64(unurlbase64(public_key)), derived) ||
        throw(ArgumentError("VAPID public and private keys do not match"))
    return (derived, String(private_key))
end

function p256_shared_secret(key, recipient_public)
    return with_p256(; public = recipient_public) do recipient
        point = ccall(
            (:EC_KEY_get0_public_key, CRYPTO_LIBRARY),
            Ptr{Cvoid},
            (Ptr{Cvoid},),
            recipient,
        )
        secret = Vector{UInt8}(undef, 32)
        count = ccall(
            (:ECDH_compute_key, CRYPTO_LIBRARY),
            Cint,
            (Ptr{UInt8}, Csize_t, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
            secret,
            length(secret),
            point,
            key,
            C_NULL,
        )
        count == 32 || error("P-256 key agreement failed")
        return secret
    end
end

function push_content_keys(shared, auth, salt, recipient_public, sender_public)
    length(auth) == 16 ||
        throw(ArgumentError("push authentication secrets contain 16 bytes"))
    length(salt) == 16 || throw(ArgumentError("push salts contain 16 bytes"))
    combined = hmac_sha256(auth, shared)
    info = [codeunits("WebPush: info\0"); recipient_public; sender_public; 0x01]
    ikm = hmac_sha256(combined, info)
    prk = hmac_sha256(salt, ikm)
    key = hmac_sha256(prk, codeunits("Content-Encoding: aes128gcm\0\x01"))[1:16]
    nonce = hmac_sha256(prk, codeunits("Content-Encoding: nonce\0\x01"))[1:12]
    return (key = key, nonce = nonce)
end

function aes128gcm_encrypt(plaintext, key, nonce)
    length(key) == 16 && length(nonce) == 12 ||
        throw(ArgumentError("invalid AES-GCM key or nonce"))
    context = ccall((:EVP_CIPHER_CTX_new, CRYPTO_LIBRARY), Ptr{Cvoid}, ())
    context == C_NULL && error("cannot allocate cipher context")
    try
        cipher = ccall((:EVP_aes_128_gcm, CRYPTO_LIBRARY), Ptr{Cvoid}, ())
        ccall(
            (:EVP_EncryptInit_ex, CRYPTO_LIBRARY),
            Cint,
            (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt8}, Ptr{UInt8}),
            context,
            cipher,
            C_NULL,
            key,
            nonce,
        ) == 1 || error("cannot initialize AES-GCM")
        ciphertext = Vector{UInt8}(undef, length(plaintext) + 16)
        written = Ref{Cint}(0)
        ccall(
            (:EVP_EncryptUpdate, CRYPTO_LIBRARY),
            Cint,
            (Ptr{Cvoid}, Ptr{UInt8}, Ref{Cint}, Ptr{UInt8}, Cint),
            context,
            ciphertext,
            written,
            plaintext,
            length(plaintext),
        ) == 1 || error("AES-GCM encryption failed")
        count = Int(written[])
        GC.@preserve ciphertext begin
            ccall(
                (:EVP_EncryptFinal_ex, CRYPTO_LIBRARY),
                Cint,
                (Ptr{Cvoid}, Ptr{UInt8}, Ref{Cint}),
                context,
                pointer(ciphertext, count + 1),
                written,
            ) == 1 || error("AES-GCM finalization failed")
            count += Int(written[])
            ccall(
                (:EVP_CIPHER_CTX_ctrl, CRYPTO_LIBRARY),
                Cint,
                (Ptr{Cvoid}, Cint, Cint, Ptr{UInt8}),
                context,
                0x10,
                16,
                pointer(ciphertext, count + 1),
            ) == 1 || error("cannot obtain AES-GCM authentication tag")
        end
        resize!(ciphertext, count + 16)
        return ciphertext
    finally
        ccall((:EVP_CIPHER_CTX_free, CRYPTO_LIBRARY), Cvoid, (Ptr{Cvoid},), context)
    end
end

function encrypt_push(
    payload::AbstractString,
    recipient_public,
    auth;
    salt = rand(RandomDevice(), UInt8, 16),
    sender_private = nothing,
)
    ncodeunits(payload) <= 3993 ||
        throw(ArgumentError("push payload exceeds the 4096-byte wire limit"))
    return with_p256(; private = sender_private) do key
        sender_public = p256_public(key)
        shared = p256_shared_secret(key, recipient_public)
        derived = push_content_keys(shared, auth, salt, recipient_public, sender_public)
        plaintext = [codeunits(payload); 0x02]
        encrypted = aes128gcm_encrypt(plaintext, derived.key, derived.nonce)
        # RFC 8188 header: salt, big-endian record size (4096), key-id size,
        # then the ephemeral uncompressed P-256 public key.
        return [salt; UInt8[0x00, 0x00, 0x10, 0x00, 0x41]; sender_public; encrypted]
    end
end

function p256_sign(key, message)
    digest = sha256(message)
    signature = ccall(
        (:ECDSA_do_sign, CRYPTO_LIBRARY),
        Ptr{Cvoid},
        (Ptr{UInt8}, Cint, Ptr{Cvoid}),
        digest,
        length(digest),
        key,
    )
    signature == C_NULL && error("ECDSA signing failed")
    try
        r, s = Ref{Ptr{Cvoid}}(C_NULL), Ref{Ptr{Cvoid}}(C_NULL)
        ccall(
            (:ECDSA_SIG_get0, CRYPTO_LIBRARY),
            Cvoid,
            (Ptr{Cvoid}, Ref{Ptr{Cvoid}}, Ref{Ptr{Cvoid}}),
            signature,
            r,
            s,
        )
        output = Vector{UInt8}(undef, 64)
        GC.@preserve output begin
            ccall(
                (:BN_bn2binpad, CRYPTO_LIBRARY),
                Cint,
                (Ptr{Cvoid}, Ptr{UInt8}, Cint),
                r[],
                pointer(output),
                32,
            ) == 32 || error("cannot export ECDSA r")
            ccall(
                (:BN_bn2binpad, CRYPTO_LIBRARY),
                Cint,
                (Ptr{Cvoid}, Ptr{UInt8}, Cint),
                s[],
                pointer(output, 33),
                32,
            ) == 32 || error("cannot export ECDSA s")
        end
        return output
    finally
        ccall((:ECDSA_SIG_free, CRYPTO_LIBRARY), Cvoid, (Ptr{Cvoid},), signature)
    end
end

function vapid_authorization(
    public_key,
    private_key,
    endpoint;
    subject = get(ENV, "VAPID_SUBJECT", "mailto:admin@localhost"),
    at = floor(Int, time()),
)
    uri = unfurl_uri(endpoint)
    uri !== nothing && uri.scheme == "https" ||
        throw(ArgumentError("push endpoints require HTTPS"))
    startswith(subject, "mailto:") ||
        startswith(subject, "https://") ||
        throw(ArgumentError("VAPID_SUBJECT must be a mailto or HTTPS URI"))
    port = isempty(uri.port) || uri.port == "443" ? "" : ":" * uri.port
    audience = "https://" * lowercase(uri.host) * port
    header = urlbase64(JSON3.write((typ = "JWT", alg = "ES256")))
    claims = urlbase64(JSON3.write((aud = audience, exp = at + 12 * 3600, sub = subject)))
    input = header * "." * claims
    signature = with_p256(; private = unurlbase64(private_key)) do key
        return p256_sign(key, codeunits(input))
    end
    return "vapid t=" * input * "." * urlbase64(signature) * ", k=" * public_key
end

function permitted_push_endpoint(endpoint)
    uri = unfurl_uri(endpoint)
    uri === nothing && return false
    uri.scheme == "https" && uri.port in ("", "443") || return false
    host = lowercase(uri.host)
    return any(
        provider -> host == provider || endswith(host, "." * provider),
        (
            "jmt17.google.com",
            "fcm.googleapis.com",
            "updates.push.services.mozilla.com",
            "web.push.apple.com",
            "notify.windows.com",
        ),
    )
end

function valid_push_keys(public_key, auth_key)
    try
        public, auth = unurlbase64(public_key), unurlbase64(auth_key)
        length(auth) == 16 || return false
        return with_p256(_ -> true; public = public)
    catch error
        error isa InterruptException && rethrow()
        return false
    end
end

function send_web_push(
    app,
    subscription,
    payload;
    resolver = Sockets.getalladdrinfo,
    fetcher = curl_unfurl_fetch,
)
    permitted_push_endpoint(subscription.endpoint) || return nothing
    valid_push_keys(subscription.p256dh_key, subscription.auth_key) || return nothing
    deadline = time() + 10
    uri = unfurl_uri(subscription.endpoint)
    ip = public_resolution(uri, deadline; resolver = resolver)
    ip === nothing && return nothing
    encrypted = encrypt_push(
        payload,
        unurlbase64(subscription.p256dh_key),
        unurlbase64(subscription.auth_key),
    )
    headers = [
        "Content-Type" => "application/octet-stream",
        "Content-Encoding" => "aes128gcm",
        "TTL" => "86400",
        "Urgency" => "high",
        "Authorization" => vapid_authorization(
            app.vapid_public_key,
            app.vapid_private_key,
            subscription.endpoint,
        ),
    ]
    # A subscription endpoint is an exact capability. Never follow redirects
    # while sending its ciphertext or authorization token elsewhere.
    response =
        fetcher(uri, ip, deadline; method = "POST", body = encrypted, headers = headers)
    return response === nothing ? nothing : response.status
end

function push_json(title, body, path, badge)
    clipped_title = first(string(title), 120)
    clipped_body = first(string(body), 1000)
    while true
        payload = JSON3.write((
            title = clipped_title,
            options = (
                body = clipped_body,
                icon = "/account/logo",
                data = (path = path, badge = badge),
            ),
        ))
        ncodeunits(payload) <= 3993 && return payload
        isempty(clipped_body) &&
            throw(ArgumentError("push notification metadata is too large"))
        clipped_body = first(clipped_body, max(0, length(clipped_body) ÷ 2))
    end
end

function deliver_push_subscription!(app, subscription, payload; sender = send_web_push)
    status = try
        sender(app, subscription, payload)
    catch error
        @warn "Push notification delivery failed" subscription_id = subscription.id exception =
            (error, catch_backtrace())
        nothing
    end
    if status in (404, 410)
        lock(app.lock) do
            return execute!(
                app,
                "DELETE FROM push_subscriptions WHERE id = ? AND endpoint = ?",
                (subscription.id, subscription.endpoint),
            )
        end
    end
    return status
end

const PushSubscription = @NamedTuple{
    id::Int64,
    auth_key::Union{Missing,String},
    created_at::String,
    endpoint::Union{Missing,String},
    p256dh_key::Union{Missing,String},
    updated_at::String,
    user_agent::Union{Missing,String},
    user_id::Int64,
    involvement::String,
    delivery_room_id::Int64,
    delivery_creator_id::Int64,
}

const PushMessage = @NamedTuple{
    creator_id::Int64,
    room_id::Int64,
    author::String,
    room_name::Union{Missing,String},
    room_type::String,
    editable_body::String,
    plain_text::String,
}

function message_push_subscriptions(app, message_id)
    return withquery(
        app,
        """
SELECT p.*, mm.involvement, msg.room_id AS delivery_room_id,
  msg.creator_id AS delivery_creator_id FROM messages msg
JOIN users author ON author.id=msg.creator_id AND author.status=0
JOIN memberships mm ON mm.room_id=msg.room_id
JOIN users recipient ON recipient.id=mm.user_id
JOIN push_subscriptions p ON p.user_id=recipient.id
WHERE msg.id=? AND recipient.status=0 AND recipient.id<>msg.creator_id
  AND mm.connections=0 AND mm.involvement IN ('everything','mentions')
""",
        (message_id,),
    ) do rows
        # The fixed projection avoids rebuilding a heterogeneous tuple for each
        # row, while SQLite.jl still copies strings before the statement resets.
        return [
            PushSubscription((
                row.id,
                row.auth_key,
                row.created_at,
                row.endpoint,
                row.p256dh_key,
                row.updated_at,
                row.user_agent,
                row.user_id,
                row.involvement,
                row.delivery_room_id,
                row.delivery_creator_id,
            )) for row in rows
        ]
    end
end

function message_push_message(app, message_id, room_id, creator_id)
    return withquery(
        app,
        """
SELECT m.creator_id,m.room_id,u.name AS author,r.name AS room_name,r.type AS room_type,
  COALESCE(rt.body,'') AS editable_body,COALESCE(idx.body,'') AS plain_text
FROM messages m JOIN users u ON u.id=m.creator_id AND u.status=0
JOIN rooms r ON r.id=m.room_id
LEFT JOIN action_text_rich_texts rt ON rt.record_type='Message'
  AND rt.record_id=m.id AND rt.name='body'
LEFT JOIN message_search_index idx ON idx.rowid=m.id
WHERE m.id=? AND m.room_id=? AND m.creator_id=?
""",
        (message_id, room_id, creator_id),
    ) do rows
        for row in rows
            return PushMessage((
                row.creator_id,
                row.room_id,
                row.author,
                row.room_name,
                row.room_type,
                row.editable_body,
                row.plain_text,
            ))
        end
        return nothing
    end
end

function message_push_badge(app, user_id::Int64)
    statement = prepared_statement(
        app,
        "SELECT count(*) FROM memberships WHERE user_id = ? AND unread_at IS NOT NULL AND involvement != 'invisible'",
    )
    return with_statement(statement, (user_id,)) do handle, status
        status == SQLite.C.SQLITE_ROW &&
        SQLite.C.sqlite3_column_type(handle, 0) == SQLite.C.SQLITE_INTEGER ||
            throw(SQLite.SQLiteException("Push badge count must be an integer"))
        return SQLite.C.sqlite3_column_int64(handle, 0)
    end
end

function message_push_snapshot(app, message_id)
    return lock(app.lock) do
        # Select current recipients before loading a body or preparing a payload.
        # No presentation, account, avatar, boost or attachment data is needed.
        subscriptions = message_push_subscriptions(app, message_id)
        isempty(subscriptions) && return nothing
        # Read fresh message text and author/room labels at delivery time. The
        # stored rich text is used only to verify mention identities; the push
        # body uses the plain-text search value, never rendered HTML.
        message = message_push_message(
            app,
            message_id,
            # An external SQL writer can move a message between these reads.
            # Never pair its new room or author with the old recipient list.
            first(subscriptions).delivery_room_id,
            first(subscriptions).delivery_creator_id,
        )
        message === nothing && return nothing
        if any(subscription -> subscription.involvement == "mentions", subscriptions)
            mentioned = mentioned_user_ids(app, message.editable_body)
            filter!(subscriptions) do subscription
                return subscription.involvement == "everything" ||
                       subscription.user_id in mentioned
            end
            isempty(subscriptions) && return nothing
        end
        # Capture counts in recipient order while the writer lock is held. All
        # strings in this snapshot are already copied by SQLite.jl.
        badges = Int64[
            message_push_badge(app, subscription.user_id) for subscription in subscriptions
        ]
        return (; message, subscriptions, badges)
    end
end

function message_push_deliveries(snapshot)
    snapshot === nothing && return Tuple{NamedTuple,String}[]
    message = snapshot.message
    direct = message.room_type == "Rooms::Direct"
    title = direct ? message.author : coalesce(message.room_name, "Campfire")
    body = direct ? message.plain_text : message.author * ": " * message.plain_text
    path = "/rooms/$(message.room_id)"
    deliveries = Tuple{NamedTuple,String}[]
    for index in eachindex(snapshot.subscriptions)
        subscription = snapshot.subscriptions[index]
        badge = snapshot.badges[index]
        push!(deliveries, (subscription, push_json(title, body, path, badge)))
    end
    return deliveries
end

function message_push_deliveries(app, message_id, base_url)
    snapshot = message_push_snapshot(app, message_id)
    # Release the writer lock before encoding; build the entire batch before
    # deliver_message_push! sends anything, including when encoding throws.
    return message_push_deliveries(snapshot)
end

function deliver_message_push!(app, message_id, base_url; sender = send_web_push)
    for (subscription, payload) in message_push_deliveries(app, message_id, base_url)
        deliver_push_subscription!(app, subscription, payload; sender = sender)
    end
    return nothing
end

function deliver_test_push!(app, subscription_id, base_url; sender = send_web_push)
    subscription = lock(app.lock) do
        return qone(
            app,
            "SELECT p.* FROM push_subscriptions p JOIN users u ON u.id = p.user_id WHERE p.id = ? AND u.status = 0",
            (subscription_id,),
        )
    end
    subscription === nothing && return nothing
    return deliver_push_subscription!(
        app,
        subscription,
        push_json("Campfire Test", string(uuid4()), "/users/me/push_subscriptions", 0);
        sender = sender,
    )
end
