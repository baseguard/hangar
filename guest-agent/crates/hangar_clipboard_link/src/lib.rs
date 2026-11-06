//! The clipboard plumbing every guest system shares: the port reader and the connection state.

#![forbid(unsafe_code)]

use std::{
    fmt,
    io::{self, Read},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, SyncSender, TrySendError},
    },
    thread::{self, sleep},
    time::Duration,
};

use hangar_spice::{self as spice, Decoder, Message, Reply, Session};

const READ_SIZE: usize = 64 * 1024;
const EMPTY_PORT_PAUSE: Duration = Duration::from_secs(1);
/// Messages waiting while the host doesn't read; one more counts the connection as broken, so a
/// host that stopped reading can't make the guest hold ever more of them.
const WAITING_MESSAGES: usize = 8;

/// How long a reader waits for the host before it looks at its stop flag again.
pub const STOP_CHECK: Duration = Duration::from_secs(1);

/// Writes the guest's messages to the host on a thread of its own.
///
/// A write waits while the host doesn't read, and the thread that sends also runs the desktop.
/// Dropping the writer ends its thread once the write in progress returns, which closes the
/// thread's copy of the port.
#[derive(Debug)]
pub struct HostWriter {
    to_host: SyncSender<Vec<u8>>,
}

impl HostWriter {
    pub fn start(
        mut write: impl FnMut(&[u8]) -> io::Result<()> + Send + 'static,
    ) -> io::Result<HostWriter> {
        let (to_host, outgoing) = mpsc::sync_channel::<Vec<u8>>(WAITING_MESSAGES);

        thread::Builder::new()
            .name("clipboard writer".into())
            .spawn(move || {
                for bytes in outgoing {
                    if write(&bytes).is_err() {
                        return;
                    }
                }
            })?;

        Ok(HostWriter { to_host })
    }

    /// Fails when the host stopped reading or a write failed; either way the caller lets go of the
    /// connection.
    pub fn send(&self, message: &Message) -> io::Result<()> {
        match self.to_host.try_send(spice::encode(message)) {
            Ok(()) => Ok(()),
            Err(TrySendError::Full(_)) => Err(io::Error::other("the host stopped reading")),
            Err(TrySendError::Disconnected(_)) => {
                Err(io::Error::other("a write to the host failed"))
            }
        }
    }
}

/// What a read of zero bytes means on the caller's port.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EmptyRead {
    /// Linux virtio ports read empty until the host answers the guest's hello.
    NotYet,
    /// macOS ttys and the Windows relay pipe read empty once the host went away.
    Closed,
}

#[derive(Debug)]
pub enum HostEvent {
    Messages(Vec<Message>),
    /// The port closed or sent bytes that aren't SPICE.
    Closed,
}

/// `deliver` runs on the reader's thread.
pub fn read_host_messages(
    mut port: impl Read,
    empty_read: EmptyRead,
    mut deliver: impl FnMut(HostEvent),
) {
    let mut decoder = Decoder::default();
    let mut buffer = vec![0; READ_SIZE];

    loop {
        let count = match port.read(&mut buffer) {
            Ok(0) if empty_read == EmptyRead::NotYet => {
                sleep(EMPTY_PORT_PAUSE);
                continue;
            }
            Ok(0) | Err(_) => break,
            Ok(count) => count,
        };

        let Ok(messages) = decoder.feed(&buffer[..count]) else {
            break;
        };

        deliver(HostEvent::Messages(messages));
    }

    // Closed means the port is free: the next user's helper may open it at once.
    drop(port);
    deliver(HostEvent::Closed);
}

/// A port whose reader can be told to stop while the host says nothing. `wait` returns whether
/// bytes, or the port's end, are ready within [`STOP_CHECK`]; `stop` is checked between waits.
pub struct StoppablePort<P, W> {
    pub port: P,
    pub stop: Arc<AtomicBool>,
    pub wait: W,
}

// The port and the wait closure have nothing useful to print.
impl<P, W> fmt::Debug for StoppablePort<P, W> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("StoppablePort")
            .field("stop", &self.stop)
            .finish_non_exhaustive()
    }
}

impl<P: Read, W: FnMut(&P) -> io::Result<bool>> Read for StoppablePort<P, W> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        loop {
            if self.stop.load(Ordering::Relaxed) {
                return Err(io::ErrorKind::ConnectionAborted.into());
            }
            if (self.wait)(&self.port)? {
                return self.port.read(buffer);
            }
        }
    }
}

/// Tells one opening of the port from the next; events of an older one are stale.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ConnectionId(u64);

#[derive(Debug)]
pub struct Link {
    state: State,
}

#[derive(Debug)]
enum State {
    Disconnected {
        last: ConnectionId,
    },
    Connected {
        connection: ConnectionId,
        session: Session,
    },
}

impl Default for Link {
    fn default() -> Self {
        Link {
            state: State::Disconnected {
                last: ConnectionId(0),
            },
        }
    }
}

impl Link {
    /// Returns the id the new reader thread tags its events with.
    pub fn connect(&mut self) -> ConnectionId {
        let connection = ConnectionId(self.last_connection().0 + 1);

        self.state = State::Connected {
            connection,
            session: Session::default(),
        };

        connection
    }

    pub fn is_connected(&self) -> bool {
        match self.state {
            State::Connected { .. } => true,
            State::Disconnected { .. } => false,
        }
    }

    pub fn reply(&mut self, connection: ConnectionId, message: &Message) -> Option<Reply> {
        match &mut self.state {
            State::Connected {
                connection: current,
                session,
            } if *current == connection => session.receive(message),
            State::Connected { .. } | State::Disconnected { .. } => None,
        }
    }

    /// False when a newer connection replaced `connection` already.
    pub fn close(&mut self, connection: ConnectionId) -> bool {
        if !self.is_current(connection) {
            return false;
        }

        self.state = State::Disconnected { last: connection };
        true
    }

    pub fn guest_copied(&self) -> Option<Message> {
        self.session().map(Session::guest_copied)
    }

    pub fn guest_text(&self, text: &str) -> Option<Message> {
        self.session().map(|session| session.guest_text(text))
    }

    fn is_current(&self, connection: ConnectionId) -> bool {
        match self.state {
            State::Connected {
                connection: current,
                ..
            } => current == connection,
            State::Disconnected { .. } => false,
        }
    }

    fn last_connection(&self) -> ConnectionId {
        match self.state {
            State::Connected { connection, .. } => connection,
            State::Disconnected { last } => last,
        }
    }

    fn session(&self) -> Option<&Session> {
        match &self.state {
            State::Connected { session, .. } => Some(session),
            State::Disconnected { .. } => None,
        }
    }
}

#[cfg(test)]
#[path = "lib_test.rs"]
mod tests;
