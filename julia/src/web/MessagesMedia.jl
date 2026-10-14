# Rich text is parsed by libxml2, then rebuilt from an explicit allowlist. Never
# interpolate stored markup into a response without this normalization.
using Libdl
const XML_LIBRARY = Libdl.find_library(["xml2", "libxml2.so.2", "libxml2.so.16"])

function initialize_media!()
    # Older libxml versions require initialization before concurrent parsing.
    ccall((:xmlInitParser, XML_LIBRARY), Cvoid, ())
    return nothing
end

struct HTMLNode
    private::Ptr{Cvoid}
    kind::Cint
    name::Ptr{UInt8}
    children::Ptr{Cvoid}
    last::Ptr{Cvoid}
    parent::Ptr{Cvoid}
    next::Ptr{Cvoid}
    previous::Ptr{Cvoid}
    document::Ptr{Cvoid}
    namespace::Ptr{Cvoid}
    content::Ptr{UInt8}
end

const RICH_TAGS = Set(
    split(
        "a b strong i em u s del strike code pre blockquote p div br hr ul ol li h1 h2 h3 h4 h5 h6 table thead tbody tfoot tr td th span sup sub mark",
    ),
)
const RICH_BLOCKS = Set(split("p div pre blockquote li h1 h2 h3 h4 h5 h6 tr"))
const RICH_DISCARD = Set(
    split(
        "head script style iframe object embed svg math template noscript form input button textarea select",
    ),
)

function media_escape(text)
    return replace(
        string(text),
        '&' => "&amp;",
        '<' => "&lt;",
        '>' => "&gt;",
        '"' => "&quot;",
        '\'' => "&#39;",
    )
end

function xml_property(node, name)
    pointer =
        ccall((:xmlGetProp, XML_LIBRARY), Ptr{UInt8}, (Ptr{Cvoid}, Cstring), node, name)
    pointer == C_NULL && return ""
    try
        return unsafe_string(pointer)
    finally
        # xmlFree is an exported function-pointer variable, not a function.
        free_pointer =
            unsafe_load(Ptr{Ptr{Cvoid}}(Libdl.dlsym(Libdl.dlopen(XML_LIBRARY), :xmlFree)))
        ccall(free_pointer, Cvoid, (Ptr{Cvoid},), pointer)
    end
end

function safe_link(value)
    value = strip(value)
    isempty(value) && return false
    any(c -> Int(c) < 0x20 || c == '\\', value) && return false
    startswith(value, "//") && return false
    (startswith(value, '/') || startswith(value, '#') || startswith(value, '?')) &&
        return true
    return occursin(r"^(?i:https?://|mailto:)", value)
end

function mention_token(ctx, id)
    return signed_token(ctx.app, "mention", string(id))
end

mention_user(ctx, token) = mention_user(ctx.app, token)

function mention_user(app::WebApp, token)
    id = verify_token(app, "mention", token)
    if isnothing(id)
        gid = verify_rails_message(
            app,
            "signed_global_ids",
            "attachable",
            token;
            digest = :sha1,
        )
        if gid isa AbstractString
            matched = match(r"^gid://[^/]+/User/(\d+)(?:\?.*)?$", gid)
            isnothing(matched) || (id = matched[1])
        end
    end
    isnothing(id) && return nothing
    return qone(app, "SELECT * FROM users WHERE id=? AND status=0", (id,))
end

function mention_html(ctx, user)
    token = mention_token(ctx, user.id)
    return "<span class=\"mention\" sgid=\"$token\"><img class=\"avatar\" src=\"/users/$(user.id)/avatar\" alt=\"\"> $(media_escape(user.name))</span>"
end

function mention_prompt_html(ctx, user)
    token = mention_token(ctx, user.id)
    avatar = signed_token(ctx.app, "avatar", string(user.id))
    name = media_escape(user.name)
    return "<lexxy-prompt-item search=\"$name\" sgid=\"$token\"><template type=\"menu\"><span class=\"autocomplete__item flex align-center gap\"><img class=\"avatar\" src=\"/users/$avatar/avatar\"><span class=\"autocompletable__name\">$name</span></span></template><template type=\"editor\">$(mention_html(ctx, user))</template></lexxy-prompt-item>"
end

function rich_nodes!(
    html,
    plain,
    pointer,
    depth = 0;
    ctx = nothing,
    storage = false,
    room = nothing,
)
    depth > 128 && return
    while pointer != C_NULL
        node = unsafe_load(Ptr{HTMLNode}(pointer))
        if node.kind == 3 || node.kind == 4
            text = node.content == C_NULL ? "" : unsafe_string(node.content)
            print(html, media_escape(text))
            print(plain, text)
        elseif node.kind == 1
            tag = lowercase(unsafe_string(node.name))
            if tag in RICH_DISCARD
                # Drop executable and foreign namespaces with their contents.
            elseif tag == "action-text-attachment"
                token = xml_property(pointer, "sgid")
                mention =
                    isnothing(ctx) || isempty(token) ? nothing : mention_user(ctx, token)
                if !isnothing(mention) && !isnothing(room)
                    isnothing(
                        scalar(
                            ctx.app,
                            "SELECT 1 FROM memberships WHERE user_id=? AND room_id=?",
                            (mention.id, room),
                        ),
                    ) && (mention = nothing)
                end
                caption = xml_property(pointer, "caption")
                isempty(caption) && (caption = xml_property(pointer, "filename"))
                content = xml_property(pointer, "content")
                if !isnothing(mention)
                    canonical = mention_html(ctx, mention)
                    if storage
                        print(
                            html,
                            "<action-text-attachment sgid=\"",
                            mention_token(ctx, mention.id),
                            "\" content-type=\"application/vnd.campfire.mention\" content=\"",
                            media_escape(canonical),
                            "\"></action-text-attachment>",
                        )
                    else
                        print(html, canonical)
                    end
                    print(plain, '@', mention.name)
                elseif !isempty(content)
                    childhtml, childplain = sanitize_rich_text(
                        content;
                        ctx = ctx,
                        storage = storage,
                        room = room,
                        depth = depth+1,
                    )
                    print(html, childhtml)
                    print(plain, childplain)
                else
                    print(html, media_escape(caption))
                    print(plain, caption)
                end
            else
                allowed = tag in RICH_TAGS
                if allowed
                    print(html, '<', tag)
                    if tag == "a"
                        href = xml_property(pointer, "href")
                        safe_link(href) && print(
                            html,
                            " href=\"",
                            media_escape(href),
                            "\" target=\"_blank\" rel=\"noopener noreferrer\"",
                        )
                    end
                    classes = xml_property(pointer, "class")
                    if occursin(r"^[a-zA-Z0-9 _-]{1,200}$", classes)
                        print(html, " class=\"", classes, '"')
                    end
                    style = xml_property(pointer, "style")
                    align = match(
                        r"(?:^|;)\s*text-align\s*:\s*(left|right|center|justify)\s*(?:;|$)",
                        style,
                    )
                    isnothing(align) || print(html, " style=\"text-align: ", align[1], "\"")
                    language = xml_property(pointer, "data-language")
                    occursin(r"^[a-zA-Z0-9_+-]{1,40}$", language) &&
                        print(html, " data-language=\"", language, "\"")
                    print(html, '>')
                end
                tag in RICH_BLOCKS && position(plain) > 0 && print(plain, '\n')
                rich_nodes!(
                    html,
                    plain,
                    node.children,
                    depth + 1;
                    ctx = ctx,
                    storage = storage,
                    room = room,
                )
                if tag == "br" || tag == "hr"
                    print(plain, '\n')
                elseif allowed
                    print(html, "</", tag, '>')
                end
            end
        end
        pointer = node.next
    end
    return nothing
end

