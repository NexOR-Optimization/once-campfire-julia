# Rails' HTML contract translated into Julia. Browser interactions remain owned
# by Campfire's existing Stimulus controllers, Turbo, and Lexxy.
function value(row, key::Symbol, default = "")
    row === nothing && return default
    result =
        row isa AbstractDict ? get(row, key, get(row, String(key), default)) :
        hasproperty(row, key) ? getproperty(row, key) : default
    return result === nothing || result === missing ? default : result
end

function h(input)
    return replace(
        string(input),
        '&' => "&amp;",
        '<' => "&lt;",
        '>' => "&gt;",
        '"' => "&quot;",
        '\'' => "&#39;",
    )
end

icon(
    name;
    size = 20,
) = "<img src=\"/assets/$(h(name)).svg\" width=\"$size\" height=\"$size\" aria-hidden=\"true\" class=\"colorize--black\">"
screen(text) = "<span class=\"for-screen-reader\">$(h(text))</span>"

function button(label; image = "check", attributes = "")
    return "<button type=\"submit\" class=\"btn btn--reversed center\" $attributes>$(icon(image))$(screen(label))</button>"
end

function input(
    name,
    label;
    val = "",
    type = "text",
    required = false,
    placeholder = label,
    attributes = "",
)
    return """<label class="flex align-center gap flex-item-grow input input--actor">
    <span class="for-screen-reader">$(h(label))</span>
    <input class="input full-width" name="$(h(name))" aria-label="$(h(label))" type="$(h(type))" value="$(h(val))" placeholder="$(h(placeholder))" $(required ? "required" : "") $attributes></label>"""
end

function form_open(ctx, url; method = "post", attributes = "", csrf = true)
    override =
        lowercase(method) in ("get", "post") ? "" :
        "<input type=\"hidden\" name=\"_method\" value=\"$(h(method))\">"
    token =
        csrf && lowercase(method) != "get" ?
        "<input type=\"hidden\" name=\"authenticity_token\" value=\"$(h(ctx.csrf))\">" : ""
    return """<form action="$(h(url))" method="$(lowercase(method) == "get" ? "get" : "post")" $attributes>$token$override"""
end

function avatar_url(ctx, id, token = nothing)
    token === nothing && (token = signed_token(ctx.app, "avatar", string(id)))
    return "/users/$(h(token))/avatar"
end

function stream_source(ctx, stream; channel = "Turbo::StreamsChannel", room_id = nothing)
    token = signed_token(ctx.app, "stream", stream)
    room = room_id === nothing ? "" : " data-room-id=\"$(h(room_id))\""
    return "<turbo-cable-stream-source channel=\"$channel\" signed-stream-name=\"$(h(token))\"$room></turbo-cable-stream-source>"
end

function layout(
    ctx,
    content;
    title = "Campfire",
    nav = "",
    footer = "",
    sidebar = "",
    room = nothing,
    body_class = "",
    head = "",
)
    user_meta =
        ctx.user === nothing ? "" :
        """
  <meta name="current-user-id" content="$(ctx.user.id)">
  <meta name="current-user-name" content="$(h(ctx.user.name))">
  <meta name="current-user-sgid" content="$(h(signed_token(ctx.app,"mention",string(ctx.user.id))))">
"""
    room_meta =
        room === nothing ? "" :
        "<meta name=\"current-room-id\" content=\"$(value(room, :id))\">"
    styles =
        replace(string(value(ctx.account, :custom_styles)), r"(?i)</style" => "<\\/style")
    isempty(nav) && (
        nav = "<a class=\"btn\" href=\"/\">$(icon("arrow-left"))$(screen("Back to chat"))</a>"
    )
    return """<!DOCTYPE html><html><head><meta charset="utf-8"><title>$(h(title)) — Campfire</title>
      <meta name="viewport" content="width=device-width, initial-scale=1, interactive-widget=resizes-content">
      <meta name="color-scheme" content="light dark"><meta name="csrf-param" content="authenticity_token">
      <meta name="csrf-token" content="$(h(ctx.csrf))"><meta name="action-cable-url" content="/cable">
      <meta name="vapid-public-key" content="$(h(value(ctx.app,:vapid_public_key)))">
      <meta name="turbo-prefetch" content="false">$user_meta$room_meta
      <link rel="icon" href="/assets/campfire-icon.png"><link rel="manifest" href="/webmanifest.json">$STYLESHEET_TAGS
      <style id="custom_styles">$styles</style>
      <script type="importmap" data-turbo-track="reload">$BROWSER_IMPORTMAP</script>
      <script type="module">import "application"</script>$head
    </head><body class="$(h(body_class))" data-controller="local-time lightbox">
      <a href="#main-content" class="skip-navigation btn">Skip to main content</a><nav id="nav">$nav</nav>
      <main id="main-content">$content<footer id="footer">$footer</footer></main>
      <aside id="sidebar" data-controller="toggle-class" data-toggle-class-toggle-class="open">$sidebar</aside>
      <dialog class="lightbox" aria-label="Image Viewer (Press escape to close)" data-lightbox-target="dialog" data-action="close->lightbox#reset">
        <img class="lightbox__image" data-lightbox-target="zoomedImage">
        <form method="dialog" class="lightbox__btn"><button class="btn">$(icon("remove"))$(screen("Close image viewer"))</button></form>
        <a class="lightbox__btn--download btn" data-lightbox-target="download">$(icon("download"))$(screen("Download file"))</a>
        <button class="lightbox__btn--share btn" data-controller="web-share" data-action="web-share#share" data-web-share-files-value="" data-lightbox-target="share">$(icon("share"))$(screen("Share file"))</button>
      </dialog><a href="https://once.com" id="app-logo" aria-label="Once software from 37signals home page"><img src="/assets/campfire-icon.png" alt="Campfire logo" width="256" height="216"></a>
    </body></html>"""
end

function sidebar_frame(; src = false, content = "")
    source = src ? " src=\"/users/me/sidebar\"" : ""
    return """<turbo-frame id="user_sidebar" target="_top"$source data-turbo-permanent
      data-controller="rooms-list read-rooms turbo-frame" data-rooms-list-unread-class="unread"
      data-action="presence:present@window->rooms-list#read read-rooms:read->rooms-list#read turbo:frame-load->rooms-list#loaded refresh-room:visible@window->turbo-frame#reload">$content</turbo-frame>"""
