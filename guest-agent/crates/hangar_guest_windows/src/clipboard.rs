//! The guest side of the shared clipboard, in the session helper.

use std::{
    cell::RefCell,
    rc::Rc,
    sync::{
        Arc,
        mpsc::{self, Receiver, Sender},
    },
    thread,
    time::{Duration, Instant},
};

use hangar_clipboard_link::{
    ConnectionId, EmptyRead, HostEvent, HostWriter, Link, read_host_messages,
};
use hangar_error::{Error, Result};
use hangar_spice::{self as spice, Message, Reply};
use hangar_sys_windows::{
    channel::Channel,
    clipboard::{self as system, Event, Listener, Waker, Window},
};

use super::{is_at_the_screen, policy};

/// Only SYSTEM can open the SPICE port, so the service relays it to the helper over this pipe.
pub(crate) const PIPE: &str = r"\\.\pipe\io.baseguard.hangar.clipboard";
/// Also how soon the relay is taken after the previous user's helper lost it.
const RECONNECT_PAUSE: Duration = Duration::from_secs(1);

/// A reader thread's event, tagged with the connection it belongs to.
type TaggedEvent = (ConnectionId, HostEvent);

struct State {
    link: Link,
    pipe: Option<Arc<Channel>>,
    to_host: Option<HostWriter>,
    /// The sequence number after the host's text was set, so that change isn't announced back.
    host_text_sequence: Option<u32>,
    next_attempt: Instant,
    host_events: Receiver<TaggedEvent>,
    /// Each reader thread sends through a clone.
    host_event_sender: Sender<TaggedEvent>,
}

type Shared = Rc<RefCell<State>>;

/// The clipboard's events arrive while this thread hands out its window messages.
pub(crate) struct Clipboard {
    state: Shared,
    waker: Waker,
    /// Owns the clipboard window and its handler, which holds its own share of the state.
    _listener: Listener,
}

pub(crate) fn start() -> Result<Clipboard> {
    let (host_event_sender, host_events) = mpsc::channel();
    let state = Rc::new(RefCell::new(State {
        link: Link::default(),
        pipe: None,
        to_host: None,
        host_text_sequence: None,
        next_attempt: Instant::now(),
        host_events,
        host_event_sender,
    }));

    let handler_state = Rc::clone(&state);
    let listener = system::listen(move |window, event| handle(window, &handler_state, event))
        .map_err(|error| Error::step("watch the clipboard", error))?;

    let clipboard = Clipboard {
        state,
        waker: listener.waker(),
        _listener: listener,
    };
    clipboard.keep_connected();

    Ok(clipboard)
}

impl Clipboard {
    /// Only the helper at the screen connects; the service ends the relay of one that no longer is.
    pub(crate) fn keep_connected(&self) {
        let due = {
            let state = self.state.borrow();
            !state.link.is_connected() && Instant::now() >= state.next_attempt
        };
        if !due || !is_at_the_screen() {
            return;
        }

        match open_service_pipe() {
            Some(pipe) => begin_connection(&self.state, self.waker, pipe),
            None => retry_later(&self.state),
        }
    }
}

fn handle(window: &Window, state: &Shared, event: Event) {
    match event {
        Event::Changed => announce_guest_copy(state),
        Event::Woken => take_host_events(window, state),
    }
}

fn open_service_pipe() -> Option<Channel> {
    let pipe = Channel::open(PIPE).ok()?;

    if !policy::served_by_system(&pipe) {
        return None;
    }

    Some(pipe)
}

fn begin_connection(state: &Shared, waker: Waker, pipe: Channel) {
    let pipe = Arc::new(pipe);
    let connection = state.borrow_mut().link.connect();
    let sender = state.borrow().host_event_sender.clone();

    let reader_pipe = Arc::clone(&pipe);
    let deliver = move |event| hand_to_window(waker, &sender, connection, event);
    let reader = thread::Builder::new()
        .name("clipboard".into())
        .spawn(move || read_host_messages(&*reader_pipe, EmptyRead::Closed, deliver));

    if reader.is_err() {
        state.borrow_mut().link.close(connection);
        retry_later(state);
        return;
    }

    let writer_pipe = Arc::clone(&pipe);
    let Ok(to_host) = HostWriter::start(move |bytes| writer_pipe.write_all(bytes)) else {
        // The reader then reports Closed, which retries.
        pipe.cancel();
        return;
    };

    state.borrow_mut().pipe = Some(pipe);
    state.borrow_mut().to_host = Some(to_host);
    send_to_host(state, &spice::hello());
}

fn retry_later(state: &Shared) {
    state.borrow_mut().next_attempt = Instant::now() + RECONNECT_PAUSE;
}

fn hand_to_window(
    waker: Waker,
    sender: &Sender<TaggedEvent>,
    connection: ConnectionId,
    event: HostEvent,
) {
    // The receiver lives as long as the helper, so this fails only while it exits.
    hangar_error::note_failure(
        "the session helper is exiting",
        sender.send((connection, event)),
    );
    waker.wake();
}

fn take_host_events(window: &Window, state: &Shared) {
    let events: Vec<TaggedEvent> = state.borrow().host_events.try_iter().collect();

    for (connection, event) in events {
        match event {
            HostEvent::Messages(messages) => answer_host(window, state, connection, &messages),
            HostEvent::Closed => connection_closed(state, connection),
        }
    }
}

fn answer_host(window: &Window, state: &Shared, connection: ConnectionId, messages: &[Message]) {
    for message in messages {
        let reply = state.borrow_mut().link.reply(connection, message);
        match reply {
            Some(Reply::SendToHost(answer)) => send_to_host(state, &answer),
            Some(Reply::SetGuestText(text)) => set_guest_text(window, state, &text),
            Some(Reply::SendGuestText) => send_guest_text(window, state),
            None => {}
        }
    }
}

fn connection_closed(state: &Shared, connection: ConnectionId) {
    let closed = state.borrow_mut().link.close(connection);
    if !closed {
        return;
    }

    state.borrow_mut().pipe = None;
    state.borrow_mut().to_host = None;
    retry_later(state);
}

fn set_guest_text(window: &Window, state: &Shared, text: &str) {
    let windows_text = text.replace("\r\n", "\n").replace('\n', "\r\n");
    let sequence = window.set_text(&windows_text);

    state.borrow_mut().host_text_sequence = sequence;
}

/// The host waits for an answer, so a clipboard with no text, or held open, answers with none.
fn send_guest_text(window: &Window, state: &Shared) {
    let text = window.text().unwrap_or_default().replace("\r\n", "\n");
    let answer = state.borrow().link.guest_text(&text);

    if let Some(answer) = answer {
        send_to_host(state, &answer);
    }
}

fn announce_guest_copy(state: &Shared) {
    let (connected, host_text_sequence) = {
        let state = state.borrow();
        (state.link.is_connected(), state.host_text_sequence)
    };
    let is_host_text = host_text_sequence == Some(system::sequence());

    if !connected || is_host_text || !system::has_text() {
        return;
    }

    let grab = state.borrow().link.guest_copied();
    if let Some(grab) = grab {
        send_to_host(state, &grab);
    }
}

fn send_to_host(state: &Shared, message: &Message) {
    let state = state.borrow();
    let (Some(pipe), Some(to_host)) = (&state.pipe, &state.to_host) else {
        return;
    };

    if to_host.send(message).is_err() {
        // Cancelling every call on the pipe makes the reader report Closed and ends a stuck write.
        pipe.cancel();
    }
}