function sanitize_rich_text(
    input::AbstractString;
    ctx = nothing,
    storage = false,
    room = nothing,
    depth = 0,
)
    depth > 128 && return ("", "")
    text = String(input)
    isvalid(text) || throw(ArgumentError("invalid UTF-8"))
    if !occursin('<', text) && !occursin('&', text)
        return (media_escape(text), text)
    end
    # Recover HTML, silence malformed-input diagnostics, and forbid network I/O.
    document = ccall(
        (:htmlReadMemory, XML_LIBRARY),
        Ptr{Cvoid},
        (Ptr{UInt8}, Cint, Cstring, Cstring, Cint),
        text,
        ncodeunits(text),
        C_NULL,
        "UTF-8",
        1 | 32 | 64 | 2048,
    )
    document == C_NULL && return (media_escape(text), text)
    try
        root =
            ccall((:xmlDocGetRootElement, XML_LIBRARY), Ptr{Cvoid}, (Ptr{Cvoid},), document)
        html, plain = IOBuffer(), IOBuffer()
        rich_nodes!(html, plain, root, depth; ctx = ctx, storage = storage, room = room)
        return (String(take!(html)), strip(String(take!(plain))))
    finally
        ccall((:xmlFreeDoc, XML_LIBRARY), Cvoid, (Ptr{Cvoid},), document)
    end
end


# Mirrors the public sound names and assets in app/models/sound.rb.
const MESSAGE_SOUNDS = Dict(
    "56k" => (
        url = "/assets/56k.mp3",
        image_url = "/assets/sounds/56k.webp",
        width = 79,
        height = 33,
        text = "",
    ),
    "bell" => (
        url = "/assets/bell.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "🔔",
    ),
    "bezos" => (
        url = "/assets/bezos.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "😆💭",
    ),
    "bueller" => (
        url = "/assets/bueller.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "anyone?",
    ),
    "butts" => (
        url = "/assets/butts.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "👐 🚬",
    ),
    "clowntown" => (
        url = "/assets/clowntown.mp3",
        image_url = "/assets/sounds/clowntown.webp",
        width = 210,
        height = 150,
        text = "",
    ),
    "cottoneyejoe" => (
        url = "/assets/cottoneyejoe.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "🎶🙉🎶 ",
    ),
    "crickets" => (
        url = "/assets/crickets.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "hears crickets chirping",
    ),
    "curb" => (
        url = "/assets/curb.mp3",
        image_url = "/assets/sounds/curb.webp",
        width = 150,
        height = 101,
        text = "",
    ),
    "dadgummit" => (
        url = "/assets/dadgummit.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "dad gummit!! 🎣",
    ),
    "dangerzone" => (
        url = "/assets/dangerzone.mp3",
        image_url = "/assets/sounds/dangerzone.webp",
        width = 157,
        height = 32,
        text = "",
    ),
    "danielsan" => (
        url = "/assets/danielsan.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "🎆 🏆 🎆",
    ),
    "deeper" => (
        url = "/assets/deeper.mp3",
        image_url = "/assets/sounds/top.webp",
        width = 188,
        height = 80,
        text = "",
    ),
    "ballmer" => (
        url = "/assets/ballmer.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "developers!",
    ),
    "donotwant" => (
        url = "/assets/donotwant.mp3",
        image_url = "/assets/sounds/donotwant.webp",
        width = 150,
        height = 150,
        text = "",
    ),
    "drama" => (
        url = "/assets/drama.mp3",
        image_url = "/assets/sounds/drama.webp",
        width = 300,
        height = 16,
        text = "",
    ),
    "flawless" => (
        url = "/assets/flawless.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "#flawless",
    ),
    "glados" => (
        url = "/assets/glados.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "🤖💢",
    ),
    "gogogo" => (
        url = "/assets/gogogo.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "Go, go, go!",
    ),
    "greatjob" => (
        url = "/assets/greatjob.mp3",
        image_url = "/assets/sounds/greatjob.webp",
        width = 79,
        height = 16,
        text = "",
    ),
    "greyjoy" => (
        url = "/assets/greyjoy.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "😖🎺",
    ),
    "guarantee" => (
        url = "/assets/guarantee.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "guarantees it 👌",
    ),
    "heygirl" => (
        url = "/assets/heygirl.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "✨💁✨",
    ),
    "honk" => (
        url = "/assets/honk.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "HONK",
    ),
    "horn" => (
        url = "/assets/horn.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "🐶 ✂️ 🐱",
    ),
    "horror" => (
        url = "/assets/horror.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "💀 💀 💀 💀 💀 💀 💀",
    ),
    "inconceivable" => (
        url = "/assets/inconceivable.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "doesn't think it means what you think it means…",
    ),
    "letitgo" => (
        url = "/assets/letitgo.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "❄️👩❄️⛄️❄️",
    ),
    "live" => (
        url = "/assets/live.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "is DOING IT LIVE",
    ),
    "loggins" => (
        url = "/assets/loggins.mp3",
        image_url = "/assets/sounds/loggins.webp",
        width = 200,
        height = 151,
        text = "",
    ),
    "makeitso" => (
        url = "/assets/makeitso.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "make it so 👉",
    ),
    "noooo" => (
        url = "/assets/noooo.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "👸💀😒",
    ),
    "nyan" => (
        url = "/assets/nyan.mp3",
        image_url = "/assets/sounds/nyan.webp",
        width = 36,
        height = 15,
        text = "",
    ),
    "ohmy" => (
        url = "/assets/ohmy.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "raises an eyebrow 😏",
    ),
    "ohyeah" => (
        url = "/assets/ohyeah.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "isn't playing by the rules",
    ),
    "pushit" => (
        url = "/assets/pushit.mp3",
        image_url = "/assets/sounds/pushit.webp",
        width = 104,
        height = 15,
        text = "",
    ),
    "rimshot" => (
        url = "/assets/rimshot.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "plays a rimshot",
    ),
    "rollout" => (
        url = "/assets/rollout.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "is rolling out 🚗",
    ),
    "rumble" => (
        url = "/assets/rumble.mp3",
        image_url = "/assets/sounds/rumble.webp",
        width = 220,
        height = 150,
        text = "",
    ),
    "sax" => (
        url = "/assets/sax.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "🌇🎷🎶",
    ),
    "secret" => (
        url = "/assets/secret.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "found a secret area 🔑",
    ),
    "sexyback" => (
        url = "/assets/sexyback.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "🔞",
    ),
    "story" => (
        url = "/assets/story.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "and now you know…",
    ),
    "tada" => (
        url = "/assets/tada.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "plays a fanfare 🎏",
    ),
    "tmyk" => (
        url = "/assets/tmyk.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "✨ ⭐️ The More You Know ✨ ⭐️",
    ),
    "totes" => (
        url = "/assets/totes.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "😁👍",
    ),
    "trololo" => (
        url = "/assets/trololo.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "трололо",
    ),
    "trombone" => (
        url = "/assets/trombone.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "plays a sad trombone",
    ),
    "unix" => (
        url = "/assets/unix.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "knows this 💻",
    ),
    "vuvuzela" => (
        url = "/assets/vuvuzela.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "======<() ~ ♪ ~♫",
    ),
    "what" => (
        url = "/assets/what.mp3",
        image_url = "/assets/sounds/what.webp",
        width = 100,
        height = 131,
        text = "",
    ),
    "whoomp" => (
        url = "/assets/whoomp.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "👏‼️😎",
    ),
    "wups" => (
        url = "/assets/wups.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "wups!",
    ),
    "yay" => (
        url = "/assets/yay.mp3",
        image_url = "/assets/sounds/yay.webp",
        width = 103,
        height = 50,
        text = "",
    ),
    "yeah" => (
        url = "/assets/yeah.mp3",
        image_url = "/assets/sounds/yeah.webp",
        width = 104,
        height = 15,
        text = "",
    ),
    "yodel" => (
        url = "/assets/yodel.mp3",
        image_url = nothing,
        width = 0,
        height = 0,
        text = "📣🗻🙉",
    ),
)

function message_sound(plain)
    matched = match(r"^/play (\w+)$", plain)
    isnothing(matched) && return nothing
    sound = get(MESSAGE_SOUNDS, matched[1], nothing)
    return isnothing(sound) ? nothing : merge(sound, (name = String(matched[1]),))