end

function sidebar_room_html(ctx, room)
    id = value(room, :id)
    name = value(room, :display_name, value(room, :name))
    direct = value(room, :type) == "Rooms::Direct"
    class = direct ? "direct" : "room btn align-center gap"
    ordering =
        direct ?
        "data-sorted-list-number=\"$(timestamp_ms(value(room,:updated_at,nowstr())))\"" :
        "data-sorted-list-name=\"$(h(name))\""
    return """<a id="room_$id" href="/rooms/$id" class="$class" data-rooms-list-target="room" data-room-id="$id" data-badge-dot-target="unread" data-sorted-list-target="item" $ordering>$(h(name))</a>"""
end

function sidebar_html(ctx; rooms = nothing)
    if rooms === nothing
        rooms = qrows(
            ctx.app,
            """SELECT r.* FROM rooms r JOIN memberships m ON m.room_id=r.id
WHERE m.user_id=? AND m.involvement != 'invisible' ORDER BY lower(r.name),r.id""",
            (ctx.user.id,),
        )
    end
    shared =
        join(sidebar_room_html(ctx, r) for r in rooms if value(r, :type) != "Rooms::Direct")
    directs =
        join(sidebar_room_html(ctx, r) for r in rooms if value(r, :type) == "Rooms::Direct")
    content = """$(stream_source(ctx, "rooms"))$(stream_source(ctx, "user:$(ctx.user.id):rooms"))
      <div class="sidebar__container overflow-y overflow-hide-scrollbar" data-controller="badge-dot" data-badge-dot-unread-class="unread"
        data-action="rooms-list:unread@window->badge-dot#update rooms-list:read@window->badge-dot#update turbo:submit-start->turbo-frame#unpermanize">
      <turbo-frame id="direct_rooms_control" target="_top"><div class="directs gap overflow-x overflow-hide-scrollbar">
        <a href="/rooms/directs/new" class="direct direct__new" data-turbo-frame="_self"><span class="avatar avatar--icon">$(icon("messages-add"))</span><span class="direct__author flex max-width min-width border-radius pad-inline-half">New Ping</span></a>
        <div id="direct_rooms" contents data-controller="sorted-list" data-action="rooms-list:unread@window->sorted-list#updateItem">$directs</div>
      </div></turbo-frame><div class="rooms position-relative flex flex-column gap">
        <div id="shared_rooms" contents data-controller="sorted-list">$shared</div>
        <a href="/rooms/opens/new" class="rooms__new-btn btn room align-center gap txt-reversed" aria-label="New Chat Room">$(icon("add"))</a>
      </div><button class="btn sidebar__toggle" data-action="toggle-class#toggle">$(icon("menu"))$(screen("Open menu"))</button></div>
      <div class="flex align-end sidebar__tools gap justify-end">
        <a href="/users/me/profile" class="btn avatar sidebar__tool"><img src="$(avatar_url(ctx,ctx.user.id))" alt="">$(screen("My Settings"))</a>
        <a href="/account/edit" class="btn sidebar__tool">$(icon("settings"))$(screen("Account Settings"))</a>
      </div>"""
    return sidebar_frame(; content)
end

function editor_html(
    room_id;
    id = "message_body",
    label = "Write a message",
    body = "",
    composer = true,
)
    actions =
        composer ?
        "lexxy:change->composer#saveDraft lexxy:change->typing-notifications#start keydown->composer#submitByKeyboard:capture" :
        ""
    target = composer ? " data-composer-target=\"text\"" : ""
    return """<lexxy-editor id="$(h(id))" name="message[body]" class="input lexxy-content" aria-label="$(h(label))" aria-multiline="true" value="$(h(body))"
      permitted-attachment-types="application/vnd.campfire.mention application/vnd.actiontext.opengraph-embed" data-action="$actions"$target>
      <lexxy-prompt trigger="@" name="mention" src="/autocompletable/users?room_id=$room_id" remote-filtering="true" empty-results="No matches"></lexxy-prompt>
    </lexxy-editor>"""
end

function composer_html(ctx, room)
    id = value(room, :id)
    return """<div class="composer flex align-end gap position-relative" data-controller="typing-notifications" data-typing-notifications-active-class="typing-indicator--active">
      <a href="/searches" class="btn flex-item-no-shrink margin-block-end composer__context-btn">$(icon("search"))$(screen("Search"))</a>
      <turbo-frame id="composer-frame">
      $(form_open(ctx, "/rooms/$id/messages"; attributes="id=\"composer\" class=\"margin-block flex-item-grow contain\" data-controller=\"composer drop-target\" data-composer-messages-outlet=\"#message-area\" data-composer-toolbar-class=\"composer--rich-text\" data-composer-room-id-value=\"$id\" data-action=\"lexxy:file-accept->composer#preventAttachment refresh-room:online@window->composer#online refresh-room:offline@window->composer#offline turbo:submit-end->composer#submitEnd paste->composer#pasteFiles\""))
      <fieldset data-composer-target="fields" contents><div class="flex flex-column">
        <div class="composer__filelist flex align-center gap flex-wrap" data-composer-target="fileList"></div>
        <div class="flex composer__input input input--actor fill-white min-width" style="--input-border-radius:1.3rem"><div class="flex align-end gap full-width">
        $(icon("messages-outlined"))<div class="flex flex-column flex-item-grow min-width gap">$(editor_html(id))</div>
        <label class="btn btn--borderless txt-small flex-item-no-shrink input--file">$(icon("attachment"))<input type="file" multiple data-action="composer#filePicked">$(screen("Attach a file"))</label>
        <button class="btn btn--borderless txt-small flex-item-no-shrink" type="button" data-action="composer#toggleToolbar">$(icon("text-options"))$(screen("Rich text"))</button>
        $(button("Send Message"; image="arrow-up", attributes="data-action=\"composer#submit\""))
      </div></div></div></fieldset><div class="typing-indicator gap txt-small align-center flex-inline" data-typing-notifications-target="indicator"><div class="typing-indicator__author spinner" data-typing-notifications-target="author"></div></div>
      <input type="hidden" name="message[client_message_id]" data-composer-target="clientid"></form></turbo-frame></div>"""
