//! Starting a command on macOS and Linux: in a terminal or with pipes, in a session of its own.

use std::{
    fs::File,
    io::{self, Read, Write},
    os::unix::process::ExitStatusExt,
    process::{Child, Command, Stdio},
};

use hangar_exec_frames::{Kind, StartRequest};
use hangar_sys_unix::{
    Account, give_terminal_to, kill_session, open_pty, set_terminal_size, start_in_own_session,
};

use crate::{
    Launch,
    session::{Streams, take_pipes},
};

/// What a command that couldn't be waited for exits with.
const UNKNOWN_EXIT: i32 = 255;

#[derive(Debug)]
pub(crate) struct Process(Child);

impl Process {
    /// A command ended by a signal exits with 128 and the signal's number, as in a shell.
    pub(crate) fn wait(mut self) -> i32 {
        let Ok(status) = self.0.wait() else {
            return UNKNOWN_EXIT;
        };
        status
            .code()
            .or_else(|| status.signal().map(|signal| 128 + signal))
            .unwrap_or(UNKNOWN_EXIT)
    }
}

/// What the session keeps to end or resize the command.
#[derive(Debug)]
pub(crate) struct Control {
    pid: u32,
    /// The terminal's controller; `None` without a terminal.
    terminal: Option<File>,
}

impl Control {
    pub(crate) fn kill(&self) {
        kill_session(self.pid);
    }

    pub(crate) fn resize(&self, columns: u16, rows: u16) {
        if let Some(terminal) = &self.terminal {
            let _resized = set_terminal_size(terminal, columns, rows);
        }
    }
}

pub(crate) fn spawn(request: &StartRequest, launch: Launch) -> io::Result<Streams> {
    let Launch {
        command,
        account,
        switches_user,
    } = launch;
    let switch_to = switches_user.then_some(&account);

    if request.tty {
        spawn_in_terminal(command, request, account.uid, switch_to)
    } else {
        spawn_with_pipes(command, request.interactive, switch_to)
    }
}

/// The command gets the terminal as its standard input, output and error; the agent keeps the
/// controller, which carries both the output and the input.
fn spawn_in_terminal(
    mut command: Command,
    request: &StartRequest,
    uid: u32,
    switch_to: Option<&Account>,
) -> io::Result<Streams> {
    let pty = open_pty(request.columns, request.rows)?;
    give_terminal_to(&pty.terminal, uid)?;
    command
        .stdin(pty.terminal.try_clone()?)
        .stdout(pty.terminal.try_clone()?)
        .stderr(pty.terminal);
    start_in_own_session(&mut command, true, switch_to)?;
    let child = command.spawn()?;
    // Drops this process's copies of the terminal, so the controller sees the command's end.
    drop(command);

    let output: Box<dyn Read + Send> = Box::new(pty.controller.try_clone()?);
    let input: Box<dyn Write + Send> = Box::new(pty.controller.try_clone()?);
    Ok(Streams {
        control: Control {
            pid: child.id(),
            terminal: Some(pty.controller),
        },
        process: Process(child),
        input: Some(input),
        outputs: vec![(Kind::Output, output)],
    })
}

fn spawn_with_pipes(
    mut command: Command,
    interactive: bool,
    switch_to: Option<&Account>,
) -> io::Result<Streams> {
    let input = if interactive {
        Stdio::piped()
    } else {
        Stdio::null()
    };
    command
        .stdin(input)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    start_in_own_session(&mut command, false, switch_to)?;
    let mut child = command.spawn()?;

    let (input, outputs) = take_pipes(&mut child);
    Ok(Streams {
        control: Control {
            pid: child.id(),
            terminal: None,
        },
        process: Process(child),
        input,
        outputs,
    })
}