end

const WEB_MESSAGE_COLUMNS = """
SELECT m.id, m.room_id, m.creator_id, m.client_message_id, m.created_at,
 m.updated_at, u.name AS author, u.role AS author_role,
 r.name AS room_name, r.type AS room_type,
 COALESCE(rt.body, '') AS body, COALESCE(idx.body, '') AS plain_text
FROM messages m JOIN users u ON u.id=m.creator_id JOIN rooms r ON r.id=m.room_id
LEFT JOIN action_text_rich_texts rt ON rt.record_type='Message'
 AND rt.record_id=m.id AND rt.name='body'
LEFT JOIN message_search_index idx ON idx.rowid=m.id
"""

function message_presentation(ctx, row, boosts, blob)
    body, _ = sanitize_rich_text(row.body; ctx = ctx)
    attachment = isnothing(blob) ? nothing : blob_presentation(ctx, blob)
    return merge(
        row,
        (
            body = body,
            editable_body = row.body,
            avatar_token = signed_token(ctx.app, "avatar", string(row.creator_id)),
            boosts = boosts,
            attachment = attachment,
            sound = isnothing(attachment) ? message_sound(row.plain_text) : nothing,
        ),
    )
end

function message_presentations(ctx, rows)
    isempty(rows) && return rows
    # One association query for the whole page avoids an N+1 query per message.
    ids = JSON3.write([row.id for row in rows])
    boosts = qrows(
        ctx.app,
        """
SELECT b.*, u.name AS author FROM boosts b JOIN users u ON u.id=b.booster_id
WHERE b.message_id IN (SELECT value FROM json_each(?)) ORDER BY b.created_at, b.id
""",
        (ids,),
    )
    attachments = qrows(
        ctx.app,
        """
SELECT b.*, a.record_id FROM active_storage_blobs b
JOIN active_storage_attachments a ON a.blob_id=b.id
WHERE a.record_type='Message' AND a.name='attachment'
 AND a.record_id IN (SELECT value FROM json_each(?))
""",
        (ids,),
    )
    return map(rows) do row
        index = findfirst(blob -> blob.record_id == row.id, attachments)
        return message_presentation(
            ctx,
            row,
            filter(boost -> boost.message_id == row.id, boosts),
            isnothing(index) ? nothing : attachments[index],
        )
    end
end

function get_message(ctx, id; room = nothing)
    sql = WEB_MESSAGE_COLUMNS * " WHERE m.id=?"
    parameters = (id,)
    if !isnothing(room)
        sql *= " AND m.room_id=?"
        parameters = (id, room)
    end
    rows = qrows(ctx.app, sql, parameters)
    return isempty(rows) ? nothing : only(message_presentations(ctx, rows))
end

const CreatedMessageRow = @NamedTuple{
    id::Int64,
    room_id::Int64,
    creator_id::Int64,
    client_message_id::String,
    created_at::String,
    updated_at::String,
    author::String,
    author_role::Int64,
    room_name::Union{Missing,String},
    room_type::String,
    body::String,
    plain_text::String,
}

function get_created_message_row(app, id)
    # New messages usually have no associations. Read the persisted values so
    # database triggers remain visible; uploads or trigger-created associations
    # use the ordinary presentation path.
    return withquery(
        app,
        WEB_MESSAGE_COLUMNS * """
 WHERE m.id=?
 AND NOT EXISTS(SELECT 1 FROM boosts b WHERE b.message_id=m.id)
 AND NOT EXISTS(SELECT 1 FROM active_storage_attachments a
   WHERE a.record_type='Message' AND a.name='attachment' AND a.record_id=m.id)
""",
        (id,),
    ) do rows
        for row in rows
            # SQLite.jl copies text before withquery resets the statement.
            return CreatedMessageRow((
                row.id,
                row.room_id,
                row.creator_id,
                row.client_message_id,
                row.created_at,
                row.updated_at,
                row.author,
                row.author_role,
                row.room_name,
                row.room_type,
                row.body,
                row.plain_text,
            ))
        end
        return nothing
    end
end

function get_created_message(ctx, id)
    row = get_created_message_row(ctx.app, id)
    row === nothing && return get_message(ctx, id)
    return message_presentation(ctx, row, NamedTuple[], nothing)
end

function query_messages(ctx, room; before = nothing, after = nothing, around = nothing)
    if !isnothing(around)
        anchor = get_message(ctx, around; room = room)
        isnothing(anchor) && return NamedTuple[]
        return vcat(
            query_messages(ctx, room; before = around),
            [anchor],
            query_messages(ctx, room; after = around),
        )
    end
    sql, parameters = WEB_MESSAGE_COLUMNS * " WHERE m.room_id=?", (room,)
    if !isnothing(before) || !isnothing(after)
        comparison, anchor = isnothing(before) ? (">", after) : ("<", before)
        sql *= " AND m.created_at $comparison (SELECT created_at FROM messages WHERE id=? AND room_id=?)"
        parameters = (room, anchor, room)
    end
    direction = isnothing(after) ? "DESC" : "ASC"
    rows = qrows(
        ctx.app,
        sql * " ORDER BY m.created_at $direction, m.id $direction LIMIT 40",
        parameters,
    )
    isnothing(after) && reverse!(rows)
    return message_presentations(ctx, rows)
end

function reachable_room(ctx, room)
    return !isnothing(ctx.user) &&
           !isnothing(
        scalar(
            ctx.app,
            "SELECT 1 FROM memberships WHERE user_id=? AND room_id=?",
            (ctx.user.id, room),
        ),
    )
end

function message_json(ctx, message)
    role =
        message.author_role == 2 ? "bot" :
        message.author_role == 1 ? "administrator" : "member"
    return (
        id = message.id,
        created_at = iso_timestamp(message.created_at),
        body = (
            plain_text = message.plain_text,
            html = "<div class=\"trix-content\">$(message.body)</div>",
        ),
        creator = (
            id = message.creator_id,
            name = message.author,
            role = role,
            avatar_url = "$(ctx.base_url)/users/$(message.avatar_token)/avatar",
        ),
        room = (id = message.room_id,),
        url = "$(ctx.base_url)/rooms/$(message.room_id)/messages/$(message.id)",
    )
end

function iso_timestamp(value)
    text = replace(string(value), ' ' => 'T')
    endswith(text, 'Z') && return text
    occursin('.', text) || (text *= ".000")
    return text * "Z"
end

function message_stream(action, target, content = "")
    return "<turbo-stream action=\"$action\" target=\"$(media_escape(target))\"><template>$content</template></turbo-stream>"
end

function message_stream(action, target, ctx, row)
    # Reserve the stream envelope in addition to the message rendering allowance.
    io = IOBuffer(sizehint = 6144 + 128)
    print(
        io,
        "<turbo-stream action=\"",
        action,
        "\" target=\"",
        media_escape(target),
        "\"><template>",
    )
    message_html(io, ctx, row)
    print(io, "</template></turbo-stream>")
    return String(take!(io))
end

messages_target(room) = "messages_room_$(room isa Integer ? room : room.id)"

function stream_response(body; status = 200)
    return HTTP.Response(
        status,
        [
            "Content-Type" => "text/vnd.turbo-stream.html; charset=utf-8",
            "Cache-Control" => "no-store",
        ],
        body,
    )
end

function touch_message_room!(ctx, message; created = false)
    timestamp = nowstr()
    execute!(
        ctx.app,
        "UPDATE rooms SET updated_at=? WHERE id=?",
        (timestamp, message.room_id),
    )
    if created
        execute!(
            ctx.app,
            """
UPDATE memberships SET unread_at=?,updated_at=?
WHERE room_id=? AND user_id<>? AND involvement<>'invisible'
AND (connected_at IS NULL OR connected_at<?)
AND (unread_at IS NULL OR (SELECT type FROM rooms WHERE id=?)='Rooms::Direct')
""",
            (
                message.created_at,
                timestamp,
                message.room_id,
                ctx.user.id,
                Dates.format(now(UTC)-Second(60), dateformat"yyyy-mm-dd HH:MM:SS.sss"),
                message.room_id,
            ),
        )
    end
    return nothing
