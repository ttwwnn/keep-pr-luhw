//! The attach loop: raw terminal in, tab output out.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::time::Duration;

use anyhow::{Context, Result};
use crossterm::terminal;
use keep_proto::{ClientMsg, ServerMsg};

/// Ctrl-\ detaches. Chosen because almost nothing binds it, so it does not
/// shadow a key the program inside the tab wanted.
const DETACH_BYTE: u8 = 0x1c;

/// Restores the terminal on every exit path, including panics.
struct RawGuard {
    /// Whether the terminal was last put on its alternate screen, followed
    /// from the output; see `KittyFlags`.
    alternate: Arc<AtomicBool>,
}

impl RawGuard {
    fn enter(alternate: Arc<AtomicBool>) -> Result<Self> {
        terminal::enable_raw_mode().context("enable raw mode")?;
        Ok(Self { alternate })
    }
}

impl Drop for RawGuard {
    fn drop(&mut self) {
        let _ = terminal::disable_raw_mode();
        let mut out = std::io::stdout();
        // Give the terminal back as the person lent it. A repaint switches on
        // whatever the tab's program had — the Kitty keyboard, the alternate
        // screen, mouse reporting — and a shell left under them reads mouse
        // moves and `CSI 99;5u` where it expected ctrl-c.
        if self.alternate.load(Ordering::Acquire) {
            let _ = out.write_all(b"\x1b[<99u\x1b[?1049l");
        }
        let _ = out.write_all(KittyFlags::RESTORE);
        // Leave the cursor somewhere sane and re-show it: the session may
        // have hidden it or parked it mid-screen.
        let _ = out.write_all(b"\x1b[?25h\r\n");
        let _ = out.flush();
    }
}

/// Whether the embedder says its surface is on screen. Anything unreadable
/// counts as showing: a viewer that cannot be asked should be given room,
/// not silently dropped from the reckoning.
fn is_showing(path: &std::path::Path) -> bool {
    match std::fs::read_to_string(path) {
        Ok(body) => body.trim() != "0",
        Err(_) => true,
    }
}

pub enum Outcome {
    Detached,
    Ended,
}

