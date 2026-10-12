#include <stdint.h>
#include <stddef.h>
#include <string.h>

/* The caller owns a destination large enough for the escaped result. */
static inline size_t escape(unsigned char *out, const unsigned char *src, size_t n) {
    unsigned char specials = 0;
    for (size_t i = 0; i < n; ++i) {
        unsigned char c = src[i];
        specials |= ((c & 0xfe) == '&') | ((c & 0xfd) == '<') | (c == '"');
    }
    if (specials == 0) {
        memcpy(out, src, n);
        return n;
    }
    size_t written = 0;
    for (size_t i = 0; i < n; ++i) {
#define ENTITY(s) do { memcpy(out + written, s, sizeof(s) - 1); written += sizeof(s) - 1; } while (0)
        switch (src[i]) {
        case '&': ENTITY("&amp;"); break;
        case '<': ENTITY("&lt;"); break;
        case '>': ENTITY("&gt;"); break;
        case '"': ENTITY("&quot;"); break;
        case '\'': ENTITY("&#39;"); break;
        default: out[written++] = src[i];
        }
#undef ENTITY
    }
    return written;
}

size_t campfire_escape(unsigned char *out, const unsigned char *src, size_t n) {
    return escape(out, src, n);
}

static inline size_t integer(unsigned char *out, uint64_t value) {
    unsigned char reverse[20];
    size_t n = 0;
    do {
        reverse[n++] = (unsigned char)('0' + value % 10);
        value /= 10;
    } while (value != 0);
    for (size_t i = 0; i < n; ++i) out[i] = reverse[n - i - 1];
    return n;
}

#define LITERAL(s) do { memcpy(out + used, s, sizeof(s) - 1); used += sizeof(s) - 1; } while (0)

size_t campfire_render(unsigned char *out, const uint64_t *ids,
        const unsigned char *const *users, const size_t *user_lengths,
        const unsigned char *const *bodies, const size_t *body_lengths, size_t count) {
    size_t used = 0;
    for (size_t i = 0; i < count; ++i) {
        LITERAL("<article id=\"message_");
        used += integer(out + used, ids[i]);
        LITERAL("\"><header>");
        used += escape(out + used, users[i], user_lengths[i]);
        LITERAL("</header><p>");
        used += escape(out + used, bodies[i], body_lengths[i]);
        LITERAL("</p></article>\n");
    }
    return used;
}
