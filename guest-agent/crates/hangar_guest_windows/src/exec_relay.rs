//! The service's end of `hangar exec`. SYSTEM listens on the exec vsock port and hands each
//! connection, byte for byte, to a pipe of the session helper of the user at the screen, who runs
//! the command; with nobody there, it answers the connection itself.

use std::{
    io::{self, Read, Write},
    path::{Path, PathBuf},
    sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError},
    thread::{self, sleep},
    time::{Duration, Instant},
};

use hangar_exec_frames::{Frame, MAX_PAYLOAD, VSOCK_PORT};
use hangar_sys_windows::{VsockListener, VsockStream, channel::Channel};

use super::{helper_watch, policy, service};

pub(crate) const EXEC_PIPE: &str = r"\\.\pipe\io.baseguard.hangar.exec";
const RETRY: Duration = Duration::from_secs(5);
/// How long a command waits for the helper's next pipe: the helper opens it once the last command
/// took its pipe, so commands started together wait for each other's.
const HELPER_WAIT: Duration = Duration::from_secs(3);
const NOBODY_AT_THE_SCREEN: &str = "Nobody is signed in at the guest's screen; on Windows, \
                                    hangar exec runs commands as that user.";

/// A helper's pipe waiting for a command, with the session it came from.
struct IdleHelper {
    pipe: Channel,
    session: u32,
}

/// The helper keeps one pipe waiting, and opens the next once a command took it.
#[derive(Default)]
pub(crate) struct WaitingHelper {
    slot: Mutex<Option<IdleHelper>>,
    arrived: Condvar,
    /// The session and time of the last pipe put in the slot.
    last_arrival: Mutex<Option<(u32, Instant)>>,
}

impl WaitingHelper {
    fn put(&self, helper: IdleHelper) {
        self.note_arrival(helper.session);
        *self.lock() = Some(helper);
        self.arrived.notify_one();
    }

    fn note_arrival(&self, session: u32) {
        let mut last_arrival = self
            .last_arrival
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        *last_arrival = Some((session, Instant::now()));
    }

    /// The waiting pipe, if its user still has the screen; waits up to `HELPER_WAIT` for one.
    fn take(&self) -> Option<Channel> {
        let (mut slot, _timed_out) = self
            .arrived
            .wait_timeout_while(self.lock(), HELPER_WAIT, |slot| slot.is_none())
            .unwrap_or_else(PoisonError::into_inner);
        let helper = slot.take()?;
        service::client_is_at_the_screen(helper.session).then_some(helper.pipe)
    }

    /// A helper that ended leaves its pipe behind, disconnected.
    pub(crate) fn has_helper_in(&self, session: u32) -> bool {
        let slot = self.lock();
        slot.as_ref()
            .is_some_and(|helper| helper.session == session && helper.pipe.is_connected())
    }

    /// The slot is also empty between a command taking the pipe and the helper's next one.
    pub(crate) fn since_helper_arrived_in(&self, session: u32) -> Option<Duration> {
        let last_arrival = *self
            .last_arrival
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        match last_arrival {
            Some((arrived_in, at)) if arrived_in == session => Some(at.elapsed()),
            _ => None,
        }
    }

    fn lock(&self) -> MutexGuard<'_, Option<IdleHelper>> {
        self.slot.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

pub(crate) fn start(this_program: PathBuf) {
    let waiting = Arc::new(WaitingHelper::default());

    let helpers = Arc::clone(&waiting);
    let helper_program = this_program.clone();
    service::start_thread("exec helpers", move || {
        accept_helpers(&helpers, &helper_program);
    });

    let watched = Arc::clone(&waiting);
    service::start_thread("session helper watch", move || {
        helper_watch::keep_helper_running(&watched, &this_program);
    });

    service::start_thread("exec port", move || follow_port(&waiting));
}

fn accept_helpers(waiting: &WaitingHelper, this_program: &Path) {
    service::serve_pipe_clients(EXEC_PIPE, |pipe| {
        keep_if_console_helper(pipe, waiting, this_program);
    });
}

/// Pipes from anything but this agent's helper in the console session are closed at once.
fn keep_if_console_helper(pipe: Channel, waiting: &WaitingHelper, this_program: &Path) {
    if !policy::client_is_console_helper(&pipe, this_program) {
        return;
    }
    if let Some(session) = pipe.client_session_id() {
        waiting.put(IdleHelper { pipe, session });
    }
}

fn follow_port(waiting: &Arc<WaitingHelper>) {
    loop {
        if let Ok(listener) = VsockListener::bind(VSOCK_PORT) {
            while let Ok(connection) = listener.accept_from_host() {
                let waiting = Arc::clone(waiting);
                let _started = thread::Builder::new()
                    .name("exec connection".into())
                    .spawn(move || hand_to_helper(&connection, &waiting));
            }
        }
        sleep(RETRY);
    }
}

fn hand_to_helper(connection: &VsockStream, waiting: &WaitingHelper) {
    let Some(pipe) = waiting.take() else {
        let _sent = (&*connection).write_all(&Frame::failed(NOBODY_AT_THE_SCREEN).encode());
        return;
    };
    relay(connection, &pipe);
}

/// Copies both ways until either side ends. The host leaving disconnects the helper's pipe, which
/// ends the command; the helper closing its pipe after the command shuts the connection down.
fn relay(connection: &VsockStream, pipe: &Channel) {
    thread::scope(|scope| {
        scope.spawn(|| {
            let _copied = copy(&mut &*connection, |bytes| pipe.write_all(bytes));
            pipe.disconnect();
        });
        let _copied = copy(&mut &*pipe, |bytes| (&*connection).write_all(bytes));
        connection.shut_down();
    });
}

/// Until `from` ends or `to` fails.
fn copy(from: &mut impl Read, mut to: impl FnMut(&[u8]) -> io::Result<()>) -> io::Result<()> {
    let mut chunk = vec![0; MAX_PAYLOAD];
    loop {
        let count = from.read(&mut chunk)?;
        if count == 0 {
            return Ok(());
        }
        to(&chunk[..count])?;
    }
}