end

function message_template(ctx)
    return """<script type="text/template" data-messages-target="template">
      <div class="message message--me \$messageClasses\$" id="message_\$clientMessageId\$" data-pending-message="true" data-client-message-id="\$clientMessageId\$" data-user-id="$(ctx.user.id)" data-message-timestamp="\$messageTimestamp\$" data-messages-target="message">
      <div class="message__day-separator"><time datetime="\$messageDatetime\$" data-local-time-target="date"></time></div>
      <figure class="avatar message__avatar"><img src="$(avatar_url(ctx,ctx.user.id))" alt=""></figure>
      <div class="message__body"><div class="message__body-content"><div class="message__meta"><h3 class="message__heading"><span class="message__author"><strong>$(h(ctx.user.name))</strong></span><time class="message__timestamp" datetime="\$messageDatetime\$" data-local-time-target="time"></time></h3></div>\$body\$</div></div></div></script>"""
end

function timestamp_ms(date)
    date isa Number && return round(Int64, date)
    normalized = replace(string(date), ' ' => 'T', "Z" => "")
    normalized = replace(normalized, r"(\.\d{3})\d+" => s"\1")
    parsed = tryparse(DateTime, normalized)
    return parsed === nothing ? 0 : round(Int64, Dates.datetime2unix(parsed) * 1000)
end

function boost_html(ctx, boost, message_id)
    id = value(boost, :id)
    return """<div id="boost_$id" class="boost boost-item flex-inline max-width align-center fill-white gap" data-controller="boost-delete" data-boost-delete-perform-class="boost--deleting" data-boost-delete-reveal-class="expanded" data-boost-delete-booster-id-value="$(value(boost,:booster_id,0))">
      <span title="$(h(value(boost, :author)))" role="button" data-action="click->boost-delete#reveal keydown.enter->boost-delete#reveal:prevent" data-boost-delete-target="content">$(h(value(boost, :content)))</span>
      $(form_open(ctx, "/messages/$message_id/boosts/$id"; method="delete", csrf=false,attributes="data-action=\"boost-delete#perform turbo:submit-start->boost-delete#perform:stop\""))<button class="btn btn--negative boost__delete" data-boost-delete-target="button">$(screen("Delete this boost"))$(icon("minus"))</button></form></div>"""
end

# The controller lives on the message so quick-boost forms and inline forms
# share one streaming target. Unsubscribe while the redirect renders the frame.
function boosts_html(ctx, message)
    id = value(message, :id)
    boosts = join(boost_html(ctx, b, id) for b in value(message, :boosts, []))
    return """<turbo-frame id="boosting_message_$id"><div class="boosts flex flex-wrap align-center gap full-width" data-action="turbo:submit-start->turbo-streaming#unsubscribe">
      <div id="boosts_message_$id" class="flex-inline flex-wrap gap" data-turbo-streaming-target="container">$boosts</div><turbo-frame id="new_boost_message_$id"></turbo-frame>
      </div></turbo-frame><span id="delete_boost_accessible_label" class="for-screen-reader">Press enter to delete this boost</span>"""
end

function message_html(ctx, row)
    id = value(row, :id)
    room = value(row, :room_id)
    author_id = value(row, :creator_id)
    author = value(row, :author)
    created = string(value(row, :created_at, nowstr()))
    datetime = replace(created, ' ' => 'T') * (endswith(created, "Z") ? "" : "Z")
    permalink = ctx.base_url * "/rooms/$room/@$id"
    body = string(value(row, :body))
    sound = value(row, :sound, nothing)
    if sound !== nothing
        image_url = value(sound, :image_url, nothing)
        presentation =
            image_url === nothing ? h(value(sound, :text)) :
            "<img src=\"$(h(image_url))\" width=\"$(h(value(sound,:width)))\" height=\"$(h(value(sound,:height)))\" alt=\"$(h(value(sound,:name)))\" class=\"align--middle\">"
        body = "<div class=\"sound\" data-controller=\"sound\" data-action=\"messages:play->sound#play\" data-sound-url-value=\"$(h(value(sound,:url)))\"><button class=\"btn btn--plain\" type=\"button\" data-action=\"sound#play\" aria-label=\"Play $(h(value(sound,:name)))\">🔊</button>$presentation</div>"
    end
    attachment = value(row, :attachment, nothing)
    if attachment !== nothing
        url = h(value(attachment, :url))
        filename = h(value(attachment, :filename))
        content_type = string(value(attachment, :content_type))
        preview = value(attachment, :preview_url, nothing)
        if startswith(content_type, "image/") && preview !== nothing
            body = "<a href=\"$(h(preview))\" data-action=\"lightbox#open\" data-lightbox-url-value=\"$url\"><img src=\"$(h(preview))\" alt=\"$filename\" class=\"message__attachment\"></a>"
        elseif startswith(content_type, "video/") && preview !== nothing
            body = "<video controls preload=\"metadata\" src=\"$url\" poster=\"$(h(preview))\" aria-label=\"$filename\"></video>"
        elseif startswith(content_type, "audio/")
            body = "<audio controls preload=\"metadata\" src=\"$url\" aria-label=\"$filename\"></audio>"
        else
            body = "<a href=\"$url\" download=\"$filename\">$filename</a>"
        end
    end
    return """<div id="message_$id" class="message" data-controller="reply turbo-streaming" data-user-id="$author_id" data-message-id="$id" data-client-message-id="$(h(value(row, :client_message_id)))"
      data-message-timestamp="$(timestamp_ms(created))" data-message-updated-at="$(timestamp_ms(value(row, :updated_at, created)))" data-sort-value="$(timestamp_ms(created))"
      data-messages-target="message" data-search-results-target="message" data-refresh-room-target="message" data-reply-composer-outlet="#composer">
      <h2 class="message__day-separator"><time datetime="$(h(datetime))" data-local-time-target="date"></time></h2>
      <figure class="avatar message__avatar"><img src="$(avatar_url(ctx,author_id,value(row,:avatar_token,nothing)))" alt="$(h(author))"></figure>
      <turbo-frame id="edit_message_$id"><div class="message__body"><div class="message__body-content">
      <div class="message__meta"><h3 class="message__heading"><span class="message__author"><strong data-reply-target="author">$(h(author))</strong></span>
      <a class="message__permalink" href="/rooms/$room/@$id" target="_top"><time class="message__timestamp" datetime="$(h(datetime))" data-local-time-target="time"></time></a>
      <span class="message__room"><a href="/rooms/$room/@$id" target="_top" data-reply-target="link">$(h(value(row, :room_name)))</a></span></h3>
      <div class="message__actions"><details class="position-relative" data-controller="popup" data-action="keydown.esc->popup#close toggle->popup#toggle click@document->popup#closeOnClickOutside" data-popup-orientation-top-class="popup-orientation-top">
        <summary class="btn message__action-btn message__options-btn">$(icon("menu-dots-horizontal"))$(screen("Message options"))</summary>
        <div class="message__actions-menu border shadow" data-popup-target="menu"><div class="quick-boosts">
        $(join(form_open(ctx,"/messages/$id/boosts"; csrf=false, attributes="data-turbo-frame=\"boosting_message_$id\" data-action=\"popup#close turbo:submit-start->turbo-streaming#unsubscribe\"") * "<input type=\"hidden\" name=\"boost[content]\" value=\"$emoji\"><button class=\"btn message__action-btn\" title=\"$title\" aria-label=\"$title\">$emoji</button></form>" for (emoji,title) in (("👍","Thumbs up"),("❤️","Heart"),("😂","Laugh"))))
        <a href="/messages/$id/boosts/new" data-turbo-frame="new_boost_message_$id" class="btn message__action-btn">$(icon("boost"))$(screen("New boost"))</a></div>
        <div class="flex flex-wrap border-top margin-block-start-half pad-block-start-half message__actions-grid">
        <button class="btn message__action-btn" type="button" data-action="reply#reply" aria-label="Reply">$(icon("reply"))</button>
        <button class="btn message__action-btn" type="button" aria-label="Copy link" data-controller="copy-to-clipboard" data-action="copy-to-clipboard#copy" data-copy-to-clipboard-success-class="btn--success" data-copy-to-clipboard-content-value="$(h(permalink))">$(icon("link"))</button>
        <a href="/rooms/$room/messages/$id/edit" class="btn message__action-btn message__edit-btn" data-turbo-frame="edit_message_$id" aria-label="Edit">$(icon("pencil"))</a></div></div>
      </details></div></div>
      <div id="presentation_message_$id" dir="auto" data-reply-target="body" data-messages-target="body"><div class="lexxy-content">$body</div></div>
      $(boosts_html(ctx, row))
      </div></div></turbo-frame></div>"""