end

function message_body(ctx, bot; room = nothing)
    raw = bot ? String(copy(ctx.req.body)) : string(param(ctx, "message[body]", ""))
    ncodeunits(raw) > 1024 * 1024 && throw(ArgumentError("message too large"))
    return sanitize_rich_text(raw; ctx = ctx, storage = true, room = room)
end

function create_message!(ctx, room; bot = false, notify_bots = true)
    attachment_key = bot ? "attachment" : "message[attachment]"
    upload = param(ctx, attachment_key, nothing)
    body, plain = upload isa UploadedFile ? ("", "") : message_body(ctx, bot; room = room)
    isempty(strip(plain)) &&
        !(upload isa UploadedFile) &&
        return html_response("Message is empty"; status = 422)
    timestamp = nowstr()
    client_id = string(param(ctx, "message[client_message_id]", string(uuid4())))
    ncodeunits(client_id) <= 255 ||
        return html_response("Message ID is too long"; status = 422)
    execute!(
        ctx.app,
        """
INSERT INTO messages(room_id,creator_id,client_message_id,created_at,updated_at)
VALUES(?,?,?,?,?)
""",
        (room, ctx.user.id, client_id, timestamp, timestamp),
    )
    id = SQLite.last_insert_rowid(ctx.app.db)
    execute!(
        ctx.app,
        """
INSERT INTO action_text_rich_texts(name,record_type,record_id,body,created_at,updated_at)
VALUES('body','Message',?,?,?,?)
""",
        (id, body, timestamp, timestamp),
    )
    if upload isa UploadedFile
        attach_upload!(ctx, "Message", id, "attachment", attachment_key)
        isempty(plain) && (plain = upload.filename)
    end
    execute!(
        ctx.app,
        "INSERT INTO message_search_index(rowid,body) VALUES(?,?)",
        (id, plain),
    )
    message = upload isa UploadedFile ? get_message(ctx, id) : get_created_message(ctx, id)
    touch_message_room!(ctx, message; created = true)
    stream = message_stream("append", messages_target(room), ctx, message)
    broadcast_room!(ctx, room, stream)
    created_at = datetime2unix(DateTime(replace(message.created_at, ' '=>'T')))
    push!(ctx.events, Event(:unread, room, (roomId = room, at = created_at)))
    push!(ctx.events, Event(:push, message.id, ctx.base_url))
    notify_bots && enqueue_bot_webhooks!(ctx, message)
    if bot
        return html_response(
            "";
            status = 201,
            headers = ["Location" => "$(ctx.base_url)/rooms/$room/messages/$id"],
        )
    end
    return stream_response(stream)
end

mentioned_user_ids(ctx, message) = mentioned_user_ids(ctx.app, message.editable_body)

function mentioned_user_ids(app::WebApp, body::AbstractString)
    ids = Set{Int64}()
    for matched in eachmatch(r"<action-text-attachment\s+[^>]*sgid=\"([^\"]+)\"", body)
        user = mention_user(app, matched[1])
        isnothing(user) || push!(ids, user.id)
    end
    return ids
end

function enqueue_bot_webhooks!(ctx, message)
    mentioned = mentioned_user_ids(ctx, message)
    direct = message.room_type == "Rooms::Direct"
    !direct && isempty(mentioned) && return nothing
    bots = qrows(
        ctx.app,
        """
SELECT u.id FROM users u JOIN memberships mm ON mm.user_id=u.id
JOIN webhooks w ON w.user_id=u.id
WHERE mm.room_id=? AND u.role=2 AND u.status=0 AND u.id<>?
 AND w.url IS NOT NULL AND w.url<>''
""",
        (message.room_id, message.creator_id),
    )
    for bot in bots
        if direct || bot.id in mentioned
            push!(
                ctx.events,
                Event(:webhook, bot.id, (message_id = message.id, base_url = ctx.base_url)),
            )
        end
    end
    return nothing
end

function webhook_context(
    app,
    bot,
    room,
    base_url;
    body = "",
    parameters = Dict{String,Any}(),
)
    path = "/rooms/$room/$(bot.id)-$(bot.bot_token)/messages"
    request = HTTP.Request("POST", path, ["Content-Type"=>"text/html"], body)
    account = current_account(app)
    return Context(
        app,
        request,
        "POST",
        path,
        parameters,
        User(bot),
        account,
        base_url,
        "",
        Event[],
    )
end

function deliver_webhook!(app, bot_id, event; transport = HTTP.post)
    # The administrator configured this endpoint, so internal bot services are
    # allowed, as in Campfire's Rails Webhook model. Never hold the DB lock while
    # waiting for an external service.
    delivery = lock(app.lock) do
        bot = qone(
            app,
            "SELECT u.*,w.url FROM users u JOIN webhooks w ON w.user_id=u.id WHERE u.id=? AND u.role=2 AND u.status=0",
            (bot_id,),
        )
        isnothing(bot) && return nothing
        room =
            scalar(app, "SELECT room_id FROM messages WHERE id=?", (event.message_id,))
        isnothing(room) && return nothing
        ctx = webhook_context(app, bot, room, event.base_url)
        reachable_room(ctx, room) || return nothing
        message = get_message(ctx, event.message_id)
        payload = (
            user = (id = message.creator_id, name = message.author),
            room = (id = room, name = message.room_name, path = ctx.path),
            message = (
                id = message.id,
                body = (
                    html = message.editable_body,
                    plain = strip(replace(message.plain_text, "@$(bot.name)"=>"")),
                ),
                path = "/rooms/$room/@$(message.id)",
            ),
        )
        return (bot = bot, room = room, payload = payload)
    end
    isnothing(delivery) && return nothing
    response = try
        transport(
            delivery.bot.url,
            ["Content-Type"=>"application/json"],
            JSON3.write(delivery.payload);
            status_exception = false,
            retry = false,
            readtimeout = 7,
            connect_timeout = 7,
            redirect = false,
        )
    catch error
        @warn "Bot webhook request failed" bot_id exception=(error, catch_backtrace())
        return nothing
    end
    response.status == 200 || return nothing
    length(response.body) <= 32 * 1024^2 || return nothing
    content_type =
        lowercase(strip(first(split(HTTP.header(response, "Content-Type"), ';'))))
    isempty(content_type) && return nothing
    parameters = Dict{String,Any}()
    body = ""
    if content_type in ("text/plain", "text/html")
        body = String(copy(response.body))
        isvalid(body) && ncodeunits(body) <= 1024 * 1024 || return nothing
    else
        extensions = Dict(
            "image/png"=>"png",
            "image/jpeg"=>"jpg",
            "image/webp"=>"webp",
            "image/gif"=>"gif",
            "application/pdf"=>"pdf",
            "audio/mpeg"=>"mp3",
            "video/mp4"=>"mp4",
        )
        parameters["attachment"] = UploadedFile(
            "attachment." * get(extensions, content_type, "bin"),
            content_type,
            response.body,
        )
    end
    events = Event[]
    lock(app.lock) do
        execute!(app, "BEGIN IMMEDIATE")
        try
            bot = qone(
                app,
                "SELECT * FROM users WHERE id=? AND role=2 AND status=0",
                (bot_id,),
            )
            if isnothing(bot)
                execute!(app, "ROLLBACK")
                return
            end
            ctx = webhook_context(
                app,
                bot,
                delivery.room,
                event.base_url;
                body = body,
                parameters = parameters,
            )
            if !reachable_room(ctx, delivery.room)
                execute!(app, "ROLLBACK")
                return
            end
            result = create_message!(ctx, delivery.room; bot = true, notify_bots = false)
            execute!(app, result.status < 400 ? "COMMIT" : "ROLLBACK")
            result.status < 400 && append!(events, ctx.events)
        catch
            execute!(app, "ROLLBACK")
            rethrow()
        end
    end
    publish_events!(app, events)
    return nothing