/// Attach to a tab and pump it until the person detaches or the shell ends.
///
/// `watching` names a file an embedder may keep beside this client, holding
/// `1` while the surface is on screen and `0` while it is not. A terminal
/// multiplexer fits a tab to its smallest viewer, and this app mounts every
/// tab a window has ever shown and merely hides the ones you are not looking
/// at — so without this a narrow window that visited a tab once would go on
/// voting on its size for as long as the app ran, throttling a wide window
/// showing that same tab for a reason nobody could see. A hidden viewer
/// reports no size at all, and the daemon leaves it out of the reckoning.
pub fn attach(
    socket: &std::path::Path,
    name: &str,
    tab: u32,
    watching: Option<std::path::PathBuf>,
) -> Result<Outcome> {
    let (cols, rows) = terminal::size().unwrap_or((80, 24));

    let mut sock = UnixStream::connect(socket).context("connect to daemon")?;
    ClientMsg::Attach { workspace: name.to_string(), tab, cols, rows }.write(&mut sock)?;

    // The keyboard protocol the terminal we run in is speaking, and which of
    // its screens it is on, as followed from what we write to it; see
    // `KittyFlags`.
    let kitty = Arc::new(AtomicU8::new(0));
    let alternate = Arc::new(AtomicBool::new(false));
    let _raw = RawGuard::enter(Arc::clone(&alternate))?;

    let detached = Arc::new(AtomicBool::new(false));

    // stdin -> daemon
    let mut input_sock = sock.try_clone().context("clone socket")?;
    let input_flag = Arc::clone(&detached);
    let input_kitty = Arc::clone(&kitty);
    std::thread::Builder::new()
        .name("keep-stdin".into())
        .spawn(move || {
            let mut stdin = std::io::stdin();
            let mut buf = [0u8; 4096];
            let mut legacy = Legacy::new();
            loop {
                let read = match stdin.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => n,
                };
                // Decoded only while the program never asked for the
                // protocol. When it did — Claude Code, an editor — the keys
                // are already in the form it wants, and decoding them is what
                // turned shift-return into a bare return.
                let decoded = if input_kitty.load(Ordering::Acquire) == 0 {
                    legacy.decode(&buf[..read])
                } else {
                    legacy.pass(&buf[..read])
                };
                let n = decoded.len();
                if n == 0 {
                    continue;
                }
                let buf = &decoded[..];
                // In the protocol the detach key is a sequence, not a byte:
                // ctrl-\\ arrives as `CSI 92;5u`.
                if let Some(pos) = detach_at(buf) {
                    // Forward whatever preceded the detach key, then stop.
                    if pos > 0 {
                        let _ = ClientMsg::write_input(&mut input_sock, &buf[..pos]);
                    }
                    input_flag.store(true, Ordering::Release);
                    let _ = input_sock.shutdown(std::net::Shutdown::Both);
                    break;
                }
                if ClientMsg::write_input(&mut input_sock, &buf[..n]).is_err() {
                    break;
                }
            }
        })
        .context("spawn stdin thread")?;

    // Window size changes. Polling instead of SIGWINCH keeps this portable
    // and costs one cheap syscall every 200ms.
    let mut resize_sock = sock.try_clone().context("clone socket")?;
    let resize_flag = Arc::clone(&detached);
    std::thread::Builder::new()
        .name("keep-resize".into())
        .spawn(move || {
            let mut sent = (cols, rows);
            while !resize_flag.load(Ordering::Acquire) {
                // Ten commits a second, live. A settle-then-commit variant was
                // tried — one clean redraw when the hand stops — and it was
                // calmer but wrong: what is wanted is the terminal *tracking*
                // the gesture, the way it does when it owns its own PTY. At
                // 5Hz the program's redraws arrived as hiccups; at 10Hz, with
                // half the latency to the first one, they read as motion. The
                // per-tick cost while nothing changes is one syscall.
                std::thread::sleep(Duration::from_millis(100));
                // Zero means "not looking", which the daemon leaves out of
                // the minimum. Read in the same tick as the size, since the
                // two answer one question: how big is this viewer, if at all.
                let showing = watching.as_ref().map(|p| is_showing(p)).unwrap_or(true);
                let now = if showing { terminal::size().unwrap_or(sent) } else { (0, 0) };
                if now != sent {
                    sent = now;
                    let msg = ClientMsg::Resize { cols: now.0, rows: now.1 };
                    if msg.write(&mut resize_sock).is_err() {
                        break;
                    }
                }
            }
        })
        .context("spawn resize thread")?;

    // daemon -> stdout. Locked once for the whole loop: `stdout()` takes the
    // process-wide handle on every call, and this loop runs once per chunk of
    // terminal output.
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    // Reported after the lock is released — the raw-mode guard writes to
    // stdout on its way out.
    let mut failure: Option<String> = None;
    let mut flags = KittyFlags::new();
    let outcome = loop {
        match ServerMsg::read(&mut sock) {
            Ok(Some(ServerMsg::Repaint(data))) => {
                // A repaint is the whole screen from the top, not more output
                // after whatever this terminal was showing: without a clear,
                // a resync painted below the old lines and left the cursor
                // somewhere else. A daemon new enough to say declares the
                // keyboard, flags off included, and needs nothing more.
                out.write_all(b"\x1b[H\x1b[2J")?;
                // A daemon too old to declare the keyboard cannot say whether
                // a pop was among the output this repaint replaces. Not
                // knowing, the terminal's keyboard is reset and input decoded,
                // which is how every client behaved before any of this.
                if !KittyFlags::declared_in(&data) {
                    out.write_all(KittyFlags::FORGET)?;
                    flags.reset();
                }
                flags.observe(&data);
                kitty.store(flags.current(), Ordering::Release);
                alternate.store(flags.on_alternate(), Ordering::Release);
                out.write_all(&data)?;
                out.flush()?;
            }
            Ok(Some(ServerMsg::Output(data))) => {
                flags.observe(&data);
                kitty.store(flags.current(), Ordering::Release);
                alternate.store(flags.on_alternate(), Ordering::Release);
                out.write_all(&data)?;
                out.flush()?;
            }
            // Which tab we landed on; the caller asked for TAB_ANY.
            Ok(Some(ServerMsg::Attached { .. })) => continue,
            Ok(Some(ServerMsg::Ended)) => break Outcome::Ended,
            Ok(Some(ServerMsg::Error(msg))) => {
                failure = Some(msg);
                break Outcome::Ended;
            }
            Ok(Some(_)) => continue,
            Ok(None) | Err(_) => {
                break if detached.load(Ordering::Acquire) {
                    Outcome::Detached
                } else {
                    Outcome::Ended
                };
            }
        }
    };
    drop(out);

    if let Some(msg) = failure {
        drop(_raw);
        anyhow::bail!("{msg}");
    }

    Ok(outcome)
}

