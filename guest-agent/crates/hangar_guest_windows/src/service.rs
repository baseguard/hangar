//! The agent's Windows service, running as SYSTEM in session 0.

use std::{
    fs::{File, OpenOptions},
    io::{self, Write},
    os::windows::fs::OpenOptionsExt,
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread::{self, JoinHandle, sleep},
    time::Duration,
};

use super::{LOG_FILE, SERVICE, clipboard::PIPE, exec_relay, folder, policy, trust};
use hangar_error::{Error, Result};
use hangar_host_commands::{HostCommand, follow_host_port};
use hangar_report::{self as report, Memory};
use hangar_sys_windows::{
    self as sys,
    channel::{self, Channel, PipeInstances},
    service,
};

const REPORT_PORT: &str = r"\\.\Global\io.baseguard.hangar.report";
const COMMAND_PORT: &str = r"\\.\Global\io.baseguard.hangar.agent";
const CLIPBOARD_PORT: &str = r"\\.\Global\com.redhat.spice.0";
const PORT_RETRY: Duration = Duration::from_secs(5);
const EMPTY_PORT_PAUSE: Duration = Duration::from_millis(200);
const SHUTDOWN_RETRY_PAUSE: Duration = Duration::from_secs(2);
const RELAY_BUFFER: usize = 64 * 1024;
const CONSOLE_CHECK: Duration = Duration::from_secs(1);

pub fn run() -> Result<()> {
    service::serve(SERVICE, work).map_err(|error| {
        Error::step(
            "start the service; only Windows' service manager runs this",
            error,
        )
    })
}

fn work() {
    start_thread("report", report_memory);
    start_relays();
    follow_host();
}

/// A thread that can't start leaves its part out; the service goes on without it.
pub(crate) fn start_thread(name: &str, work: impl FnOnce() + Send + 'static) {
    let started = thread::Builder::new().name(name.into()).spawn(work);
    if let Err(error) = started {
        note_in_log(&Error::step("start a thread of the service", error));
    }
}

fn report_memory() {
    report::send(|| open_port_write_only(REPORT_PORT), guest_memory, || None)
}

fn guest_memory() -> Option<Memory> {
    let memory = sys::physical_memory()?;
    Memory::from_total_and_available(memory.total, memory.available)
}

/// No sharing, so no other program can open the port while the agent has it.
fn open_port_write_only(path: &str) -> Option<File> {
    OpenOptions::new().write(true).share_mode(0).open(path).ok()
}

fn open_port_read_write(path: &str) -> Option<File> {
    OpenOptions::new()
        .read(true)
        .write(true)
        .share_mode(0)
        .open(path)
        .ok()
}

fn follow_host() {
    follow_host_port(|| open_port_read_write(COMMAND_PORT), obey);
}

fn obey(command: HostCommand) {
    match command {
        HostCommand::ShutDown => shut_down(),
        HostCommand::Trust(state) => trust::reconcile(&state),
    }
}

fn shut_down() {
    if start_shutdown().is_ok() {
        return;
    }

    sleep(SHUTDOWN_RETRY_PAUSE);
    if let Err(error) = start_shutdown() {
        note_in_log(&Error::step("shut Windows down", error));
    }
}

/// A shutdown already under way (`ERROR_SHUTDOWN_IN_PROGRESS`) is what Hangar asked for.
fn start_shutdown() -> io::Result<()> {
    match sys::shut_down() {
        Err(error) if sys::is_shutdown_in_progress(&error) => Ok(()),
        started => started,
    }
}

/// The relays need this program's path to tell the session helper from other programs.
fn start_relays() {
    let this_program = match std::env::current_exe() {
        Ok(this_program) => this_program,
        Err(error) => {
            note_in_log(&Error::step("start the relays", error));
            return;
        }
    };

    let clipboard_program = this_program.clone();
    start_thread("clipboard relay", move || {
        relay_clipboard(&clipboard_program);
    });
    exec_relay::start(this_program);
}

/// Only SYSTEM can open the SPICE port; only the session helper can reach the user's clipboard.
fn relay_clipboard(this_program: &Path) {
    serve_pipe_clients(PIPE, |session| {
        serve_clipboard_client(session, this_program);
    });
}

/// Only the agent's own helper in the console session gets the clipboard; anyone else is dropped.
fn serve_clipboard_client(session: Channel, this_program: &Path) {
    if !policy::client_is_console_helper(&session, this_program) {
        return;
    }
    let Some(client) = session.client_session_id() else {
        return;
    };

    let Ok(port) = Channel::open(CLIPBOARD_PORT) else {
        sleep(PORT_RETRY);
        return;
    };

    relay_one_session(session, port, client);
}

/// Hands each client of the pipe at `path` to `serve`, and never returns. Once made, the pipe's
/// instances are kept through every failure, so its name never goes free for another process.
pub(crate) fn serve_pipe_clients(path: &str, mut serve: impl FnMut(Channel)) {
    let mut instances = make_pipe_instances(path);
    let mut has_noted_failure = false;

    loop {
        match instances.next_client() {
            Ok(client) => serve(client),
            Err(error) => {
                note_first_failure(&mut has_noted_failure, &Error::file("serve", path, error));
                sleep(PORT_RETRY);
            }
        }
    }
}

