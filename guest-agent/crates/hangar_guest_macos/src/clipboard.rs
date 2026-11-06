//! Runs on the main thread, except each connection's reader and writer threads.

use std::{
    cell::RefCell,
    fs::{File, OpenOptions},
    io::{self, Write},
    os::unix::fs::OpenOptionsExt,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

use hangar_clipboard_link::{
    self as clipboard_link, ConnectionId, EmptyRead, HostEvent, HostWriter, Link, STOP_CHECK,
    StoppablePort,
};
use hangar_spice::{self as spice, Message, Reply};
use hangar_sys_macos::{self as macos, MainThread};

use super::is_at_the_screen;

const SPICE_PORT: &str = "/dev/tty.com.redhat.spice.0";
/// Also how soon the port is taken after the previous user's agent let go of it.
const CONNECT_RETRY: Duration = Duration::from_secs(1);
const RECONNECT_PAUSE: Duration = Duration::from_secs(2);

/// `NSPasteboard` has no change notification, so its change count is polled.
const PASTEBOARD_POLL: Duration = Duration::from_millis(500);

#[derive(Default)]
struct Clipboard {
    link: Link,
    connection: Option<Connection>,
    /// Includes the agent's own pastes.
    seen_changes: isize,
    next_attempt: Option<Instant>,
}

/// The open port's threads, as the main thread reaches them.
struct Connection {
    id: ConnectionId,
    to_host: HostWriter,
    /// Tells the reader to close its copy of the port and report Closed.
    stop_reader: Arc<AtomicBool>,
}

thread_local! {
    /// GCD work must be `Send`, so timers and the reader reach the main thread's state here.
    static CLIPBOARD: RefCell<Clipboard> = RefCell::new(Clipboard::default());
}

pub(crate) fn start(main: MainThread) {
    let changes = macos::pasteboard_changes(main);
    CLIPBOARD.with_borrow_mut(|clipboard| clipboard.seen_changes = changes);

    poll(main);
}

fn poll(main: MainThread) {
    keep_connected(main);

    if pasteboard_changed(main) && is_connected() && macos::pasteboard_text(main).is_some() {
        announce_guest_copy();
    }

    macos::after(PASTEBOARD_POLL, poll);
}

/// Opens the port for the user at the screen and lets go of it for anyone else.
fn keep_connected(main: MainThread) {
    let at_the_screen = is_at_the_screen();
    let has_port = CLIPBOARD.with_borrow(|clipboard| clipboard.connection.is_some());

    if at_the_screen && !has_port && is_attempt_due() {
        connect_to_host(main);
    } else if !at_the_screen && has_port {
        let_go_of_port();
    }
}

fn is_attempt_due() -> bool {
    let next_attempt = CLIPBOARD.with_borrow(|clipboard| clipboard.next_attempt);
    next_attempt.is_none_or(|due| Instant::now() >= due)
}

fn announce_guest_copy() {
    let copied = CLIPBOARD.with_borrow(|clipboard| clipboard.link.guest_copied());
    if let Some(copied) = copied {
        send_to_host(&copied);
    }
}

fn is_connected() -> bool {
    CLIPBOARD.with_borrow(|clipboard| clipboard.link.is_connected())
}

fn pasteboard_changed(main: MainThread) -> bool {
    let change_count = macos::pasteboard_changes(main);
    CLIPBOARD.with_borrow_mut(|clipboard| {
        let changed = change_count != clipboard.seen_changes;
        clipboard.seen_changes = change_count;
        changed
    })
}

/// A failure leaves the port closed for a later poll to try again.
fn connect_to_host(_main: MainThread) {
    let next_attempt = Instant::now() + CONNECT_RETRY;
    CLIPBOARD.with_borrow_mut(|clipboard| clipboard.next_attempt = Some(next_attempt));

    let Some((reader, writer)) = open_spice_port() else {
        return;
    };

    let id = CLIPBOARD.with_borrow_mut(|clipboard| clipboard.link.connect());
    let stop_reader = Arc::new(AtomicBool::new(false));

    let Ok(to_host) = start_port_threads(reader, writer, id, Arc::clone(&stop_reader)) else {
        CLIPBOARD.with_borrow_mut(|clipboard| clipboard.link.close(id));
        return;
    };

    let connection = Connection {
        id,
        to_host,
        stop_reader,
    };
    CLIPBOARD.with_borrow_mut(|clipboard| clipboard.connection = Some(connection));
    send_to_host(&spice::hello());
}

/// A port that stays cooked isn't used: the line discipline would mangle SPICE's binary messages.
fn open_spice_port() -> Option<(File, File)> {
    // O_NOCTTY: the port must not become the agent's controlling terminal.
    let port = OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NOCTTY | libc::O_CLOEXEC)
        .open(SPICE_PORT)
        .ok()?;

    macos::make_exclusive(&port).ok()?;
    macos::make_raw(&port).ok()?;

    let reader = port.try_clone().ok()?;
    Some((reader, port))
}