/// Where the detach key is in what was read, whichever way it was written.
///
/// A terminal speaking the Kitty keyboard protocol writes ctrl-\\ as
/// `CSI 92;5u` (or `CSI 28;5u`), never as the byte — and a tab whose program
/// asked for the protocol is passed through undecoded, so looking for the
/// byte alone left no way out of any tab running Claude Code or an editor.
/// Control must be the only modifier held, caps lock and num lock aside, and
/// a release is not a press.
fn detach_at(bytes: &[u8]) -> Option<usize> {
    let mut at = 0;
    while at < bytes.len() {
        match bytes[at] {
            DETACH_BYTE => return Some(at),
            0x1b if bytes.get(at + 1) == Some(&b'[') => {
                let mut end = at + 2;
                while end < bytes.len() && (bytes[end].is_ascii_digit() || bytes[end] == b';' || bytes[end] == b':') {
                    end += 1;
                }
                if end < bytes.len() && bytes[end] == b'u' && is_detach_key(&bytes[at + 2..end]) {
                    return Some(at);
                }
                at = end.max(at + 1);
            }
            _ => at += 1,
        }
    }
    None
}

fn is_detach_key(params: &[u8]) -> bool {
    let Ok(text) = std::str::from_utf8(params) else { return false };
    let mut fields = text.split(';');
    let code = fields.next().and_then(|f| f.split(':').next()).and_then(|c| c.parse::<u32>().ok());
    let mut modifier = fields.next().unwrap_or("1").split(':');
    let held = modifier.next().and_then(|m| m.parse::<u32>().ok()).unwrap_or(1).saturating_sub(1);
    let event = modifier.next().and_then(|e| e.parse::<u32>().ok()).unwrap_or(1);
    matches!(code, Some(92) | Some(28)) && held & !(64 | 128) == 4 && event != 3
}

/// The Kitty keyboard flags the terminal this client runs in is using.
///
/// That terminal changes how it writes keys only when a program asks it to,
/// and every such request reaches it through this client — in the tab's
/// output, or in a repaint. So following what is written to it is enough to
/// know which protocol the keys coming back are in: the one the program asked
/// for, to be passed on as they are, or none, in which case whatever arrives
/// as `CSI … u` is `Legacy`'s to undo.
///
/// Kept the way the protocol keeps it: a stack per screen, main and
/// alternate, because an editor pushes its flags on the alternate screen and
/// the shell underneath never sees them.
pub struct KittyFlags {
    main: Vec<u8>,
    alternate: Vec<u8>,
    on_alternate: bool,
    /// A sequence split across two writes; see `Legacy::partial`.
    partial: Vec<u8>,
}

impl KittyFlags {
    /// Written on the way out: every flag pushed on this screen popped,
    /// modifyOtherKeys back to its default, and the modes a program switches
    /// on for itself switched off — mouse reporting, focus reports, bracketed
    /// paste, application cursor keys and keypad.
    pub const RESTORE: &'static [u8] = b"\x1b[<99u\x1b[>4m\
        \x1b[?9l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1005l\x1b[?1006l\x1b[?1015l\
        \x1b[?1016l\x1b[?1004l\x1b[?2004l\x1b[?2031l\x1b[?2048l\x1b[?1l\x1b>\
        \x1b[?6l\x1b[r";