end

function edit_message_html(ctx, row)
    id, room = value(row, :id), value(row, :room_id)
    editable, _ = sanitize_rich_text(
        value(row, :editable_body, value(row, :body));
        ctx,
        storage = true,
    )
    return """<turbo-frame id="edit_message_$id"><div class="message__body position-relative"><div class="message__body-content message__body-content--editing gap"><div class="composer--edit composer--rich-text">
      $(form_open(ctx,"/rooms/$room/messages/$id"; method="patch", attributes="data-controller=\"form\" data-action=\"keydown.esc->form#cancel keydown.ctrl+enter->form#submit:prevent keydown.meta+enter->form#submit:prevent\""))
      $(editor_html(room; id="edit_message_$(id)_body", label="Edit message", body=editable, composer=false))
      <a href="/rooms/$room/messages/$id" hidden data-form-target="cancel">Close editor and discard changes</a>
      <div class="message__edit-btns flex align-center gap">$(button("Save changes"))<a href="/rooms/$room/messages/$id" class="btn">Cancel changes</a></div></form>
      $(form_open(ctx,"/rooms/$room/messages/$id";method="delete"))<button class="btn btn--negative">$(icon("trash"))$(screen("Delete message"))</button></form>
      </div></div></div></turbo-frame>"""
end

message_edit_html(ctx, row) = edit_message_html(ctx, row)

function notifications_html(ctx, room)
    id = value(room, :id)
    return """<span class="button_to_change_notifying" data-controller="notifications" data-notifications-subscriptions-url-value="/users/me/push_subscriptions" data-notifications-attention-class="btn--pulsing">
      <turbo-frame id="involvement_room_$id" data-controller="turbo-frame" data-action="notifications:ready@window->turbo-frame#load" data-turbo-frame-url-param="/rooms/$id/involvement">
        <button class="btn" data-action="click->notifications#attemptToSubscribe" data-notifications-target="bell">$(icon("notification-bell-loading"))<img src="/assets/notification-bell-alert.svg" width="20" height="20" aria-hidden="true" hidden>$(screen("Notification settings for this room"))</button>
      </turbo-frame><dialog data-notifications-target="notAllowedNotice" class="dialog pad center border-radius border shadow"><h1 class="txt-large">Notifications aren’t allowed</h1>
        <details class="notifications-help" data-notifications-target="details"><summary class="btn">Check your browser settings</summary><p>Allow notifications for $(h(ctx.base_url)) in your browser’s site settings.</p></details>
        <details class="notifications-help" data-notifications-target="details"><summary class="btn">Check your system settings</summary><p>Allow notifications for Campfire and your browser in your device’s notification settings.</p></details>
        <details class="notifications-help pwa__instructions hide-in-pwa" data-controller="pwa-install" data-pwa-install-prompting-class="pwa--can-install" data-notifications-target="details"><summary class="btn">Install Campfire as a web app</summary><p>Use your browser’s Install app or Add to Home Screen command. On iOS, open Campfire from its Home Screen icon to enable notifications.</p><div class="pwa__installer"><button class="btn" data-action="pwa-install#promptInstall">Install now</button></div></details>
        <form method="dialog"><button class="btn">$(icon("remove"))$(screen("Close"))</button></form></dialog></span>"""
end

