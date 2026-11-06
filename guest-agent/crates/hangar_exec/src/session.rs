//! The command a connection started: its input, and the threads that carry its output and exit
//! code back. Starting the command is each system's own (`spawn_unix`, `spawn_windows`).

use std::{
    io::{self, Read, Write},
    process::Child,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
        mpsc::{self, Receiver, RecvTimeoutError},
    },
    thread,
    time::Duration,
};

use hangar_exec_frames::{Frame, Kind, StartRequest};

#[cfg(unix)]
use crate::spawn_unix::{Control, Process, spawn};
#[cfg(windows)]
use crate::spawn_windows::{Control, Process, spawn};
use crate::{Host, Launch};

const OUTPUT_CHUNK: usize = 16 * 1024;
/// How long the outputs may stay open after the command ended before the exit code goes, so a
/// background process that keeps writing to them doesn't hold it back. Time an output spends
/// waiting for a host that reads slowly doesn't count, so output already read is never overtaken
/// by the exit.
const OUTPUT_GRACE: Duration = Duration::from_secs(1);
/// How often the exit thread looks whether an output waits for the host.
const GRACE_STEP: Duration = Duration::from_millis(50);

/// The command's standard input; `None` for a command that takes none.
pub(crate) type Input = Option<Box<dyn Write + Send>>;
/// The command's outputs, each with the kind of frame that carries it.
pub(crate) type Outputs = Vec<(Kind, Box<dyn Read + Send>)>;

pub(crate) struct Session {
    /// `None` once the input ended, or for a command that takes none.
    input: Input,
    control: Control,
    /// Set once the command was waited for, so ending the session doesn't reach a process whose id
    /// was given again.
    has_exited: Arc<AtomicBool>,
}

/// The command's ends, as the agent holds them after the start.
pub(crate) struct Streams {
    pub(crate) process: Process,
    pub(crate) control: Control,
    pub(crate) input: Input,
    pub(crate) outputs: Outputs,
}

/// The pipes of a command started with `Stdio::piped`, taken out of the child.
pub(crate) fn take_pipes(child: &mut Child) -> (Input, Outputs) {
    let input = child
        .stdin
        .take()
        .map(|stdin| Box::new(stdin) as Box<dyn Write + Send>);
    let mut outputs: Outputs = Vec::new();
    if let Some(stdout) = child.stdout.take() {
        outputs.push((Kind::Output, Box::new(stdout)));
    }
    if let Some(stderr) = child.stderr.take() {
        outputs.push((Kind::ErrorOutput, Box::new(stderr)));
    }
    (input, outputs)
}

impl Session {
    pub(crate) fn start(
        request: &StartRequest,
        launch: Launch,
        host: Host,
    ) -> Result<Session, String> {
        let program = request.program();
        let Streams {
            process,
            control,
            input,
            outputs,
        } = spawn(request, launch)
            .map_err(|error| format!("Could not start {program}: {error}."))?;

        let has_exited = Arc::new(AtomicBool::new(false));
        match carry(process, outputs, host, Arc::clone(&has_exited)) {
            Ok(()) => Ok(Session {
                input,
                control,
                has_exited,
            }),
            Err(error) => {
                control.kill();
                Err(format!("Could not follow {program}: {error}."))
            }
        }
    }

    /// An empty input ends the command's input; input the command no longer takes is dropped.
    pub(crate) fn write_input(&mut self, bytes: &[u8]) {
        let Some(input) = &mut self.input else {
            return;
        };
        if bytes.is_empty() || input.write_all(bytes).is_err() {
            self.input = None;
        }
    }

    pub(crate) fn resize(&self, columns: u16, rows: u16) {
        self.control.resize(columns, rows);
    }

    /// Ends the command, with everything it started, unless it already exited.
    pub(crate) fn end(self) {
        if !self.has_exited.load(Ordering::Acquire) {
            self.control.kill();
        }
    }
}

/// Starts the threads that move the command's output and exit code.
fn carry(
    process: Process,
    outputs: Outputs,
    host: Host,
    has_exited: Arc<AtomicBool>,
) -> io::Result<()> {
    let (reader_end, reader_ends) = mpsc::channel();
    let readers = outputs.len();
    let sending = Arc::new(AtomicUsize::new(0));
    for (kind, reader) in outputs {
        let host = host.clone();
        let reader_end = reader_end.clone();
        let sending = Arc::clone(&sending);
        thread::Builder::new()
            .name("exec output".into())
            .spawn(move || {
                forward_output(kind, reader, &host, &sending);
                let _sent = reader_end.send(());
            })?;
    }

    thread::Builder::new()
        .name("exec exit".into())
        .spawn(move || {
            let code = process.wait();
            has_exited.store(true, Ordering::Release);
            wait_for_output(&reader_ends, readers, &sending);
            host.send(&Frame::exit(code));
        })?;
    Ok(())
}

fn forward_output(
    kind: Kind,
    mut reader: Box<dyn Read + Send>,
    host: &Host,
    sending: &AtomicUsize,
) {
    let mut chunk = vec![0; OUTPUT_CHUNK];
    loop {
        let count = match reader.read(&mut chunk) {
            Ok(0) => return,
            Ok(count) => count,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            // A terminal whose command and its children are gone reads as an error on Linux.
            Err(_) => return,
        };
        if let Some(frame) = Frame::new(kind, chunk[..count].to_vec()) {
            sending.fetch_add(1, Ordering::AcqRel);
            host.send(&frame);
            sending.fetch_sub(1, Ordering::AcqRel);
        }
    }
}

/// Until every output has ended, or `OUTPUT_GRACE` has passed in steps where no output was
/// waiting for the host.
fn wait_for_output(reader_ends: &Receiver<()>, readers: usize, sending: &AtomicUsize) {
    let mut ended = 0;
    let mut grace_used = Duration::ZERO;
    while ended < readers && grace_used < OUTPUT_GRACE {
        match reader_ends.recv_timeout(GRACE_STEP) {
            Ok(()) => ended += 1,
            Err(RecvTimeoutError::Timeout) => {
                if sending.load(Ordering::Acquire) == 0 {
                    grace_used += GRACE_STEP;
                }
            }
            Err(RecvTimeoutError::Disconnected) => return,
        }
    }
}