    /// Written before a repaint from a daemon that does not declare the
    /// keyboard: the flags on this screen popped, modifyOtherKeys off.
    pub const FORGET: &'static [u8] = b"\x1b[<99u\x1b[>4m";

    /// Whether a repaint says what the keyboard is — the `CSI = n ; 1 u` a
    /// new daemon ends every repaint with.
    pub fn declared_in(repaint: &[u8]) -> bool {
        let Some(start) = repaint.iter().rposition(|b| *b == 0x1b) else { return false };
        let tail = &repaint[start..];
        tail.len() > 6 && tail.starts_with(b"\x1b[=") && tail.ends_with(b";1u")
            && tail[3..tail.len() - 3].iter().all(u8::is_ascii_digit)
    }
    const LIMIT: usize = 32;
    /// How many pushes a stack holds before the oldest is dropped.
    const DEPTH: usize = 8;

    pub fn new() -> Self {
        Self { main: vec![0], alternate: vec![0], on_alternate: false, partial: Vec::new() }
    }

    pub fn reset(&mut self) {
        *self = Self::new();
    }

    pub fn on_alternate(&self) -> bool {
        self.on_alternate
    }

    pub fn current(&self) -> u8 {
        let stack = if self.on_alternate { &self.alternate } else { &self.main };
        stack.last().copied().unwrap_or(0)
    }

    fn stack(&mut self) -> &mut Vec<u8> {
        if self.on_alternate { &mut self.alternate } else { &mut self.main }
    }

    /// Follow bytes on their way to the terminal.
    pub fn observe(&mut self, bytes: &[u8]) {
        let mut source = std::mem::take(&mut self.partial);
        source.extend_from_slice(bytes);
        let mut at = 0;
        while at < source.len() {
            if source[at] != 0x1b {
                at += 1;
                continue;
            }
            let Some(&kind) = source.get(at + 1) else {
                self.partial = source[at..].to_vec();
                return;
            };
            match kind {
                // RIS: the terminal starts over, keyboard included.
                b'c' => {
                    self.reset();
                    at += 2;
                }
                b'[' => {
                    // Parameters and intermediates, then the final byte.
                    let mut end = at + 2;
                    while end < source.len() && (0x20..=0x3f).contains(&source[end]) {
                        end += 1;
                    }
                    if end >= source.len() {
                        if source.len() - at <= Self::LIMIT {
                            self.partial = source[at..].to_vec();
                        }
                        return;
                    }
                    self.apply(&source[at + 2..end], source[end]);
                    at = end + 1;
                }
                _ => at += 1,
            }
        }
    }

    fn apply(&mut self, params: &[u8], final_byte: u8) {
        let (marker, rest) = match params.first() {
            Some(&m @ (b'<' | b'=' | b'>' | b'?')) => (m, &params[1..]),
            _ => (0, params),
        };
        let numbers: Vec<Option<u32>> = rest
            .split(|b| *b == b';')
            .map(|field| std::str::from_utf8(field).ok().and_then(|f| f.parse().ok()))
            .collect();
        let first = numbers.first().copied().flatten();
        match (marker, final_byte) {
            // Push.
            (b'>', b'u') => {
                let flags = (first.unwrap_or(0) & 0x1f) as u8;
                let stack = self.stack();
                if stack.len() > Self::DEPTH {
                    stack.remove(1);
                }
                stack.push(flags);
            }
            // Pop, and popping past the bottom leaves nothing asked for.
            (b'<', b'u') => {
                for _ in 0..first.unwrap_or(1).max(1).min(Self::DEPTH as u32 + 1) {
                    let stack = self.stack();
                    if stack.len() > 1 {
                        stack.pop();
                    } else {
                        stack[0] = 0;
                    }
                }
            }
            // Set, add or remove flags in place — the form a repaint uses.
            (b'=', b'u') => {
                let flags = (first.unwrap_or(0) & 0x1f) as u8;
                let mode = numbers.get(1).copied().flatten().unwrap_or(1);
                if let Some(top) = self.stack().last_mut() {
                    *top = match mode {
                        2 => *top | flags,
                        3 => *top & !flags,
                        _ => flags,
                    };
                }
            }
            // Switching screens switches stacks; a fresh alternate screen
            // starts with nothing asked for.
            (b'?', b'h' | b'l') => {
                let switches = numbers.iter().flatten().any(|n| matches!(n, 47 | 1047 | 1049));
                if switches {
                    let entering = final_byte == b'h';
                    if entering && !self.on_alternate {
                        self.alternate = vec![0];
                    }
                    self.on_alternate = entering;
                }
            }
            _ => {}
        }
    }
}