function room_page_html(ctx, room, messages)
    id = value(room, :id)
    name = value(room, :display_name, value(room, :name))
    direct = value(room, :type) == "Rooms::Direct"
    heading = direct && !startswith(name, "Ping with ") ? "Ping with $name" : name
    nav = """<span class="btn btn--reversed btn--faux room--current"><h1 class="room__contents txt-medium overflow-ellipsis">$(h(heading))</h1></span>
      <a href="/rooms/$(direct ? "directs" : value(room,:type)=="Rooms::Closed" ? "closeds" : "opens")/$id/edit" class="btn" aria-label="Settings for this room">$(icon("menu-dots-horizontal"))</a>$(notifications_html(ctx,room))"""
    content = """<div id="message-area" class="message-area" contents data-controller="messages presence drop-target"
      data-action="turbo:before-stream-render@document->messages#beforeStreamRender keydown.up@document->messages#editMyLastMessage visibilitychange@document->presence#visibilityChanged"
      data-messages-first-of-day-class="message--first-of-day" data-messages-formatted-class="message--formatted" data-messages-me-class="message--me" data-messages-mentioned-class="message--mentioned" data-messages-threaded-class="message--threaded" data-messages-page-url-value="/rooms/$id/messages">
      $(message_template(ctx))<div id="messages_room_$id" class="messages" data-controller="maintain-scroll refresh-room" data-action="turbo:before-stream-render@document->maintain-scroll#beforeStreamRender visibilitychange@document->refresh-room#visibilityChanged online@window->refresh-room#online" data-messages-target="messages" data-refresh-room-loaded-at-value="$(timestamp_ms(value(room,:updated_at,nowstr())))" data-refresh-room-url-value="/rooms/$id/refresh">
      $(join(message_html(ctx,m) for m in messages))</div>
      $(stream_source(ctx,"room:$id:messages";channel="RoomMessagesChannel",room_id=id))
      <button class="message-area__return-to-latest btn" data-action="messages#returnToLatest" data-messages-target="latest" hidden>$(icon("arrow-down"))$(screen("Jump to newest message"))</button></div>"""
    return layout(
        ctx,
        content;
        title = name,
        nav,
        footer = composer_html(ctx, room),
        sidebar = sidebar_frame(; src = true),
        room,
        body_class = "sidebar",
        head = "<meta name=\"turbo-cache-control\" content=\"no-preview\">",
    )
end

function search_page_html(ctx, rows, query)
    content = """<div id="message-area" class="message-area"><div id="search-results" class="messages" data-controller="search-results" data-search-results-me-class="message--me" data-search-results-threaded-class="message--threaded" data-search-results-mentioned-class="message--mentioned" data-search-results-formatted-class="message--formatted">$(join(message_html(ctx,m) for m in rows))</div></div>"""
    footer = """<div class="composer flex align-center gap"><a href="/" class="btn">$(icon("arrow-left"))$(screen("Exit search"))</a>$(form_open(ctx,"/searches";attributes="class=\"margin-block flex-item-grow contain flex gap\""))$(input("q","search";val=query,type="search"))$(button("Search";image="search"))</form></div>"""
    recent = qrows(
        ctx.app,
        "SELECT query FROM searches WHERE user_id=? ORDER BY updated_at DESC,id DESC LIMIT 10",
        (ctx.user.id,),
    )
    sidebar = join(
        "<a href=\"/searches?q=$(HTTP.escapeuri(value(row,:query)))\" class=\"room btn\">$(h(value(row,:query)))</a>"
        for row in recent
    )
    isempty(recent) ||
        (sidebar *= delete_form(ctx, "/searches/clear", "Clear recent searches"))
    return layout(
        ctx,
        content;
        title = "Search",
        nav = "<h1>Search: $(h(query))</h1>",
        footer,
        sidebar,
        body_class = "sidebar searches",
    )
end

function direct_form_html(ctx)
    return """<turbo-frame id="direct_rooms_control" target="_top"><div class="directs directs--new flex flex-column gap">
      $(form_open(ctx,"/rooms/directs";attributes="class=\"flex gap flex-item-grow\" data-controller=\"form\" data-action=\"keydown.esc->form#cancel\""))
      <a href="/users/me/sidebar" class="btn flex-item-no-shrink" data-turbo-frame="user_sidebar" data-form-target="cancel">$(icon("arrow-left"))$(screen("Cancel changes"))</a>
      <section class="autocomplete__container unpad input input--actor"><div class="autocomplete__input input flex flex-wrap position-relative flex-item-grow" data-controller="autocomplete" data-autocomplete-url-value="/autocompletable/users">
      <select name="user_ids[]" data-autocomplete-target="select" data-template-id="autocompletable-user" multiple hidden required></select>
      <template id="autocompletable-user"><div class="autocomplete__pill max-width" data-value="" tabindex="0"><img class="avatar flex-item-no-shrink" data-content="avatar"><span class="autocomplete-field__selected-value-text overflow-ellipsis flex-item-grow" data-content="label"></span><button type="button" data-action="autocomplete#remove:prevent" data-value="" tabindex="-1" class="btn btn--plain txt-small translucent flex-item-no-shrink">$(icon("remove-circle"))<span class="for-screen-reader">Remove <span data-content="screenReaderLabel"></span></span></button></div></template>
      <input name="room[user_ids_input]" autocomplete="off" autocorrect="off" class="autocomplete__input input" data-autocomplete-target="input" data-action="input->autocomplete#search keydown->autocomplete#didPressKey"></div></section>
      $(button("Start Ping"))</form><span class="txt-small translucent center">Type names to ping someone…</span></div></turbo-frame>"""
end

function upload_field(name, label; url = "/assets/default-avatar.svg")
    return """<div class="align-center center avatar__form gap" data-controller="upload-preview">
      <img src="$(h(url))" width="96" height="96" class="avatar" alt="$(h(label))" data-upload-preview-target="image">
      <label class="btn input--file">$(icon("camera"))<input type="file" name="$(h(name))" accept="image/*" aria-label="$(h(label))" data-upload-preview-target="input" data-action="upload-preview#previewImage">$(screen(label))</label></div>"""
end

function delete_form(ctx, url, label; confirm = "")
    attributes = isempty(confirm) ? "" : "data-turbo-confirm=\"$(h(confirm))\""
    return form_open(ctx, url; method = "delete", attributes) *
           "<button class=\"btn btn--negative\" type=\"submit\">$(icon("trash"))$(screen(label))</button></form>"