/// Tries until the pipe is made; until then there is no instance to keep.
fn make_pipe_instances(path: &str) -> PipeInstances {
    let mut has_noted_failure = false;

    loop {
        match PipeInstances::new(path, policy::PIPE_ACCESS) {
            Ok(instances) => return instances,
            Err(error) => {
                note_first_failure(&mut has_noted_failure, &Error::file("serve", path, error));
                sleep(PORT_RETRY);
            }
        }
    }
}

/// A failure that repeats every few seconds would fill the log.
fn note_first_failure(has_noted_failure: &mut bool, failure: &Error) {
    if !*has_noted_failure {
        note_in_log(failure);
        *has_noted_failure = true;
    }
}

/// `client` is the helper's session, the console session when the relay starts.
fn relay_one_session(session: Channel, port: Channel, client: u32) {
    let session = Arc::new(session);
    let port = Arc::new(port);
    let session_ended = Arc::new(AtomicBool::new(false));

    let started = spawn_host_to_session(
        Arc::clone(&port),
        Arc::clone(&session),
        Arc::clone(&session_ended),
        client,
    );
    let host_to_session = match started {
        Ok(copy) => copy,
        Err(error) => {
            note_in_log(&Error::step("relay the clipboard", error));
            return;
        }
    };
    let watch = spawn_console_watch(Arc::clone(&session), Arc::clone(&session_ended), client);

    copy_session_to_host(&session, &port, client);
    session_ended.store(true, Ordering::Release);
    stop_host_to_session(&host_to_session, &port);
    end_console_watch(watch);
}

/// Checked before every forward, so nothing crosses once another user has the screen. The bytes
/// in hand are dropped: a paste from the host reaches the next user only with the host's next copy.
pub(crate) fn client_is_at_the_screen(client: u32) -> bool {
    policy::is_console_session(Some(client), channel::console_session_id())
}

/// When this copy ends, cancelling the helper's side ends the other copy too.
fn spawn_host_to_session(
    port: Arc<Channel>,
    session: Arc<Channel>,
    session_ended: Arc<AtomicBool>,
    client: u32,
) -> io::Result<JoinHandle<()>> {
    thread::Builder::new()
        .name("clipboard relay to the helper".into())
        .spawn(move || {
            copy_host_to_session(&port, &session, &session_ended, client);
            session.cancel();
        })
}

/// The copies wait in reads; when another user takes the screen, cancelling the helper's side
/// ends them now rather than at the next copy, so the next user's helper gets the relay. The
/// cancel repeats because it can come just before a read starts.
fn spawn_console_watch(
    session: Arc<Channel>,
    session_ended: Arc<AtomicBool>,
    client: u32,
) -> io::Result<JoinHandle<()>> {
    thread::Builder::new()
        .name("clipboard console watch".into())
        .spawn(move || {
            while !session_ended.load(Ordering::Acquire) {
                if !client_is_at_the_screen(client) {
                    session.cancel();
                }
                sleep(CONSOLE_CHECK);
            }
        })
}

/// The watch holds the helper's pipe; the helper sees its relay end only once the pipe is closed.
fn end_console_watch(watch: io::Result<JoinHandle<()>>) {
    let ended = match watch {
        Ok(watch) => watch
            .join()
            .map_err(|_panic| io::Error::other("the watch panicked")),
        Err(error) => Err(error),
    };
    if let Err(error) = ended {
        note_in_log(&Error::step("watch the console session", error));
    }
}

/// The SPICE port reads empty while the host isn't listening, so an empty read waits and retries.
fn copy_host_to_session(
    port: &Channel,
    session: &Channel,
    session_ended: &AtomicBool,
    client: u32,
) {
    let mut buffer = vec![0; RELAY_BUFFER];

    while !session_ended.load(Ordering::Acquire) {
        let count = match port.read(&mut buffer) {
            Ok(0) => {
                sleep(EMPTY_PORT_PAUSE);
                continue;
            }
            Ok(count) => count,
            Err(_) => return,
        };

        if !client_is_at_the_screen(client) || session.write_all(&buffer[..count]).is_err() {
            return;
        }
    }
}

fn copy_session_to_host(session: &Channel, port: &Channel, client: u32) {
    let mut buffer = vec![0; RELAY_BUFFER];

    loop {
        let count = match session.read(&mut buffer) {
            Ok(0) | Err(_) => return,
            Ok(count) => count,
        };

        if !client_is_at_the_screen(client) || port.write_all(&buffer[..count]).is_err() {
            return;
        }
    }
}

/// A cancel can come just before the next read starts, so it is repeated until the copy ends.
fn stop_host_to_session(copy: &JoinHandle<()>, port: &Channel) {
    while !copy.is_finished() {
        port.cancel();
        sleep(EMPTY_PORT_PAUSE);
    }
}

/// Session 0 has nobody to show a message to; the log is where a person looks.
pub(crate) fn note_in_log(failure: &Error) {
    hangar_error::note_failure("nowhere else to tell", append_to_log(&failure.to_string()));
}

fn append_to_log(line: &str) -> Result<()> {
    let path = folder()?.join(LOG_FILE);
    let mut log = OpenOptions::new()
        .append(true)
        .create(true)
        .open(&path)
        .map_err(|error| Error::file("open", path.display(), error))?;

    writeln!(log, "{line}").map_err(|error| Error::file("write", path.display(), error))
}