/// Turn Kitty keyboard sequences back into the bytes a shell expects.
///
/// The terminal this client runs in speaks the Kitty keyboard protocol: it
/// encodes ctrl-c as `CSI 3 ; 5 u` rather than as the byte 0x03. The shell at
/// the other end of the socket never agreed to that protocol and cannot read
/// it — it printed the escape and carried on, and nothing could be cancelled.
///
/// A relay between two terminals that disagree is the place to reconcile
/// them, so the sequences are decoded here on their way through. Only the
/// form `CSI <code> ; <modifiers> u` is touched; everything else, arrows and
/// function keys included, passes untouched because it does not end in `u`.
///
/// Only while the program asked for nothing (see `KittyFlags`). A program
/// that asked for the protocol reads it, and decoding it anyway threw away
/// every modifier the legacy bytes have no room for: shift-return reached
/// Claude Code as a bare return, and sent the message.
pub struct Legacy {
    /// A sequence split across two reads. Escape sequences are short, and a
    /// buffer that grows without limit on malformed input is a way to be
    /// killed by whatever is on the other end.
    partial: Vec<u8>,
}

impl Legacy {
    const LIMIT: usize = 32;

    pub fn new() -> Self {
        Self { partial: Vec::new() }
    }

    /// The input as it came, with anything held from a previous read in
    /// front of it — for when there is nothing to reconcile.
    pub fn pass(&mut self, input: &[u8]) -> Vec<u8> {
        let mut out = std::mem::take(&mut self.partial);
        out.extend_from_slice(input);
        out
    }

    pub fn decode(&mut self, input: &[u8]) -> Vec<u8> {
        let mut source = std::mem::take(&mut self.partial);
        source.extend_from_slice(input);

        let mut out = Vec::with_capacity(source.len());
        let mut at = 0;
        while at < source.len() {
            if source[at] != 0x1b {
                out.push(source[at]);
                at += 1;
                continue;
            }
            match Self::sequence(&source[at..]) {
                // A complete CSI ... u: keep what it means, drop how it was
                // written.
                Step::Decoded(byte, length) => {
                    if let Some(byte) = byte {
                        out.push(byte);
                    }
                    at += length;
                }
                Step::Untouched(length) => {
                    out.extend_from_slice(&source[at..at + length]);
                    at += length;
                }
                // Ends mid-sequence: hold it for the next read rather than
                // forwarding half an escape.
                Step::Incomplete => {
                    if source.len() - at <= Self::LIMIT {
                        self.partial.extend_from_slice(&source[at..]);
                    } else {
                        out.extend_from_slice(&source[at..]);
                    }
                    return out;
                }
            }
        }
        out
    }
}

enum Step {
    /// A `CSI ... u` worth this byte, and how long it was.
    Decoded(Option<u8>, usize),
    /// Something else of this length, to be passed on as it is.
    Untouched(usize),
    Incomplete,
}