end

function profile_page_html(
    ctx,
    user;
    editing = false,
    transfer = "",
    qr = "",
    memberships = [],
)
    id = value(user, :id)
    own = id == value(ctx.user, :id)
    admin = value(ctx.user, :role, -1) == 1
    title = value(user, :name, "Profile")
    content = "<section class=\"panel flex flex-column gap\">"
    if editing && own
        content *=
            form_open(
                ctx,
                "/users/me/profile";
                method = "patch",
                attributes = "enctype=\"multipart/form-data\" class=\"flex flex-column gap\"",
            ) *
            upload_field("user[avatar]", "Upload avatar"; url = avatar_url(ctx, id)) *
            button("Upload avatar"; image = "camera") *
            "</form>" *
            delete_form(ctx, "/users/me/avatar", "Delete avatar")
        content *= """$(form_open(ctx,"/users/me/profile";method="patch",attributes="class=\"flex flex-column gap\""))
          $(input("user[name]","Name";val=title,required=true))$(input("user[email_address]","Email address";val=value(user,:email_address),type="email"))
          $(input("user[password]","Change password";type="password",attributes="autocomplete=\"new-password\" maxlength=\"72\""))
          <label class="input input--actor"><span class="for-screen-reader">Bio</span><textarea class="input full-width" name="user[bio]" rows="3" maxlength="200" placeholder="A few words about yourself…">$(h(value(user,:bio)))</textarea></label>$(button("Save changes"))</form>"""
        for room in memberships
            content *= "<div class=\"flex align-center gap\"><a href=\"/rooms/$(value(room,:id))\">$(h(value(room,:name)))</a>$(view(ctx,:involvement;room,involvement=value(room,:involvement,"mentions")))</div>"
        end
        content *= "<a href=\"/users/me/push_subscriptions\">Notification subscriptions</a>"
    else
        content *= "<img class=\"avatar center\" src=\"$(avatar_url(ctx,id))\" alt=\"Profile avatar\"><h1>$(h(title))</h1><p>$(h(value(user,:bio)))</p>"
        admin && (
            content *= "<a href=\"mailto:$(h(value(user,:email_address)))\">$(h(value(user,:email_address)))</a>"
        )
        if value(user, :status, 0) == 0
            content *=
                form_open(ctx, "/rooms/directs") *
                "<input type=\"hidden\" name=\"user_ids[]\" value=\"$id\">" *
                button("Ping $title"; image = "messages") *
                "</form>"
        else
            content *= "<p>$(h(title)) is no longer active on this account.</p>"
        end
        own &&
            (content *= "<a href=\"/users/me/profile\" class=\"btn\">Edit my profile</a>")
    end
    if !isempty(transfer)
        content *= """<fieldset class="flex flex-column gap"><legend>Sign in on another device</legend><input type="text" class="input" id="session_transfer_url" value="$(h(transfer))" readonly><div class="flex align-center gap"><a class="btn" href="$(h(qr))" aria-label="Show auto-login QR code">$(icon("qr-code"))</a><button type="button" class="btn" data-controller="copy-to-clipboard" data-action="copy-to-clipboard#copy" data-copy-to-clipboard-success-class="btn--success" data-copy-to-clipboard-content-value="$(h(transfer))">$(icon("copy-paste"))$(screen("Copy auto-login link"))</button></div></fieldset>"""
    end
    if admin && !own
        banned = value(user, :status, 0) == 2
        content *=
            form_open(ctx, "/users/$id/ban"; method = banned ? "delete" : "post") *
            button(banned ? "Unban $title" : "Ban $title"; image = "cancel") *
            "</form>"
    end
    content *= "</section>"
    nav = "<a href=\"/\" class=\"btn\">$(icon("arrow-left"))$(screen("Back to chat"))</a>"
    if own
        nav *=
            form_open(
                ctx,
                "/session";
                method = "delete",
                attributes = "data-controller=\"sessions\"",
            ) *
            "<input type=\"hidden\" name=\"push_subscription_endpoint\" data-sessions-target=\"pushSubscriptionEndpoint\"><button type=\"submit\" class=\"btn\" data-action=\"sessions#logout:prevent\">$(icon("logout"))$(screen("Log out"))</button></form>"
    end
    return layout(ctx, content; title, nav)
end

function account_user_html(ctx, user)
    id = value(user, :id)
    own = id == ctx.user.id
    name = value(user, :name)
    content = "<li class=\"flex align-center gap margin-none\"><img class=\"avatar\" src=\"$(avatar_url(ctx,id))\" alt=\"\"><a href=\"/users/$id\">$(h(name))</a>"
    if ctx.user.role == 1 && value(user, :status, 0) == 0 && !own
        next_role = value(user, :role, 0) == 1 ? "member" : "administrator"
        label =
            next_role == "administrator" ? "Make $name an administrator" :
            "Make $name a member"
        content *=
            form_open(ctx, "/account/users/$id"; method = "patch") *
            "<input type=\"hidden\" name=\"user[role]\" value=\"$next_role\">" *
            button(label; image = "crown") *
            "</form>"
        content *= delete_form(
            ctx,
            "/account/users/$id",
            "Delete $name";
            confirm = "Permanently remove this person from the account?",
        )
    end
    return content * "</li>"
end

