use std::ptr;

// Isolate the reduction so LLVM does not sink it into a scalar early-exit loop.
#[inline(never)]
fn contains_special(input: &[u8]) -> bool {
    let mut specials = false;
    for &c in input {
        specials |= ((c & 0xfe) == b'&') | ((c & 0xfd) == b'<') | (c == b'"');
    }
    specials
}

// The caller owns a destination large enough for the escaped result.
unsafe fn escape(out: *mut u8, src: *const u8, n: usize) -> usize {
    let input = std::slice::from_raw_parts(src, n);
    if !contains_special(input) {
        ptr::copy_nonoverlapping(src, out, n);
        return n;
    }
    let mut written = 0;
    macro_rules! entity {
        ($s:expr) => {{
            ptr::copy_nonoverlapping($s.as_ptr(), out.add(written), $s.len());
            written += $s.len();
        }};
    }
    for &c in input {
        match c {
            b'&' => entity!(b"&amp;"),
            b'<' => entity!(b"&lt;"),
            b'>' => entity!(b"&gt;"),
            b'"' => entity!(b"&quot;"),
            b'\'' => entity!(b"&#39;"),
            _ => {
                *out.add(written) = c;
                written += 1;
            }
        }
    }
    written
}

#[no_mangle]
pub unsafe extern "C" fn campfire_escape(out: *mut u8, src: *const u8, n: usize) -> usize {
    escape(out, src, n)
}

unsafe fn integer(out: *mut u8, mut value: u64) -> usize {
    let mut reverse = [0u8; 20];
    let mut n = 0;
    loop {
        *reverse.get_unchecked_mut(n) = b'0' + (value % 10) as u8;
        n += 1;
        value /= 10;
        if value == 0 {
            break;
        }
    }
    for i in 0..n {
        *out.add(i) = *reverse.get_unchecked(n - i - 1);
    }
    n
}

#[no_mangle]
pub unsafe extern "C" fn campfire_render(
    out: *mut u8,
    ids: *const u64,
    users: *const *const u8,
    user_lengths: *const usize,
    bodies: *const *const u8,
    body_lengths: *const usize,
    count: usize,
) -> usize {
    let mut used = 0;
    macro_rules! literal {
        ($s:expr) => {{
            ptr::copy_nonoverlapping($s.as_ptr(), out.add(used), $s.len());
            used += $s.len();
        }};
    }
    for i in 0..count {
        literal!(b"<article id=\"message_");
        used += integer(out.add(used), *ids.add(i));
        literal!(b"\"><header>");
        used += escape(out.add(used), *users.add(i), *user_lengths.add(i));
        literal!(b"</header><p>");
        used += escape(out.add(used), *bodies.add(i), *body_lengths.add(i));
        literal!(b"</p></article>\n");
    }
    used
}
