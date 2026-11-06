//! The guest side of `hangar exec`: each connection from the host asks for one command, which the
//! agent starts as a user at the guest; its output and exit code go back on that connection, and
//! the host closing it ends the command. Who runs the command and how is the caller's [`Launch`];
//! the rest is the same on every system.

#![cfg(any(unix, windows))]
#![forbid(unsafe_code)]

#[cfg(unix)]
mod account;
mod session;
#[cfg(unix)]
mod spawn_unix;
#[cfg(windows)]
mod spawn_windows;

use std::{
    io::{Read, Write},
    sync::{Arc, Mutex, PoisonError},
};
#[cfg(unix)]
use std::{process::Command, thread, time::Duration};

#[cfg(unix)]
pub use account::{choose_account, user_command};
use hangar_exec_frames::{Frame, Kind, StartRequest};
#[cfg(unix)]
pub use hangar_sys_unix::Account;
#[cfg(unix)]
use hangar_sys_unix::{VsockListener, VsockStream};
use session::Session;

/// The host runs the agent's own commands, such as `cp-in`, under this name; it isn't on the user's
/// PATH, so it means the program that runs this very agent.
const AGENT_COMMAND: &str = "hangar-agent";

/// The vsock device can show up after the agent starts.
#[cfg(unix)]
const LISTEN_RETRY: Duration = Duration::from_secs(5);

/// How a start request becomes a command.
#[cfg(unix)]
#[derive(Debug)]
pub struct Launch {
    pub command: Command,
    /// Who the command runs as; their terminal is theirs.
    pub account: Account,
    /// Whether the agent switches to `account` before the command starts; not when the command
    /// switches itself, as with `sudo -u`.
    pub switches_user: bool,
}

/// How a start request becomes a command: the session helper runs it as its own user.
#[cfg(windows)]
#[derive(Debug)]
pub struct Launch {
    /// Where the command starts, the user's profile folder.
    pub folder: std::path::PathBuf,
}

/// Chooses who runs a request's command, or says why nobody can.
pub type LaunchFor = fn(&StartRequest) -> Result<Launch, String>;

/// Listens on the exec port for as long as the agent runs, each connection on a thread of its own.
#[cfg(unix)]
pub fn serve(launch: LaunchFor) {
    loop {
        if let Ok(listener) = VsockListener::bind(hangar_exec_frames::VSOCK_PORT) {
            accept_connections(&listener, launch);
        }
        thread::sleep(LISTEN_RETRY);
    }
}

/// Returns once accepting fails.
#[cfg(unix)]
fn accept_connections(listener: &VsockListener, launch: LaunchFor) {
    while let Ok(connection) = listener.accept_from_host() {
        // A thread that can't start drops the connection, which the host reads as the agent
        // leaving.
        let _started = thread::Builder::new()
            .name("exec".into())
            .spawn(move || answer(connection, launch));
    }
}

#[cfg(unix)]
fn answer(connection: VsockStream, launch: LaunchFor) {
    let Ok(writer) = connection.try_clone() else {
        return;
    };
    serve_connection(connection, writer, launch);
}

/// The host's end of the connection: whole frames, from the command's output and exit threads.
#[derive(Clone)]
struct Host(Arc<Mutex<Box<dyn Write + Send>>>);

impl Host {
    fn new(writer: impl Write + Send + 'static) -> Host {
        Host(Arc::new(Mutex::new(Box::new(writer))))
    }

    /// A host that is gone takes nothing; reading the connection notices and ends the command.
    fn send(&self, frame: &Frame) {
        let mut connection = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        let _sent = connection.write_all(&frame.encode());
    }
}

/// Runs the one command the connection asks for, until it exits or the host goes away.
pub fn serve_connection(
    mut connection: impl Read,
    writer: impl Write + Send + 'static,
    launch: LaunchFor,
) {
    let request = read_start(&mut connection);
    run_command(request, connection, writer, launch);
}

/// The connection's first frame, which must be the start; waits for it.
pub fn read_start(connection: &mut impl Read) -> Result<StartRequest, String> {
    let unreadable = || "The agent can't read Hangar's request.".to_string();
    let frame = Frame::read_from(connection)
        .ok()
        .flatten()
        .ok_or_else(unreadable)?;
    if frame.kind != Kind::Start {
        return Err(unreadable());
    }
    StartRequest::parse(&frame.payload).ok_or_else(unreadable)
}

/// Starts the command `request` asks for and follows the host until either is done; a request that
/// couldn't be read is answered with why.
pub fn run_command(
    request: Result<StartRequest, String>,
    mut connection: impl Read,
    writer: impl Write + Send + 'static,
    launch: LaunchFor,
) {
    let host = Host::new(writer);
    let started = request.and_then(with_agent_program).and_then(|request| {
        let launched = launch(&request)?;
        Session::start(&request, launched, host.clone())
    });
    match started {
        Ok(session) => follow_host(&mut connection, session),
        Err(message) => host.send(&Frame::failed(&message)),
    }
}

/// A request for `hangar-agent` gets this agent's own program, by its full path, in its place.
fn with_agent_program(mut request: StartRequest) -> Result<StartRequest, String> {
    let Some(program) = request.command.first_mut() else {
        return Ok(request);
    };
    if program != AGENT_COMMAND {
        return Ok(request);
    }

    *program = agent_program()?;
    Ok(request)
}

fn agent_program() -> Result<String, String> {
    let path = std::env::current_exe()
        .map_err(|error| format!("The agent can't find its own program: {error}."))?;
    path.into_os_string()
        .into_string()
        .map_err(|path| format!("The agent's own path isn't UTF-8: {}.", path.display()))
}

/// Hands the host's input and terminal sizes to the command until the host goes away, then ends
/// the command if it still runs.
///
/// Input is written straight to the command, so a command that doesn't read it stops the host
/// from sending more; the host leaving is then noticed once the command reads again or exits.
fn follow_host(connection: &mut impl Read, mut session: Session) {
    while let Ok(Some(frame)) = Frame::read_from(connection) {
        match frame.kind {
            Kind::Input => session.write_input(&frame.payload),
            Kind::Resize => {
                if let Some((columns, rows)) = frame.terminal_size() {
                    session.resize(columns, rows);
                }
            }
            Kind::Start | Kind::Output | Kind::ErrorOutput | Kind::Exit | Kind::Failed => break,
        }
    }

    session.end();
}

#[cfg(test)]
#[cfg(unix)]
#[path = "lib_test.rs"]
mod tests;
