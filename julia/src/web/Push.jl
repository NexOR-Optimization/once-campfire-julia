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

function message_push_deliveries(app, message_id, base_url)
    return lock(app.lock) do
        basic = qone(app, "SELECT creator_id FROM messages WHERE id = ?", (message_id,))
        basic === nothing && return Tuple{NamedTuple,String}[]
        author = qone(
            app,
            "SELECT * FROM users WHERE id = ? AND status = 0",
            (basic.creator_id,),
        )
        author === nothing && return Tuple{NamedTuple,String}[]
        account = something(qone(app, "SELECT * FROM accounts LIMIT 1"), EMPTY_ACCOUNT)
        ctx = Context(
            app,
            HTTP.Request("GET", "/"),
            "GET",
            "/",
            Dict{String,Any}(),
            User(author),
            account,
            String(base_url),
            "",
            Event[],
        )
        message = get_message(ctx, message_id)
        mentioned = mentioned_user_ids(ctx, message)
        subscriptions = qrows(
            app,
            """
SELECT p.*, m.involvement FROM push_subscriptions p
JOIN users u ON u.id = p.user_id
JOIN memberships m ON m.user_id = u.id AND m.room_id = ?
WHERE u.status = 0 AND u.id != ? AND m.connections = 0
  AND m.involvement IN ('everything', 'mentions')
""",
            (message.room_id, message.creator_id),
        )
        room = qone(app, "SELECT name, type FROM rooms WHERE id = ?", (message.room_id,))
        title = room.type == "Rooms::Direct" ? author.name : coalesce(room.name, "Campfire")
        body =
            room.type == "Rooms::Direct" ? message.plain_text :
            author.name * ": " * message.plain_text
        deliveries = Tuple{NamedTuple,String}[]
        for subscription in subscriptions
            subscription.involvement == "everything" ||
                subscription.user_id in mentioned ||
                continue
            badge = scalar(
                app,
                "SELECT count(*) FROM memberships WHERE user_id = ? AND unread_at IS NOT NULL AND involvement != 'invisible'",
                (subscription.user_id,),
            )
            push!(
                deliveries,
                (subscription, push_json(title, body, "/rooms/$(message.room_id)", badge)),
            )
        end
        return deliveries
    end
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