impl Legacy {
    fn sequence(bytes: &[u8]) -> Step {
        // An escape on its own is a key somebody pressed, not the start of
        // something yet to arrive. Held back waiting for a sequence that never
        // came, it took with it the escape key and every key this terminal
        // chooses to write as a bare escape.
        if bytes.len() < 2 {
            return Step::Untouched(1);
        }
        if bytes[1] != b'[' {
            return Step::Untouched(1);
        }
        let mut end = 2;
        while end < bytes.len() {
            let byte = bytes[end];
            // Parameters and separators, then a final byte that says what the
            // sequence is.
            if byte.is_ascii_digit() || byte == b';' || byte == b':' {
                end += 1;
                continue;
            }
            if !byte.is_ascii_alphabetic() && byte != b'~' {
                return Step::Untouched(end + 1);
            }
            if byte != b'u' {
                return Step::Untouched(end + 1);
            }
            let params = &bytes[2..end];
            return Step::Decoded(Self::byte_for(params), end + 1);
        }
        if bytes.len() > Self::LIMIT {
            Step::Untouched(bytes.len())
        } else {
            Step::Incomplete
        }
    }

    /// The byte a `CSI code ; modifiers u` stands for.
    ///
    /// Kitty writes the modifiers as a bitmask plus one, with control at bit
    /// two. A key pressed with control is the byte the key would send with
    /// control held: letters fold into the C0 range, and a code already in
    /// that range is the byte itself — which is what this terminal sends for
    /// ctrl-c, `CSI 3 ; 5 u`, three being the byte it already means.
    fn byte_for(params: &[u8]) -> Option<u8> {
        let text = std::str::from_utf8(params).ok()?;
        let mut fields = text.split(';');
        let code: u32 = fields.next()?.split(':').next()?.parse().ok()?;
        let modifiers: u32 = fields
            .next()
            .and_then(|f| f.split(':').next())
            .and_then(|f| f.parse().ok())
            .unwrap_or(1);
        let held = modifiers.saturating_sub(1);
        let ctrl = held & 0b100 != 0;

        if code < 0x20 {
            return u8::try_from(code).ok();
        }
        if ctrl && (b'a'..=b'z').contains(&(code as u8)) {
            return Some((code as u8) & 0x1f);
        }
        if ctrl && (b'A'..=b'Z').contains(&(code as u8)) {
            return Some((code as u8) & 0x1f);
        }
        // The rest of the C0 row a terminal types with control: @ [ \\ ] ^ _.
        // ctrl-\\ among them, which is the detach key, and was dropped here.
        if ctrl && code < 0x80 && (0x40..=0x5f).contains(&(code as u8)) {
            return Some((code as u8) & 0x1f);
        }
        // Not something this cares about: a plain key that the terminal chose
        // to report in the protocol. Its own byte.
        if code < 0x80 && held == 0 {
            return u8::try_from(code).ok();
        }
        None
    }
}

#[cfg(test)]
mod legacy_tests {
    use super::Legacy;

    #[test]
    fn ctrl_c_becomes_the_byte_a_tty_turns_into_a_signal() {
        let mut legacy = Legacy::new();
        assert_eq!(legacy.decode(b"\x1b[3;5u"), vec![0x03]);
    }

    #[test]
    fn a_letter_held_with_control_folds_into_the_control_range() {
        let mut legacy = Legacy::new();
        assert_eq!(legacy.decode(b"\x1b[100;5u"), vec![0x04]);
        assert_eq!(legacy.decode(b"\x1b[122;5u"), vec![0x1a]);
    }

    #[test]
    fn control_with_the_rest_of_the_row_is_the_control_byte() {
        let mut legacy = Legacy::new();
        assert_eq!(legacy.decode(b"\x1b[92;5u"), vec![0x1c], "ctrl-\\ is the detach key");
        assert_eq!(legacy.decode(b"\x1b[91;5u"), vec![0x1b]);
    }

    #[test]
    fn ordinary_typing_passes_through() {
        let mut legacy = Legacy::new();
        assert_eq!(legacy.decode(b"ls -la\r"), b"ls -la\r".to_vec());
    }

    #[test]
    fn arrows_and_other_escapes_are_left_alone() {
        let mut legacy = Legacy::new();
        assert_eq!(legacy.decode(b"\x1b[A\x1b[3~\x1bOP"), b"\x1b[A\x1b[3~\x1bOP".to_vec());
    }