/// Returns where the main thread sends its messages to the host.
fn start_port_threads(
    reader: File,
    mut writer: File,
    connection: ConnectionId,
    stop_reader: Arc<AtomicBool>,
) -> io::Result<HostWriter> {
    let to_host = HostWriter::start(move |bytes| writer.write_all(bytes))?;
    thread::Builder::new()
        .name("clipboard".into())
        .spawn(move || read_from_host(reader, stop_reader, connection))?;

    Ok(to_host)
}

fn read_from_host(port: File, stop: Arc<AtomicBool>, connection: ConnectionId) {
    let port = StoppablePort {
        port,
        stop,
        wait: |port: &File| hangar_sys_unix::wait_readable(port, STOP_CHECK),
    };
    clipboard_link::read_host_messages(port, EmptyRead::Closed, |event| {
        hand_to_main(connection, event);
    });
}

fn hand_to_main(connection: ConnectionId, event: HostEvent) {
    macos::on_main(move |main| handle_host_event(main, connection, event));
}

fn handle_host_event(main: MainThread, connection: ConnectionId, event: HostEvent) {
    match event {
        HostEvent::Messages(messages) => {
            for message in &messages {
                answer_host(main, connection, message);
            }
        }
        HostEvent::Closed => disconnect(connection),
    }
}

/// [`Link`] drops messages of a replaced connection.
fn answer_host(main: MainThread, connection: ConnectionId, message: &Message) {
    let reply = CLIPBOARD.with_borrow_mut(|clipboard| clipboard.link.reply(connection, message));
    match reply {
        Some(Reply::SendToHost(message)) => send_to_host(&message),
        Some(Reply::SetGuestText(text)) => paste_from_host(main, &text),
        Some(Reply::SendGuestText) => send_guest_text(main),
        None => {}
    }
}

/// Puts the host's text on the pasteboard and counts the change as seen, so it doesn't go back
/// to the host as a copy.
fn paste_from_host(main: MainThread, text: &str) {
    let changes = macos::set_pasteboard_text(main, text);
    CLIPBOARD.with_borrow_mut(|clipboard| clipboard.seen_changes = changes);
}

/// An empty pasteboard is sent as empty text, so the host isn't left waiting.
fn send_guest_text(main: MainThread) {
    let text = macos::pasteboard_text(main).unwrap_or_default();
    let message = CLIPBOARD.with_borrow(|clipboard| clipboard.link.guest_text(&text));

    if let Some(message) = message {
        send_to_host(&message);
    }
}

/// The reader ended on its own: the host went away or the port broke.
fn disconnect(connection: ConnectionId) {
    let current = CLIPBOARD.with_borrow_mut(|clipboard| clipboard.link.close(connection));
    if !current {
        return;
    }

    let next_attempt = Instant::now() + RECONNECT_PAUSE;
    CLIPBOARD.with_borrow_mut(|clipboard| {
        clipboard.connection = None;
        clipboard.next_attempt = Some(next_attempt);
    });
}

/// Nothing more is relayed from here on; the reader closes its copy of the port within
/// [`STOP_CHECK`], and its Closed is then stale.
fn let_go_of_port() {
    CLIPBOARD.with_borrow_mut(|clipboard| {
        let Some(connection) = clipboard.connection.take() else {
            return;
        };
        connection.stop_reader.store(true, Ordering::Relaxed);
        clipboard.link.close(connection.id);
    });
}

/// A connection that can't take the message is let go of, and the next poll connects again.
fn send_to_host(message: &Message) {
    let sent = CLIPBOARD.with_borrow(|clipboard| {
        let connection = clipboard.connection.as_ref()?;
        Some(connection.to_host.send(message))
    });

    if let Some(Err(error)) = sent {
        hangar_error::note_failure("the clipboard connects again", Err::<(), _>(error));
        let_go_of_port();
    }
}
