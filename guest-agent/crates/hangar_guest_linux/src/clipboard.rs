//! `hangar-agent clipboard`: a GTK app in the user's session that shares copied text with the host.

use std::{
    cell::RefCell,
    fs::{File, OpenOptions},
    io::{self, Write},
    mem,
    os::unix::fs::OpenOptionsExt,
    rc::Rc,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, Sender},
    },
    thread,
    time::Duration,
};

use hangar_clipboard_link::{
    ConnectionId, EmptyRead, HostEvent, HostWriter, Link, STOP_CHECK, StoppablePort,
    read_host_messages,
};
use hangar_spice::{self as spice, Message, Reply};
use hangar_sys_linux::gtk::{App, Clipboard, Event, Gtk, MainQueue};

use super::is_at_the_screen;

/// The udev rule `install` writes lets the desktop's user open this port.
const PORT: &str = "/dev/virtio-ports/com.redhat.spice.0";

const APPLICATION_ID: &str = "io.baseguard.hangar.Clipboard";

/// Also how soon the port is taken after the previous user's helper let go of it, or after a
/// distribution's `spice-vdagent` that held it (the open fails with `EBUSY`) quit.
const CHECK_INTERVAL: Duration = Duration::from_secs(1);

/// A reader thread's event, tagged with the connection it belongs to.
type TaggedEvent = (ConnectionId, HostEvent);

/// The port as GTK's thread sees it; only one reader thread may read it at a time.
enum Port {
    Closed,
    Open {
        connection: ConnectionId,
        to_host: HostWriter,
        stop_reader: Arc<AtomicBool>,
    },
    /// The reader was told to stop. It closes its copy of the port within [`STOP_CHECK`], then
    /// reports Closed.
    Closing,
}

struct State {
    /// Held so the application keeps running without a window.
    app: Option<App>,
    clipboard: Option<Clipboard>,
    link: Link,
    port: Port,
    host_events: Receiver<TaggedEvent>,
    /// Each reader thread sends through a clone.
    host_event_sender: Sender<TaggedEvent>,
}

type Shared = Rc<RefCell<State>>;

pub fn run() -> hangar_error::Result<()> {
    let gtk = super::load_gtk()?;

    // Wayland gives a background client no clipboard; X11 (XWayland there) reports every change.
    gtk.prefer_x11();

    let (host_event_sender, host_events) = mpsc::channel();
    let state = Rc::new(RefCell::new(State {
        app: None,
        clipboard: None,
        link: Link::default(),
        port: Port::Closed,
        host_events,
        host_event_sender,
    }));

    super::run_desktop_helper(gtk, APPLICATION_ID, move |gtk, event| {
        handle(gtk, &state, event);
    })
}

fn handle(gtk: Gtk, state: &Shared, event: Event) {
    match event {
        Event::Startup(app) => start(gtk, state, app),
        Event::Woken => take_host_events(gtk, state),
        Event::ClipboardChanged => guest_copied(state),
        Event::Text(text) => send_guest_text(state, text),
    }
}

fn start(gtk: Gtk, state: &Shared, app: App) {
    gtk.hold(&app);
    let clipboard = gtk.clipboard();

    state.borrow_mut().app = Some(app);
    state.borrow_mut().clipboard = clipboard;

    keep_connected(gtk, state);
}

/// Opens the port for the user at the screen and lets go of it for anyone else.
fn keep_connected(gtk: Gtk, state: &Shared) {
    let at_the_screen = is_at_the_screen();
    let is_closed = matches!(state.borrow().port, Port::Closed);
    let is_open = matches!(state.borrow().port, Port::Open { .. });

    if at_the_screen && is_closed {
        connect(gtk, state);
    } else if !at_the_screen && is_open {
        let_go_of_port(&mut state.borrow_mut());
    }

    let state = Rc::clone(state);
    gtk.after(CHECK_INTERVAL, move |gtk| keep_connected(gtk, &state));
}

/// A failure leaves the port closed for the next check to try again.
fn connect(gtk: Gtk, state: &Shared) {
    let Ok(mut port) = open_port() else {
        return;
    };

    let connection = state.borrow_mut().link.connect();
    let sender = state.borrow().host_event_sender.clone();

    let Ok(stop_reader) = start_reader(gtk.main_queue(), sender, connection, &port) else {
        state.borrow_mut().link.close(connection);
        return;
    };
    let Ok(to_host) = HostWriter::start(move |bytes| port.write_all(bytes)) else {
        stop_reader.store(true, Ordering::Relaxed);
        state.borrow_mut().link.close(connection);
        return;
    };

    state.borrow_mut().port = Port::Open {
        connection,
        to_host,
        stop_reader,
    };

    send(state, &spice::hello());
}