    #[test]
    fn a_sequence_split_across_reads_is_still_decoded() {
        let mut legacy = Legacy::new();
        assert_eq!(legacy.decode(b"abc\x1b[3"), b"abc".to_vec());
        assert_eq!(legacy.decode(b";5u!"), vec![0x03, b'!']);
    }

    /// A relay may translate what it understands. It may never eat a key.
    #[test]
    fn an_escape_on_its_own_is_passed_on_at_once() {
        let mut legacy = Legacy::new();
        assert_eq!(legacy.decode(b"\x1b"), vec![0x1b], "the escape key was swallowed");
        assert_eq!(legacy.decode(b"\x1b\x1b"), vec![0x1b, 0x1b]);
        assert_eq!(legacy.decode(b"vi\x1b"), b"vi\x1b".to_vec());
    }

    #[test]
    fn nonsense_does_not_grow_without_limit() {
        let mut legacy = Legacy::new();
        let junk = [0x1b; 200];
        let out = legacy.decode(&junk);
        assert!(!out.is_empty(), "a flood of escapes was swallowed whole");
    }

    /// For a program that asked for the protocol, shift-return is itself.
    #[test]
    fn passing_leaves_the_protocol_alone() {
        let mut legacy = Legacy::new();
        assert_eq!(legacy.pass(b"\x1b[13;2u"), b"\x1b[13;2u".to_vec());
    }

    #[test]
    fn passing_hands_on_what_decoding_was_holding() {
        let mut legacy = Legacy::new();
        assert_eq!(legacy.decode(b"\x1b[13"), b"".to_vec());
        assert_eq!(legacy.pass(b";2u"), b"\x1b[13;2u".to_vec());
    }
}

#[cfg(test)]
mod detach_tests {
    use super::detach_at;

    #[test]
    fn the_byte_detaches() {
        assert_eq!(detach_at(b"ls\x1c"), Some(2));
    }

    #[test]
    fn the_protocol_forms_detach() {
        assert_eq!(detach_at(b"\x1b[92;5u"), Some(0));
        assert_eq!(detach_at(b"x\x1b[28;5u"), Some(1));
        assert_eq!(detach_at(b"\x1b[92:124;5:1u"), Some(0), "alternates and press");
        assert_eq!(detach_at(b"\x1b[92;69u"), Some(0), "caps lock held too");
    }

    #[test]
    fn a_release_or_another_modifier_does_not() {
        assert_eq!(detach_at(b"\x1b[92;5:3u"), None, "release");
        assert_eq!(detach_at(b"\x1b[92;7u"), None, "ctrl-alt");
        assert_eq!(detach_at(b"\x1b[92u"), None, "backslash on its own");
        assert_eq!(detach_at(b"\x1b[13;2u\x1b[99;5u"), None);
    }
}

#[cfg(test)]
mod kitty_flags_tests {
    use super::KittyFlags;

    fn after(chunks: &[&[u8]]) -> u8 {
        let mut flags = KittyFlags::new();
        for chunk in chunks {
            flags.observe(chunk);
        }
        flags.current()
    }

    #[test]
    fn a_shell_asks_for_nothing() {
        assert_eq!(after(&[b"$ ls -la\r\nfile\r\n$ \x1b[1;32mok\x1b[0m"]), 0);
    }

    /// What Claude Code writes when it starts, and when it exits.
    #[test]
    fn claude_code_asks_and_then_gives_it_back() {
        assert_eq!(after(&[b"\x1b[<u\x1b[>5u\x1b[>4;2m"]), 5);
        assert_eq!(after(&[b"\x1b[<u\x1b[>5u\x1b[>4;2m", b"bye\x1b[<u\x1b[>4m"]), 0);
    }

    /// The form a repaint carries.
    #[test]
    fn a_repaint_sets_the_flags_in_place() {
        assert_eq!(after(&[b"\x1b[?2004h> \x1b[>4;2m\x1b[1;3H\x1b[0m\x1b[=5;1u"]), 5);
        assert_eq!(after(&[b"\x1b[=5;1u", b"\x1b[=2;2u"]), 7);
        assert_eq!(after(&[b"\x1b[=7;1u", b"\x1b[=2;3u"]), 5);
    }