function account_page_html(ctx; users = [], invite_url = nothing)
    admin = value(ctx.user, :role, -1) == 1
    content = "<section class=\"panel flex flex-column gap\"><h1>Account settings</h1>"
    if admin
        content *=
            form_open(
                ctx,
                "/account";
                method = "patch",
                attributes = "enctype=\"multipart/form-data\" class=\"flex flex-column gap\"",
            ) *
            upload_field("account[logo]", "Upload logo"; url = "/account/logo") *
            button("Upload logo"; image = "camera") *
            "</form>" *
            delete_form(ctx, "/account/logo", "Delete logo")
        content *=
            form_open(
                ctx,
                "/account";
                method = "patch",
                attributes = "class=\"flex gap\"",
            ) *
            input("account[name]", "Name this account"; val = value(ctx.account, :name)) *
            button("Save changes") *
            "</form>"
        content *= "<a href=\"/account/bots\">Set up chat bots</a><a href=\"/account/custom_styles/edit\">Custom styles</a>"
        settings = try
            JSON3.read(string(value(ctx.account, :settings, "{}")))
        catch
            Dict()
        end
        restricted =
            get(settings, :restrict_room_creation_to_administrators, false) === true
        content *=
            form_open(ctx, "/account"; method = "put") *
            "<input type=\"hidden\" name=\"account[settings][restrict_room_creation_to_administrators]\" value=\"$(!restricted)\"><button class=\"btn\" role=\"switch\" aria-checked=\"$restricted\">Must be admin to create new rooms</button></form>"
    else
        content *= "<h2>$(h(value(ctx.account,:name)))</h2>"
    end
    invite =
        invite_url === nothing ?
        ctx.base_url * "/join/" * string(value(ctx.account, :join_code)) : invite_url
    content *= "<label>Invitation link<input id=\"invite_url\" class=\"input full-width\" value=\"$(h(invite))\" readonly></label>"
    admin && (
        content *=
            form_open(ctx, "/account/join_code") *
            button("Reset invitation link"; image = "refresh") *
            "</form>"
    )
    content *=
        "<menu class=\"flex flex-column gap\">" *
        join(account_user_html(ctx, user) for user in users) *
        "</menu></section>"
    return layout(ctx, content; title = "Account settings")
end

function room_form_page_html(ctx, room, kind, users)
    id = value(room, :id, nothing)
    admin = id === nothing || ctx.user.role == 1 || value(room, :creator_id) == ctx.user.id
    url = id === nothing ? "/rooms/$kind" : "/rooms/$kind/$id"
    content = "<section class=\"panel flex flex-column gap\"><h1>$(id === nothing ? "New room" : "Room settings")</h1>"
    if admin
        content *=
            form_open(
                ctx,
                url;
                method = id === nothing ? "post" : "patch",
                attributes = "class=\"flex flex-column gap\"",
            ) *
            input("room[name]", "Name this room"; val = value(room, :name), required = true)
        other_kind = kind == "opens" ? "closeds" : "opens"
        other_path =
            id === nothing ? "/rooms/$other_kind/new" : "/rooms/$other_kind/$id/edit"
        label =
            kind == "opens" ? "Give only some access to this room" :
            "Give everyone access to this room"
        content *= "<p>$(kind == "opens" ? "Everyone has access to this room." : "Only selected people have access to this room.")</p><a href=\"$other_path\" class=\"btn\">$label</a>"
        if kind == "closeds"
            for user in users
                selected =
                    value(user, :selected, false) in (true, 1) ||
                    value(user, :id) == ctx.user.id
                content *= "<div class=\"flex align-center gap\"><span>$(h(value(user,:name)))</span><label class=\"switch\"><input type=\"checkbox\" class=\"switch__input\" name=\"user_ids[]\" value=\"$(value(user,:id))\"$(selected ? " checked" : "")><span class=\"switch__btn round\"></span>$(screen("Give $(value(user,:name)) access to this room"))</label></div>"
            end
        else
            content *=
                "<ul>" *
                join("<li>$(h(value(user,:name)))</li>" for user in users) *
                "</ul>"
        end
        content *= button("Save") * "</form>"
    else
        content *=
            "<h2>$(h(value(room,:name)))</h2><ul>" *
            join("<li>$(h(value(user,:name)))</li>" for user in users) *
            "</ul>"
    end
    if id !== nothing
        content *= view(
            ctx,
            :involvement;
            room,
            involvement = value(room, :involvement, "mentions"),
        )
        admin && (
            content *= delete_form(
                ctx,
                "/rooms/$id",
                "Delete $(value(room,:name))";
                confirm = "Delete this room and all messages in it? This cannot be undone.",
            )
        )
    end
    return layout(ctx, content*"</section>"; title = "Room settings")
end