end

function update_message!(ctx, message; bot = false)
    upload = param(ctx, bot ? "attachment" : "message[attachment]", nothing)
    body, plain =
        upload isa UploadedFile ? ("", upload.filename) :
        message_body(ctx, bot; room = message.room_id)
    upload isa UploadedFile && attach_upload!(
        ctx,
        "Message",
        message.id,
        "attachment",
        bot ? "attachment" : "message[attachment]",
    )
    timestamp = nowstr()
    execute!(
        ctx.app,
        """
INSERT INTO action_text_rich_texts(name,record_type,record_id,body,created_at,updated_at)
VALUES('body','Message',?,?,?,?)
ON CONFLICT(record_type,record_id,name) DO UPDATE SET body=excluded.body,updated_at=excluded.updated_at
""",
        (message.id, body, timestamp, timestamp),
    )
    execute!(
        ctx.app,
        "UPDATE messages SET updated_at=? WHERE id=?",
        (timestamp, message.id),
    )
    execute!(
        ctx.app,
        "UPDATE message_search_index SET body=? WHERE rowid=?",
        (plain, message.id),
    )
    message = get_message(ctx, message.id)
    touch_message_room!(ctx, message)
    broadcast_room!(
        ctx,
        message.room_id,
        message_stream("replace", "message_$(message.id)", ctx, message),
    )
    return bot ? json_response(message_json(ctx, message)) :
           redirect("/rooms/$(message.room_id)/messages/$(message.id)")
end

function delete_message!(ctx, message; bot = false)
    execute!(ctx.app, "DELETE FROM boosts WHERE message_id=?", (message.id,))
    purge = detach_attachments!(ctx.app, "Message", message.id)
    for rich_text in qrows(
        ctx.app,
        "SELECT id FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?",
        (message.id,),
    )
        Base.append!(
            purge,
            detach_attachments!(ctx.app, "ActionText::RichText", rich_text.id),
        )
    end
    isempty(purge) || push!(ctx.events, Event(:purge_storage, 0, purge))
    execute!(
        ctx.app,
        "DELETE FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?",
        (message.id,),
    )
    execute!(ctx.app, "DELETE FROM message_search_index WHERE rowid=?", (message.id,))
    execute!(ctx.app, "DELETE FROM messages WHERE id=?", (message.id,))
    touch_message_room!(ctx, message)
    stream = message_stream("remove", "message_$(message.id)")
    broadcast_room!(ctx, message.room_id, stream)
    return bot ? html_response(""; status = 204) : stream_response(stream)
end

function remove_banned_messages!(ctx, user_id)
    rows = qrows(ctx.app, WEB_MESSAGE_COLUMNS * " WHERE m.creator_id=?", (user_id,))
    for message in rows
        delete_message!(ctx, message)
    end
    return nothing
end

function bot_authenticate!(ctx, key)
    parts = split(key, '-'; limit = 2)
    length(parts) == 2 && !isempty(parts[2]) || return false
    id = tryparse(Int64, parts[1])
    isnothing(id) && return false
    row = qone(
        ctx.app,
        "SELECT * FROM users WHERE id=? AND bot_token=? AND role=2 AND status=0",
        (id, parts[2]),
    )
    isnothing(row) && return false
    ctx.user = User(row)
    return true
end

function route_messages(ctx)
    startswith(ctx.path, "/searches") && return route_search(ctx)
    route = match(
        r"^/rooms/(\d+)/(?:([^/]+)/)?messages(?:/(\d+))?(?:/(edit|boosts)(?:/(\d+|new))?)?$",
        ctx.path,
    )
    single =
        isnothing(route) ?
        match(r"^/messages/(\d+)(?:/(edit|boosts)(?:/(\d+|new))?)?$", ctx.path) : nothing
    isnothing(route) && isnothing(single) && return nothing
    bot = !isnothing(route) && !isnothing(route[2])
    if bot
        bot_authenticate!(ctx, route[2]) || return redirect("/session/new")
    elseif isnothing(ctx.user)
        return redirect("/session/new")
    elseif ctx.user.role == 2
        return html_response("Forbidden"; status = 403)
    end
    id =
        isnothing(route) ? parse(Int64, single[1]) :
        isnothing(route[3]) ? nothing : parse(Int64, route[3])
    room =
        isnothing(route) ?
        scalar(ctx.app, "SELECT room_id FROM messages WHERE id=?", (id,)) :
        parse(Int64, route[1])
    isnothing(room) && return html_response("Not found"; status = 404)
    reachable_room(ctx, room) || return html_response("Not found"; status = 404)
    suffix = isnothing(route) ? single[2] : route[4]
    suffix_id = isnothing(route) ? single[3] : route[5]
    if isnothing(id)
        if ctx.method == "POST"
            return create_message!(ctx, room; bot = bot)
        elseif ctx.method == "GET"
            before, after = param(ctx, "before", nothing), param(ctx, "after", nothing)
            for anchor in (before, after)
                isnothing(anchor) && continue
                idnum = tryparse(Int64, string(anchor))
                (
                    isnothing(idnum) || isnothing(
                        scalar(
                            ctx.app,
                            "SELECT 1 FROM messages WHERE id=? AND room_id=?",
                            (idnum, room),
                        ),
                    )
                ) && return html_response("Not found"; status = 404)
            end
            messages = query_messages(ctx, room; before = before, after = after)
            if bot
                headers = [
                    "X-Total-Count" => string(
                        scalar(
                            ctx.app,
                            "SELECT messages_count FROM rooms WHERE id=?",
                            (room,);
                            default = 0,
                        ),
                    ),
                ]
                if !isempty(messages)
                    boundary = isnothing(after) ? first(messages) : last(messages)
                    comparison = isnothing(after) ? "<" : ">"
                    if !isnothing(
                        scalar(
                            ctx.app,
                            "SELECT 1 FROM messages WHERE room_id=? AND created_at $comparison ? LIMIT 1",
                            (room, boundary.created_at),
                        ),
                    )
                        parameter = isnothing(after) ? "before" : "after"
                        push!(
                            headers,
                            "Link" => "<$(ctx.base_url)$(ctx.path)?$parameter=$(boundary.id)>; rel=\"next\"",
                        )
                    end
                end
                return json_response(
                    [message_json(ctx, m) for m in messages];
                    headers = headers,
                )
            end
            isempty(messages) && return html_response(""; status = 204)
            return html_response(join(message_html(ctx, message) for message in messages))
        end
        return html_response("Method not allowed"; status = 405)
    end
    message = get_message(ctx, id; room = room)
    isnothing(message) && return html_response("Not found"; status = 404)
    suffix == "boosts" && return route_boost(ctx, message, suffix_id; bot = bot)
    administration = ctx.user.role == 1 || message.creator_id == ctx.user.id
    if ctx.method in ("PUT", "PATCH", "DELETE") || suffix == "edit"
        administration || return html_response("Forbidden"; status = 403)
    end
    if ctx.method == "GET"
        return html_response(
            suffix == "edit" ? edit_message_html(ctx, message) : message_html(ctx, message),
        )
    elseif ctx.method in ("PATCH", "PUT")
        return update_message!(ctx, message; bot = bot)
    elseif ctx.method == "DELETE"
        return delete_message!(ctx, message; bot = bot)
    end
    return html_response("Method not allowed"; status = 405)
end

function boost_html(boost)
    return "<span id=\"boost_$(boost.id)\" class=\"boost\" title=\"$(media_escape(boost.author))\">$(media_escape(boost.content))</span>"
end