    #[test]
    fn a_sequence_split_across_writes_still_counts() {
        assert_eq!(after(&[b"text\x1b", b"[>", b"5u"]), 5);
    }

    #[test]
    fn popping_past_the_bottom_leaves_nothing_asked_for() {
        assert_eq!(after(&[b"\x1b[>5u\x1b[<3u"]), 0);
        assert_eq!(after(&[b"\x1b[=5;1u\x1b[<u"]), 0);
    }

    #[test]
    fn nested_pushes_unwind_one_at_a_time() {
        assert_eq!(after(&[b"\x1b[>1u\x1b[>5u\x1b[<u"]), 1);
    }

    /// An editor started from Claude Code's shell tool, or a shell under it.
    #[test]
    fn the_alternate_screen_keeps_its_own_stack() {
        let mut flags = KittyFlags::new();
        flags.observe(b"\x1b[>5u");
        flags.observe(b"\x1b[?1049h");
        assert_eq!(flags.current(), 0, "a fresh alternate screen asked for nothing");
        flags.observe(b"\x1b[>1u");
        assert_eq!(flags.current(), 1);
        flags.observe(b"\x1b[<u\x1b[?1049l");
        assert_eq!(flags.current(), 5, "the main screen's flags came back");
    }

    #[test]
    fn a_full_reset_forgets_everything() {
        assert_eq!(after(&[b"\x1b[>5u\x1b[?1049h\x1b[>1u\x1bc"]), 0);
    }

    #[test]
    fn queries_and_other_keyboard_modes_change_nothing() {
        assert_eq!(after(&[b"\x1b[?u\x1b[>4;2m\x1b[>0q\x1b[?25l"]), 0);
    }

    #[test]
    fn the_restore_on_the_way_out_clears_every_push() {
        let mut flags = KittyFlags::new();
        flags.observe(b"\x1b[>1u\x1b[>5u\x1b[>7u");
        flags.observe(KittyFlags::RESTORE);
        assert_eq!(flags.current(), 0);
    }

    #[test]
    fn a_repaint_that_declares_the_keyboard_is_told_apart() {
        assert!(KittyFlags::declared_in(b"\x1b[?1049l\x1b[H\x1b[2J$ \x1b[1;3H\x1b[0m\x1b[=5;1u"));
        assert!(KittyFlags::declared_in(b"$ \x1b[=0;1u"));
        assert!(!KittyFlags::declared_in(b"$ claude\r\n> hi\x1b[4;3H\x1b[0m"), "an old daemon's repaint");
        assert!(!KittyFlags::declared_in(b""));
    }

    /// The form a new daemon's repaint ends with, off included.
    #[test]
    fn a_repaint_declaring_nothing_asked_for_clears_a_stale_push() {
        assert_eq!(after(&[b"\x1b[>5u", b"\x1b[?2004h$ \x1b[1;3H\x1b[0m\x1b[=0;1u"]), 0);
    }
}

#[cfg(test)]
mod tests {
    use super::is_showing;

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("keep-showing-{name}"));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("showing")
    }

    #[test]
    fn a_zero_means_nobody_can_see_us() {
        let p = scratch("off");
        std::fs::write(&p, "0").unwrap();
        assert!(!is_showing(&p));
    }

    #[test]
    fn anything_else_means_we_are_on_screen() {
        let p = scratch("on");
        std::fs::write(&p, "1\n").unwrap();
        assert!(is_showing(&p));
    }

    /// The safe direction when we cannot tell. A client that wrongly says it
    /// is hidden drops out of the size vote and lets the tab reflow under a
    /// window that is looking right at it; one that wrongly says it is visible
    /// just behaves the way every client did before this existed.
    #[test]
    fn no_file_means_we_assume_we_are_seen() {
        assert!(is_showing(&scratch("gone").with_file_name("never-written")));
    }
}
