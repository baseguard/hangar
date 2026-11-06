//! Starting a command on Windows, as the session helper's own user: in a pseudo console with `-t`,
//! else with pipes; either way in a job, so a close ends it with everything it started.

use std::{
    io::{self, Read, Write},
    os::windows::{io::AsRawHandle, process::CommandExt},
    path::Path,
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex, PoisonError},
};

use hangar_exec_frames::{Kind, StartRequest};
use hangar_sys_windows::{
    UserEnvironment, command_line_of,
    exec::{self, Job, PseudoConsole},
};

use crate::{
    Launch,
    session::{Streams, take_pipes},
};

/// What a command that couldn't be waited for exits with.
const UNKNOWN_EXIT: i32 = 255;
/// `CREATE_NO_WINDOW`: a console program started with pipes gets no console window of its own.
const NO_WINDOW: u32 = 0x0800_0000;

/// The command's pseudo console, until the command ended.
type Console = Arc<Mutex<Option<PseudoConsole>>>;

#[derive(Debug)]
pub(crate) enum Process {
    InConsole(exec::Process, Console),
    Piped(Child),
}

impl Process {
    /// Windows exit codes are unsigned; the frame carries the same 32 bits. A command's pseudo
    /// console is closed once it ended, which ends the console's output.
    pub(crate) fn wait(self) -> i32 {
        let code = match self {
            Process::InConsole(process, console) => {
                let code = process.wait().map(u32::cast_signed);
                let closed = lock(&console).take();
                drop(closed);
                code
            }
            Process::Piped(mut child) => child
                .wait()
                .map(|status| status.code().unwrap_or(UNKNOWN_EXIT)),
        };
        code.unwrap_or(UNKNOWN_EXIT)
    }
}

/// What the session keeps to end or resize the command.
#[derive(Debug)]
pub(crate) struct Control {
    job: Job,
    /// `None` without a terminal.
    console: Option<Console>,
}

impl Control {
    pub(crate) fn kill(&self) {
        self.job.end();
    }

    pub(crate) fn resize(&self, columns: u16, rows: u16) {
        let Some(console) = &self.console else {
            return;
        };
        if let Some(console) = &*lock(console) {
            let _resized = console.resize(columns, rows);
        }
    }
}

pub(crate) fn spawn(request: &StartRequest, launch: Launch) -> io::Result<Streams> {
    let Launch { folder } = launch;
    let environment = UserEnvironment::now()?;
    let job = Job::new()?;

    if request.tty {
        spawn_in_console(request, &folder, &environment, job)
    } else {
        spawn_with_pipes(request, &folder, &environment, job)
    }
}

fn spawn_in_console(
    request: &StartRequest,
    folder: &Path,
    environment: &UserEnvironment,
    job: Job,
) -> io::Result<Streams> {
    let program = exec::start_in_console(
        &command_line_of(&request.command),
        folder,
        environment,
        request.columns,
        request.rows,
        &job,
    )?;

    let input: Box<dyn Write + Send> = Box::new(program.input);
    let output: Box<dyn Read + Send> = Box::new(program.output);
    let console = Arc::new(Mutex::new(Some(program.console)));
    Ok(Streams {
        process: Process::InConsole(program.process, Arc::clone(&console)),
        control: Control {
            job,
            console: Some(console),
        },
        input: Some(input),
        outputs: vec![(Kind::Output, output)],
    })
}

fn spawn_with_pipes(
    request: &StartRequest,
    folder: &Path,
    environment: &UserEnvironment,
    job: Job,
) -> io::Result<Streams> {
    let input = if request.interactive {
        Stdio::piped()
    } else {
        Stdio::null()
    };
    let mut child = Command::new(request.program())
        .args(request.arguments())
        .current_dir(folder)
        .env_clear()
        .envs(environment.variables())
        .creation_flags(NO_WINDOW)
        .stdin(input)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    // A program it starts in the moment before this joins the job outlives a close.
    if let Err(error) = job.add(child.as_raw_handle()) {
        let _killed = child.kill();
        return Err(error);
    }

    let (input, outputs) = take_pipes(&mut child);
    Ok(Streams {
        process: Process::Piped(child),
        control: Control { job, console: None },
        input,
        outputs,
    })
}

fn lock(console: &Console) -> std::sync::MutexGuard<'_, Option<PseudoConsole>> {
    console.lock().unwrap_or_else(PoisonError::into_inner)
}