fn open_port() -> io::Result<File> {
    OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NOCTTY | libc::O_CLOEXEC)
        .open(PORT)
}

fn start_reader(
    queue: MainQueue,
    sender: Sender<TaggedEvent>,
    connection: ConnectionId,
    port: &File,
) -> io::Result<Arc<AtomicBool>> {
    let stop = Arc::new(AtomicBool::new(false));
    let reader = StoppablePort {
        port: port.try_clone()?,
        stop: Arc::clone(&stop),
        wait: |port: &File| hangar_sys_unix::wait_readable(port, STOP_CHECK),
    };

    let deliver = move |event| hand_to_gtk(&queue, &sender, connection, event);
    thread::Builder::new()
        .name("clipboard".into())
        .spawn(move || read_host_messages(reader, EmptyRead::NotYet, deliver))?;

    Ok(stop)
}

fn hand_to_gtk(
    queue: &MainQueue,
    sender: &Sender<TaggedEvent>,
    connection: ConnectionId,
    event: HostEvent,
) {
    // The receiver lives as long as the helper, so this fails only while it exits.
    hangar_error::note_failure(
        "the clipboard helper is exiting",
        sender.send((connection, event)),
    );
    queue.wake();
}

fn take_host_events(gtk: Gtk, state: &Shared) {
    let events: Vec<TaggedEvent> = state.borrow().host_events.try_iter().collect();

    for (connection, event) in events {
        match event {
            HostEvent::Messages(messages) => {
                for message in &messages {
                    answer_host(gtk, state, connection, message);
                }
            }
            HostEvent::Closed => reader_stopped(state, connection),
        }
    }
}

fn answer_host(gtk: Gtk, state: &Shared, connection: ConnectionId, message: &Message) {
    let reply = state.borrow_mut().link.reply(connection, message);

    match reply {
        Some(Reply::SendToHost(answer)) => send(state, &answer),
        Some(Reply::SetGuestText(text)) => set_guest_text(state, &text),
        Some(Reply::SendGuestText) => read_guest_text(gtk, state),
        None => {}
    }
}

/// One reader runs at a time, so this is the current one: the port is free to open again.
fn reader_stopped(state: &Shared, connection: ConnectionId) {
    state.borrow_mut().link.close(connection);
    state.borrow_mut().port = Port::Closed;
}

fn send(state: &Shared, message: &Message) {
    let mut current = state.borrow_mut();

    let Port::Open { to_host, .. } = &current.port else {
        return;
    };

    if to_host.send(message).is_err() {
        let_go_of_port(&mut current);
    }
}

/// Nothing more is relayed from here on; the reader closes its copy of the port and reports Closed.
fn let_go_of_port(state: &mut State) {
    let Port::Open {
        connection,
        stop_reader,
        ..
    } = mem::replace(&mut state.port, Port::Closing)
    else {
        return;
    };

    stop_reader.store(true, Ordering::Relaxed);
    state.link.close(connection);
}

fn guest_copied(state: &Shared) {
    let grab = grab_to_announce(&state.borrow());

    if let Some(grab) = grab {
        send(state, &grab);
    }
}

fn grab_to_announce(state: &State) -> Option<Message> {
    let clipboard = state.clipboard.as_ref()?;
    if !state.link.is_connected() || !holds_text_from_another_app(clipboard) {
        return None;
    }

    state.link.guest_copied()
}

/// Text this helper set came from the host, and offering it back would echo it.
fn holds_text_from_another_app(clipboard: &Clipboard) -> bool {
    !clipboard.is_local() && clipboard.offers_text()
}

fn set_guest_text(state: &Shared, text: &str) {
    if let Some(clipboard) = &state.borrow().clipboard {
        clipboard.set_text(text);
    }
}

/// Starts reading the guest's clipboard; [`Event::Text`] brings the text to [`send_guest_text`].
fn read_guest_text(gtk: Gtk, state: &Shared) {
    if let Some(clipboard) = &state.borrow().clipboard {
        gtk.read_text(clipboard);
    }
}

fn send_guest_text(state: &Shared, text: Option<String>) {
    let text = text.unwrap_or_default();
    let message = state.borrow().link.guest_text(&text);

    if let Some(message) = message {
        send(state, &message);
    }
}