function route_boost(ctx, message, id; bot = false)
    if ctx.method == "POST"
        content =
            bot ? String(copy(ctx.req.body)) : string(param(ctx, "boost[content]", ""))
        isvalid(content) && !isempty(strip(content)) && length(content) <= 16 ||
            return html_response("Invalid boost"; status = 422)
        timestamp = nowstr()
        execute!(
            ctx.app,
            "INSERT INTO boosts(message_id,booster_id,content,created_at,updated_at) VALUES(?,?,?,?,?)",
            (message.id, ctx.user.id, content, timestamp, timestamp),
        )
        id = SQLite.last_insert_rowid(ctx.app.db)
        boost = (id = id, content = content, author = ctx.user.name, created_at = timestamp)
        execute!(
            ctx.app,
            "UPDATE messages SET updated_at=? WHERE id=?",
            (timestamp, message.id),
        )
        touch_message_room!(ctx, message)
        broadcast_room!(
            ctx,
            message.room_id,
            message_stream(
                "append",
                "boosts_message_$(message.id)",
                boost_html(ctx, merge(boost, (booster_id = ctx.user.id,)), message.id),
            ),
        )
        if bot
            return json_response(
                (
                    id = id,
                    content = content,
                    created_at = iso_timestamp(timestamp),
                    booster = (
                        id = ctx.user.id,
                        name = ctx.user.name,
                        role = "bot",
                        avatar_url = "$(ctx.base_url)/users/$(signed_token(ctx.app,"avatar",string(ctx.user.id)))/avatar",
                    ),
                    message = (
                        id = message.id,
                        url = "$(ctx.base_url)/rooms/$(message.room_id)/messages/$(message.id)",
                    ),
                );
                status = 201,
            )
        end
        return redirect("/messages/$(message.id)/boosts")
    elseif ctx.method == "DELETE"
        boost = qone(
            ctx.app,
            "SELECT * FROM boosts WHERE id=? AND message_id=? AND booster_id=?",
            (id, message.id, ctx.user.id),
        )
        isnothing(boost) && return html_response("Not found"; status = 404)
        execute!(ctx.app, "DELETE FROM boosts WHERE id=?", (boost.id,))
        execute!(
            ctx.app,
            "UPDATE messages SET updated_at=? WHERE id=?",
            (nowstr(), message.id),
        )
        touch_message_room!(ctx, message)
        broadcast_room!(ctx, message.room_id, message_stream("remove", "boost_$(boost.id)"))
        return html_response(""; status = 204)
    elseif ctx.method == "GET"
        if id == "new"
            return html_response(
                "<turbo-frame id=\"new_boost_message_$(message.id)\"><form action=\"/messages/$(message.id)/boosts\" method=\"post\" data-turbo-frame=\"boosting_message_$(message.id)\"><input type=\"hidden\" name=\"authenticity_token\" value=\"$(media_escape(ctx.csrf))\"><input name=\"boost[content]\" aria-label=\"Boost\" maxlength=\"16\"><button type=\"submit\">Boost</button></form></turbo-frame>",
            )
        end
        return html_response(boosts_html(ctx, message))
    end
    return html_response("Method not allowed"; status = 405)
end

function route_search(ctx)
    ctx.path in ("/searches", "/searches/clear") || return nothing
    isnothing(ctx.user) && return redirect("/session/new")
    query = strip(replace(string(param(ctx, "q", "")), r"[^\p{L}\p{N}_]" => " "))
    if ctx.method == "POST"
        if !isempty(query)
            timestamp = nowstr()
            existing = scalar(
                ctx.app,
                "SELECT id FROM searches WHERE user_id=? AND query=?",
                (ctx.user.id, query),
            )
            if isnothing(existing)
                execute!(
                    ctx.app,
                    "INSERT INTO searches(user_id,query,created_at,updated_at) VALUES(?,?,?,?)",
                    (ctx.user.id, query, timestamp, timestamp),
                )
            else
                execute!(
                    ctx.app,
                    "UPDATE searches SET updated_at=? WHERE id=?",
                    (timestamp, existing),
                )
            end
            execute!(
                ctx.app,
                "DELETE FROM searches WHERE user_id=? AND id NOT IN(SELECT id FROM searches WHERE user_id=? ORDER BY updated_at DESC,id DESC LIMIT 10)",
                (ctx.user.id, ctx.user.id),
            )
        end
        return redirect("/searches?q=$(HTTP.escapeuri(query))")
    elseif ctx.method == "DELETE"
        execute!(ctx.app, "DELETE FROM searches WHERE user_id=?", (ctx.user.id,))
        return redirect("/searches")
    elseif ctx.method != "GET"
        return html_response("Method not allowed"; status = 405)
    end
    search_columns = replace(
        WEB_MESSAGE_COLUMNS,
        "LEFT JOIN message_search_index" => "JOIN message_search_index",
    )
    rows =
        isempty(query) ? NamedTuple[] :
        qrows(
            ctx.app,
            search_columns * """
JOIN memberships mm ON mm.room_id=m.room_id AND mm.user_id=?
WHERE idx.body MATCH ? ORDER BY m.id DESC LIMIT 100
""",
            (ctx.user.id, join(('"' * word * '"' for word in split(query)), ' ')),
        )
    reverse!(rows)
    return html_response(search_page_html(ctx, message_presentations(ctx, rows), query))
end

function blob_path(app, key)
    occursin(r"^[A-Za-z0-9_-]{4,128}$", key) || throw(ArgumentError("invalid storage key"))
    return joinpath(app.storage_root, key[1:2], key[3:4], key)
end

function attachment_blob(app, record_type, id, name)
    return qone(
        app,
        """
SELECT b.* FROM active_storage_blobs b JOIN active_storage_attachments a ON a.blob_id=b.id
WHERE a.record_type=? AND a.record_id=? AND a.name=? ORDER BY a.id DESC LIMIT 1
""",
        (record_type, id, name),
    )
end

function read_blob(app, blob)
    return lock(app.storage_lock) do
        return read(blob_path(app, blob.key))
    end
end

function detach_attachments!(app, record_type, id; name = nothing)
    scope = "record_type=? AND record_id=?" * (isnothing(name) ? "" : " AND name=?")
    parameters = isnothing(name) ? (record_type, id) : (record_type, id, name)
    blobs = qrows(
        app,
        "SELECT DISTINCT blob_id FROM active_storage_attachments WHERE $scope",
        parameters,
    )
    execute!(app, "DELETE FROM active_storage_attachments WHERE $scope", parameters)
    keys = String[]
    for row in blobs
        isnothing(
            scalar(
                app,
                "SELECT 1 FROM active_storage_attachments WHERE blob_id=? LIMIT 1",
                (row.blob_id,),
            ),
        ) || continue
        for variant in qrows(
            app,
            "SELECT id FROM active_storage_variant_records WHERE blob_id=?",
            (row.blob_id,),
        )
            Base.append!(
                keys,
                detach_attachments!(app, "ActiveStorage::VariantRecord", variant.id),
            )
        end
        execute!(
            app,
            "DELETE FROM active_storage_variant_records WHERE blob_id=?",
            (row.blob_id,),
        )
        key = scalar(app, "SELECT key FROM active_storage_blobs WHERE id=?", (row.blob_id,))
        isnothing(key) || push!(keys, key)
        execute!(app, "DELETE FROM active_storage_blobs WHERE id=?", (row.blob_id,))
    end
    return keys
end

function purge_storage!(app, keys)
    lock(app.lock) do
        lock(app.storage_lock) do
            for key in keys
                # Recheck after commit, so rollback can never delete a live file.
                isnothing(
                    scalar(app, "SELECT 1 FROM active_storage_blobs WHERE key=?", (key,)),
                ) || continue
                path = blob_path(app, key)
                for suffix in
                    ("", "-thumbnail.webp", "-no-thumbnail", "-avatar.webp", "-logo.png")
                    rm(path * suffix; force = true)
                end
            end
        end
    end
    return nothing
end

