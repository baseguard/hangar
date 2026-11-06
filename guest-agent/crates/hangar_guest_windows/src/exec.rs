//! The session helper's end of `hangar exec`: it runs the commands the service hands it, one per
//! pipe, as the user signed in at the screen.

use std::{
    io::{self, Read, Write},
    path::PathBuf,
    sync::Arc,
    thread::{self, sleep},
    time::Duration,
};

use hangar_exec::Launch;
use hangar_exec_frames::StartRequest;
use hangar_sys_windows::channel::Channel;

use super::{exec_relay::EXEC_PIPE, is_at_the_screen, policy};

const RETRY: Duration = Duration::from_secs(5);
/// Shorter than the service's wait for the next pipe, so a command started after a lost pipe still
/// finds one.
const PIPE_LOST_PAUSE: Duration = Duration::from_secs(1);

/// While this user has the screen, keeps one pipe to the service waiting for a command; each
/// command runs on a thread of its own, and the next pipe opens once the last one got its command.
pub(crate) fn follow_service() {
    loop {
        let Some(pipe) = is_at_the_screen().then(open_service_pipe).flatten() else {
            sleep(RETRY);
            continue;
        };

        let pipe = Arc::new(pipe);
        let mut reader = PipeEnd(Arc::clone(&pipe));
        let request = hangar_exec::read_start(&mut reader);
        let got_no_command = request.is_err();
        let started = thread::Builder::new()
            .name("exec".into())
            .spawn(move || hangar_exec::run_command(request, reader, PipeEnd(pipe), launch));
        // A service that drops pipes, or a thread that won't start, isn't asked again at once.
        if got_no_command || started.is_err() {
            sleep(PIPE_LOST_PAUSE);
        }
    }
}

/// A pipe of the same name made by anyone but the SYSTEM service could hand out commands.
fn open_service_pipe() -> Option<Channel> {
    let pipe = Channel::open(EXEC_PIPE).ok()?;
    policy::served_by_system(&pipe).then_some(pipe)
}

/// Commands start in the user's profile folder, as in a new terminal.
fn launch(_request: &StartRequest) -> Result<Launch, String> {
    let folder = std::env::var_os("USERPROFILE")
        .map(PathBuf::from)
        .ok_or("The session helper doesn't know the user's profile folder.")?;
    Ok(Launch { folder })
}

/// The service's pipe as a stream; reads and writes may come from different threads.
struct PipeEnd(Arc<Channel>);

impl Read for PipeEnd {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        self.0.read(buffer)
    }
}

impl Write for PipeEnd {
    fn write(&mut self, data: &[u8]) -> io::Result<usize> {
        self.0.write_all(data)?;
        Ok(data.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