function view(ctx, name::Symbol; kwargs...)
    option(key, default = nothing) = get(kwargs, key, default)
    if name in (:room, :room_show)
        return room_page_html(ctx, option(:room), option(:messages, []))
    elseif name == :sidebar
        return sidebar_html(ctx; rooms = option(:rooms))
    elseif name in (:direct_form, :direct_new)
        return direct_form_html(ctx)
    elseif name in (:search, :searches)
        return search_page_html(ctx, option(:messages, []), option(:q, ""))
    elseif name in (:message_edit, :edit_message)
        return edit_message_html(ctx, option(:message))
    elseif name == :transfer
        content =
            form_open(
                ctx,
                ctx.path;
                method = "put",
                attributes = "data-controller=\"auto-submit\"",
            ) *
            button("Sign in") *
            "</form>"
        return layout(ctx, content; title = "Sign in")
    elseif name in (:first_run, :join, :session, :login)
        setup = name == :first_run
        joining = name == :join
        title =
            setup ? "Set up Campfire" :
            joining ? "Join $(value(ctx.account,:name,"Campfire"))" : "Sign in"
        url = setup ? "/first_run" : joining ? "/join/$(option(:join_code,""))" : "/session"
        fields =
            setup || joining ?
            upload_field("user[avatar]", "Add your avatar") *
            input("user[name]", "Name"; required = true) : ""
        prefix = setup || joining ? "user[" : ""
        suffix = setup || joining ? "]" : ""
        fields *= input(
            prefix*"email_address"*suffix,
            "Email address";
            type = "email",
            required = true,
            attributes = "autocomplete=\"username\"",
        )
        fields *= input(
            prefix*"password"*suffix,
            "Password";
            type = "password",
            required = true,
            attributes = "maxlength=\"72\" autocomplete=\"$(setup || joining ? "new-password" : "current-password")\"",
        )
        content = """<section class="panel flex flex-column gap"><h1 class="txt-large">$(h(title))</h1><div role="alert">$(h(option(:alert,option(:error,""))))</div>
          $(form_open(ctx,url;attributes="class=\"flex flex-column gap\" enctype=\"multipart/form-data\""))$fields$(button(setup || joining ? "Save" : "Sign in";image="arrow-right"))</form></section>"""
        return layout(ctx, content; title, body_class = setup || joining ? "signup" : "")
    elseif name in (:profile, :user)
        return profile_page_html(
            ctx,
            option(:user, ctx.user);
            editing = name==:profile,
            transfer = option(:transfer_url, ""),
            qr = option(:qr_url, ""),
            memberships = option(:memberships, []),
        )
    elseif name == :account
        return account_page_html(
            ctx;
            users = option(:users, []),
            invite_url = option(:invite_url),
        )
    elseif name in (:styles, :custom_styles)
        content = """<section class="panel panel--wide"><h1>Custom styles</h1>$(form_open(ctx,"/account/custom_styles";method="patch",attributes="class=\"flex flex-column gap\""))<textarea name="account[custom_styles]" class="input full-width" rows="20" aria-label="Custom styles">$(h(value(ctx.account,:custom_styles)))</textarea>$(button("Save changes"))</form></section>"""
        return layout(ctx, content; title = "Custom styles")
    elseif name in (:bot_form, :bot_new, :bot_edit)
        bot = option(:bot, option(:user))
        existing = bot !== nothing
        url = existing ? "/account/bots/$(value(bot,:id))" : "/account/bots"
        avatar =
            existing ? avatar_url(ctx, value(bot, :id)) : "/assets/default-bot-avatar.svg"
        content = """<section class="panel flex flex-column gap"><h1>Chat Bot Setup</h1>$(form_open(ctx,url;method=existing ? "patch" : "post",attributes="class=\"flex flex-column gap\" enctype=\"multipart/form-data\""))$(upload_field("user[avatar]","Upload bot avatar";url=avatar))$(input("user[name]","Name the bot";val=value(bot,:name),required=true))$(input("user[webhook_url]","Webhook URL";val=value(bot,:webhook_url),type="url"))$(button("Save changes"))</form>"""
        if existing
            content *=
                delete_form(
                    ctx,
                    url,
                    "Delete this chat bot";
                    confirm = "Permanently remove this bot from the account?",
                ) *
                form_open(ctx, url*"/key"; method = "put") *
                button("Generate a new key"; image = "refresh") *
                "</form>"
        end
        content *= "</section>"
        return layout(ctx, content; title = "Chat Bot Setup")
    elseif name == :bots
        content = "<section class=\"panel panel--wide flex flex-column gap\"><h1>Chat bots</h1><a href=\"/account/bots/new\" class=\"btn\">Add a chat bot</a>"
        for bot in option(:bots, [])
            content *= "<section class=\"fill-shade border-radius pad\"><h2>$(h(value(bot,:name)))</h2><a href=\"/account/bots/$(value(bot,:id))/edit\">Edit $(h(value(bot,:name)))</a>"
            for room in value(bot, :rooms, option(:rooms, []))
                command = "curl -d 'Hello!' $(ctx.base_url)/rooms/$(value(room,:id))/$(value(bot,:bot_key,value(bot,:bot_token)))/messages"
                content *= "<label>$(h(value(room,:name)))<input class=\"input full-width\" aria-label=\"curl command for posting messages\" value=\"$(h(command))\" readonly></label>"
            end
            content *= "</section>"
        end
        return layout(ctx, content*"</section>"; title = "Chat bots")
    elseif name == :involvement
        room = option(:room)
        id = value(room, :id)
        involvement = option(:involvement, "mentions")
        order =
            value(room, :type) == "Rooms::Direct" ? ["everything", "nothing"] :
            ["mentions", "everything", "nothing", "invisible"]
        index = something(findfirst(==(involvement), order), 0)
        next = order[mod1(index + 1, length(order))]
        return """<turbo-frame id="involvement_room_$id">$(form_open(ctx,"/rooms/$id/involvement";method="put"))<input type="hidden" name="involvement" value="$next"><button class="btn $(h(involvement))" aria-label="Change notifications">$(icon("notification-bell-$involvement"))</button></form></turbo-frame>"""
    elseif name == :room_settings
        room = option(:room)
        id = value(room, :id)
        kind =
            value(room, :type)=="Rooms::Closed" ? "closeds" :
            value(room, :type)=="Rooms::Direct" ? "directs" : "opens"
        content = """<section class="panel flex flex-column gap"><h1>$(h(value(room,:display_name,value(room,:name))))</h1>"""
        if kind == "directs"
            users = qrows(
                ctx.app,
                "SELECT u.* FROM users u JOIN memberships m ON m.user_id=u.id WHERE m.room_id=? ORDER BY lower(u.name)",
                (id,),
            )
            content *= join(
                "<div class=\"flex align-center gap\"><img class=\"avatar\" src=\"$(avatar_url(ctx,value(user,:id)))\" alt=\"\"><a href=\"/users/$(value(user,:id))\">$(h(value(user,:name)))</a></div>"
                for user in users
            )
            content *= delete_form(
                ctx,
                "/rooms/directs/$id",
                "Delete Ping";
                confirm = "Delete this ping and all messages in it? This cannot be undone.",
            )
        else
            content *= "<a href=\"/rooms/$kind/$id/edit\" class=\"btn\">Edit room</a>"
        end
        content *=
            view(
                ctx,
                :involvement;
                room,
                involvement = option(:involvement, value(room, :involvement, "mentions")),
            ) * "</section>"
        return layout(ctx, content; title = "Room settings")
    elseif name == :push_subscriptions
        content = "<section class=\"panel flex flex-column gap\"><h1>Notification subscriptions</h1>"
        for subscription in option(:subscriptions, [])
            content *=
                "<div>$(h(value(subscription,:user_agent,"Device")))</div>" * delete_form(
                    ctx,
                    "/users/me/push_subscriptions/$(value(subscription,:id))",
                    "Remove subscription",
                )
        end
        return layout(ctx, content*"</section>"; title = "Notification subscriptions")
    elseif name in (:room_form, :room_new, :room_edit)
        room = option(:room)
        kind = option(
            :kind,
            value(room, :type, "Rooms::Open")=="Rooms::Closed" ? "closeds" : "opens",
        )
        return room_form_page_html(ctx, room, kind, option(:users, []))
    else
        return layout(
            ctx,
            "<section class=\"panel\"><h1>$(h(option(:title,string(name))))</h1>$(h(option(:message,"")))</section>";
            title = option(:title, "Campfire"),
        )
    end
end