function attach_upload!(app, record_type, id, name, upload::UploadedFile; cleanup = nothing)
    length(upload.data) <= 100 * 1024^2 || throw(ArgumentError("attachment too large"))
    filename = replace(basename(replace(upload.filename, '\\'=>'/')), r"[\x00-\x1f]" => "")
    isempty(filename) && (filename = "attachment")
    key = replace(string(uuid4()), "-"=>"")
    path = blob_path(app, key)
    lock(app.storage_lock) do
        mkpath(dirname(path))
        return write(path, upload.data)
    end
    timestamp = nowstr()
    content_type =
        occursin(r"^[a-zA-Z0-9.+-]+/[a-zA-Z0-9.+-]+$", upload.content_type) ?
        upload.content_type : "application/octet-stream"
    execute!(
        app,
        """
INSERT INTO active_storage_blobs(key,filename,content_type,metadata,service_name,byte_size,created_at,checksum)
VALUES(?,?,?,'{}','local',?,?,?)
""",
        (
            key,
            filename,
            content_type,
            length(upload.data),
            timestamp,
            blob_checksum(upload.data),
        ),
    )
    blob_id = SQLite.last_insert_rowid(app.db)
    keys = detach_attachments!(app, record_type, id; name = name)
    isnothing(cleanup) || Base.append!(cleanup, keys)
    execute!(
        app,
        "INSERT INTO active_storage_attachments(name,record_type,record_id,blob_id,created_at) VALUES(?,?,?,?,?)",
        (name, record_type, id, blob_id, timestamp),
    )
    return attachment_blob(app, record_type, id, name)
end

function blob_checksum(data)
    digest = ccall((:EVP_md5, CRYPTO_LIBRARY), Ptr{Cvoid}, ())
    bytes = Vector{UInt8}(undef, 16)
    size = Ref{Cuint}(16)
    result = ccall(
        (:EVP_Digest, CRYPTO_LIBRARY),
        Cint,
        (Ptr{UInt8}, Csize_t, Ptr{UInt8}, Ref{Cuint}, Ptr{Cvoid}, Ptr{Cvoid}),
        data,
        length(data),
        bytes,
        size,
        digest,
        C_NULL,
    )
    result == 1 && size[] == 16 || error("Unable to compute Active Storage checksum")
    return base64encode(bytes)
end

function attach_upload!(ctx, record_type, id, name, param_key::AbstractString)
    upload = param(ctx, param_key, nothing)
    upload isa UploadedFile || return nothing
    keys = String[]
    blob = attach_upload!(ctx.app, record_type, id, name, upload; cleanup = keys)
    isempty(keys) || push!(ctx.events, Event(:purge_storage, 0, keys))
    return blob
end

function blob_presentation(ctx, blob)
    token = signed_token(ctx.app, "blob", string(blob.id))
    url = "/rails/active_storage/blobs/redirect/$token/$(HTTP.escapeuri(blob.filename))"
    preview = attachment_preview(ctx.app, blob)
    preview_url =
        isnothing(preview) ? nothing :
        "/rails/active_storage/representations/redirect/$token/thumbnail/$(HTTP.escapeuri(blob.filename)).webp"
    return merge(blob, (url = url, preview_url = preview_url))
end

function attachment_preview(app, blob)
    return lock(app.storage_lock) do
        return attachment_preview_locked(app, blob)
    end
end

function render_variant(f::F, destination) where {F}
    # Keep the extension for encoder selection, and publish only complete bytes.
    return mktempdir(dirname(destination); prefix = ".variant-") do directory
        temporary = joinpath(directory, basename(destination))
        f(temporary)
        Base.Filesystem.rename(temporary, destination)
        return destination
    end
end

function attachment_preview_locked(app, blob)
    content_type = string(coalesce(blob.content_type, ""))
    (startswith(content_type, "image/") || startswith(content_type, "video/")) ||
        return nothing
    source = blob_path(app, blob.key)
    isfile(source) || return nothing
    destination = source * "-thumbnail.webp"
    isfile(destination) && return destination
    isfile(source * "-no-thumbnail") && return nothing
    try
        if startswith(content_type, "image/")
            bitmap_file(source) || return nothing
            width = parse(
                Int,
                strip(
                    read(
                        pipeline(
                            safe_vips(`vipsheader -f width $source`);
                            stderr = devnull,
                        ),
                        String,
                    ),
                ),
            )
            height = parse(
                Int,
                strip(
                    read(
                        pipeline(
                            safe_vips(`vipsheader -f height $source`);
                            stderr = devnull,
                        ),
                        String,
                    ),
                ),
            )
            0 < width <= 250_000_000 ÷ max(height, 1) && height > 0 || return nothing
            render_variant(destination) do temporary
                return run(
                    pipeline(
                        safe_vips(
                            `vips thumbnail $source $temporary 1200 --height 800 --size down`,
                        );
                        stdout = devnull,
                        stderr = devnull,
                    ),
                )
            end
        else
            formats = "mov,mp4,m4a,3gp,3g2,mj2,matroska,webm,avi,mpeg,mpegts,ogg"
            metadata = JSON3.read(
                read(
                    pipeline(
                        `ffprobe -v error -protocol_whitelist file,pipe -format_whitelist $formats -select_streams v:0 -show_entries stream=width,height -of json $source`;
                        stderr = devnull,
                    ),
                    String,
                ),
            )
            stream = first(metadata.streams)
            width, height = Int(stream.width), Int(stream.height)
            0 < width <= 250_000_000 ÷ max(height, 1) && height > 0 || return nothing
            filter = "scale=w=min(1200\\,iw):h=min(800\\,ih):force_original_aspect_ratio=decrease"
            render_variant(destination) do temporary
                return run(
                    pipeline(
                        `ffmpeg -v error -nostdin -y -protocol_whitelist file,pipe -format_whitelist $formats -i $source -frames:v 1 -vf $filter $temporary`;
                        stdout = devnull,
                        stderr = devnull,
                    ),
                )
            end
        end
        return isfile(destination) ? destination : nothing
    catch error
        error isa InterruptException && rethrow()
        isfile(destination) && rm(destination; force = true)
        touch(source * "-no-thumbnail")
        return nothing
    end
end

safe_vips(command) = addenv(command, "VIPS_BLOCK_UNTRUSTED"=>"1", "VIPS_CONCURRENCY"=>"1")

function bitmap_file(path)
    # Autodetection must not select document/vector loaders with external
    # resource references based solely on a user-supplied MIME type.
    header = open(path, "r") do io
        return read(io, 12)
    end
    length(header) >= 12 || return false
    return header[1:8] == UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] ||
           header[1:3] == UInt8[0xff, 0xd8, 0xff] ||
           (header[1:4] == codeunits("RIFF") && header[9:12] == codeunits("WEBP")) ||
           header[1:6] in (codeunits("GIF87a"), codeunits("GIF89a")) ||
           header[1:4] in (UInt8[0x49, 0x49, 0x2a, 0x00], UInt8[0x4d, 0x4d, 0x00, 0x2a]) ||
           header[5:8] == codeunits("ftyp")
end

function media_response(bytes, content_type; filename = nothing)
    headers = [
        "Content-Type" => content_type,
        "Cache-Control" => "private, max-age=1800",
        "X-Content-Type-Options" => "nosniff",
    ]
    if !isnothing(filename)
        escaped = replace(filename, r"[\x00-\x1f\"\\]"=>"_")
        push!(
            headers,
            "Content-Disposition" => "attachment; filename=\"$escaped\"; filename*=UTF-8''$(HTTP.escapeuri(filename))",
        )
    end
    return HTTP.Response(200, headers, bytes)
end

function mutable_media_response(bytes, content_type)
    response = media_response(bytes, content_type)
    HTTP.setheader(response, "Cache-Control"=>"no-cache")
    return response
end

function media_range_response(ctx, response)
    HTTP.setheader(response, "Accept-Ranges"=>"bytes")
    requested = HTTP.header(ctx.req, "Range")
    isempty(requested) && return response
    match_range = match(r"^bytes=(\d*)-(\d*)$", requested)
    total = length(response.body)
    invalid() = HTTP.Response(416, ["Content-Range"=>"bytes */$total"], "")
    isnothing(match_range) && return invalid()
    firstbyte, lastbyte = match_range[1], match_range[2]
    isempty(firstbyte) && isempty(lastbyte) && return invalid()
    if isempty(firstbyte)
        suffix = tryparse(Int, lastbyte)
        (isnothing(suffix) || suffix <= 0) && return invalid()
        start, stop = max(0, total-suffix), total-1
    else
        start = tryparse(Int, firstbyte)
        stop = isempty(lastbyte) ? total-1 : tryparse(Int, lastbyte)
        (isnothing(start) || isnothing(stop)) && return invalid()
        stop = min(stop, total-1)
    end
    0 <= start <= stop < total || return invalid()
    response.status = 206
    HTTP.setheader(response, "Content-Range"=>"bytes $start-$stop/$total")
    response.body = response.body[(start+1):(stop+1)]
    return response
end

function avatar_variant(app, blob; logo = false)
    return lock(app.storage_lock) do
        return avatar_variant_locked(app, blob; logo)
    end
end

function avatar_variant_locked(app, blob; logo = false)
    # Reuse Rails' processed variant bytes when reading a reference fixture.
    variant = qone(
        app,
        """
SELECT b.* FROM active_storage_variant_records v
JOIN active_storage_attachments a ON a.record_type='ActiveStorage::VariantRecord' AND a.record_id=v.id
JOIN active_storage_blobs b ON b.id=a.blob_id WHERE v.blob_id=? ORDER BY v.id LIMIT 1
""",
        (blob.id,),
    )
    !isnothing(variant) &&
        isfile(blob_path(app, variant.key)) &&
        return (read_blob(app, variant), string(variant.content_type))
    source = blob_path(app, blob.key)
    isfile(source) || return nothing
    bitmap_file(source) || return nothing
    extension = logo ? ".png" : ".webp"
    destination = source * (logo ? "-logo" : "-avatar") * extension
    if !isfile(destination)
        # libvips bounds output dimensions and evaluates lazily; the filename is
        # generated by us, and Cmd interpolation does not invoke a shell.
        limit = logo ? "512" : "512"
        try
            width = parse(
                Int,
                strip(
                    read(
                        pipeline(
                            safe_vips(`vipsheader -f width $source`);
                            stderr = devnull,
                        ),
                        String,
                    ),
                ),
            )
            height = parse(
                Int,
                strip(
                    read(
                        pipeline(
                            safe_vips(`vipsheader -f height $source`);
                            stderr = devnull,
                        ),
                        String,
                    ),
                ),
            )
            0 < width <= 250_000_000 ÷ max(height, 1) && height > 0 || return nothing
            render_variant(destination) do temporary
                return run(
                    pipeline(
                        safe_vips(
                            `vips thumbnail $source $temporary $limit --height $limit --size down`,
                        );
                        stdout = devnull,
                        stderr = devnull,
                    ),
                )
            end
        catch
            return nothing
        end
    end
    return (read(destination), logo ? "image/png" : "image/webp")
end

function avatar_svg(name; bot = false)
    initials = bot ? "🤖" : join(first(word) for word in Iterators.take(split(name), 2))
    return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"128\" height=\"128\" viewBox=\"0 0 128 128\"><rect width=\"128\" height=\"128\" rx=\"20\" fill=\"#5d6378\"/><text x=\"64\" y=\"70\" dominant-baseline=\"middle\" text-anchor=\"middle\" fill=\"white\" font-family=\"sans-serif\" font-size=\"48\">$(media_escape(uppercase(initials)))</text></svg>"
end

function route_media(ctx)
    avatar = match(r"^/users/([^/]+)/avatar$", ctx.path)
    if !isnothing(avatar)
        if ctx.method == "DELETE"
            isnothing(ctx.user) && return redirect("/session/new")
            keys = detach_attachments!(ctx.app, "User", ctx.user.id; name = "avatar")
            isempty(keys) || push!(ctx.events, Event(:purge_storage, 0, keys))
            return redirect("/users/me/profile")
        elseif ctx.method != "GET"
            return html_response("Method not allowed"; status = 405)
        end
        token = HTTP.unescapeuri(avatar[1])
        id = verify_token(ctx.app, "avatar", token)
        isnothing(id) && (id = verify_rails_signed_id(ctx.app, "avatar", token))
        if isnothing(id) && !isnothing(ctx.user)
            id = token == "me" ? ctx.user.id : tryparse(Int64, token)
        end
        isnothing(id) && return html_response("Not found"; status = 404)
        user = qone(ctx.app, "SELECT id,name,role FROM users WHERE id=?", (id,))
        isnothing(user) && return html_response("Not found"; status = 404)
        blob = attachment_blob(ctx.app, "User", user.id, "avatar")
        if !isnothing(blob)
            image = avatar_variant(ctx.app, blob)
            isnothing(image) || return mutable_media_response(image...)
        end
        return mutable_media_response(
            avatar_svg(user.name; bot = user.role == 2),
            "image/svg+xml",
        )
    elseif ctx.path == "/account/logo"
        if ctx.method == "DELETE"
            (isnothing(ctx.user) || ctx.user.role != 1) &&
                return html_response("Forbidden"; status = 403)
            keys = detach_attachments!(ctx.app, "Account", ctx.account.id; name = "logo")
            isempty(keys) || push!(ctx.events, Event(:purge_storage, 0, keys))
            return redirect("/account/edit")
        elseif ctx.method == "GET"
            blob =
                isnothing(ctx.account) ? nothing :
                attachment_blob(ctx.app, "Account", ctx.account.id, "logo")
            if !isnothing(blob)
                image = avatar_variant(ctx.app, blob; logo = true)
                isnothing(image) || return mutable_media_response(image...)
            end
            asset = normpath(
                joinpath(
                    @__DIR__,
                    "../../../app/assets/images/logos",
                    param(ctx, "size", "") == "small" ? "app-icon-192.png" : "app-icon.png",
                ),
            )
            return mutable_media_response(read(asset), "image/png")
        end
    end
    preview = match(
        r"^/rails/active_storage/representations/(?:redirect|proxy)/([^/]+)/thumbnail/[^/]+$",
        ctx.path,
    )
    if !isnothing(preview)
        ctx.method == "GET" || return html_response("Method not allowed"; status = 405)
        id = verify_token(ctx.app, "blob", HTTP.unescapeuri(preview[1]))
        isnothing(id) && return html_response("Not found"; status = 404)
        blob = qone(ctx.app, "SELECT * FROM active_storage_blobs WHERE id=?", (id,))
        isnothing(blob) && return html_response("Not found"; status = 404)
        return lock(ctx.app.storage_lock) do
            path = attachment_preview(ctx.app, blob)
            isnothing(path) && return html_response("Not found"; status = 404)
            return media_response(read(path), "image/webp")
        end
    end
    route =
        match(r"^/rails/active_storage/blobs/(?:redirect|proxy)/([^/]+)/[^/]+$", ctx.path)
    isnothing(route) && return nothing
    ctx.method == "GET" || return html_response("Method not allowed"; status = 405)
    id = verify_token(ctx.app, "blob", HTTP.unescapeuri(route[1]))
    isnothing(id) && return html_response("Not found"; status = 404)
    blob = qone(ctx.app, "SELECT * FROM active_storage_blobs WHERE id=?", (id,))
    (isnothing(blob) || !isfile(blob_path(ctx.app, blob.key))) &&
        return html_response("Not found"; status = 404)
    # Signed URLs are capability URLs, as in Active Storage. User-controlled
    # HTML/SVG always downloads instead of executing in the site's origin.
    content_type = string(coalesce(blob.content_type, "application/octet-stream"))
    inline = content_type in (
        "image/png",
        "image/jpeg",
        "image/webp",
        "image/gif",
        "audio/mpeg",
        "audio/ogg",
        "video/mp4",
        "video/webm",
    )
    response = media_response(
        read_blob(ctx.app, blob),
        content_type;
        filename = inline ? nothing : blob.filename,
    )
    return media_range_response(ctx, response)
end
