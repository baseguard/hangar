//! The `session` command: the helper in the signed-in user's session that runs the clipboard and
//! `hangar exec`'s commands.

use std::{
    fs::{self, File},
    io,
    path::PathBuf,
    time::Duration,
};

use super::{clipboard, exec};
use hangar_error::{Error, Result};
use hangar_fs::Dir;
use hangar_sys_windows::{
    self as sys,
    instance::{NamedEvent, NamedMutex},
};

const HELPER_NAME: &str = "io.baseguard.hangar.session";
/// How soon the clipboard follows the user at the screen, or a port another program let go of.
const CLIPBOARD_CHECK: Duration = Duration::from_millis(500);
const TAKE_OVER_TIMEOUT: Duration = Duration::from_secs(30);
const LOG_FILE: &str = "agent.log";

struct HelperInstance {
    quit: NamedEvent,
    /// The mutex this helper owns while it runs; ending the process lets go of it.
    _owner: NamedMutex,
}

pub fn run() -> Result<()> {
    let helper = take_over(HELPER_NAME).map_err(cannot_start)?;
    send_failures_to_log_file();

    // The clipboard window needs this thread's messages flowing, so the wait between checks is
    // its message loop too.
    let clipboard = clipboard::start()?;
    start_exec();

    while !helper.quit.signaled_within(CLIPBOARD_CHECK) {
        clipboard.keep_connected();
    }

    Ok(())
}

/// Without its thread the helper goes on, with no `hangar exec`.
fn start_exec() {
    let started = std::thread::Builder::new()
        .name("exec".into())
        .spawn(exec::follow_service);
    hangar_error::note_failure("hangar exec can't run commands for this user", started);
}

fn take_over(name: &str) -> io::Result<HelperInstance> {
    let quit = NamedEvent::open(&format!("Local\\{name}.quit"))?;
    let owner = NamedMutex::open(&format!("Local\\{name}"))?;

    quit.signal()?;

    if !owner.acquire_within(TAKE_OVER_TIMEOUT) {
        return Err(io::Error::other("Another session helper is still running."));
    }

    quit.reset()?;

    Ok(HelperInstance {
        quit,
        _owner: owner,
    })
}

/// The helper has no console, so a person finds its failures in the user's local app data. Only
/// after the take-over, so the helper it replaced has stopped writing. Without the file they go
/// nowhere, as before.
fn send_failures_to_log_file() {
    let _unlogged = open_log_file().and_then(sys::send_stderr_to);
}

fn open_log_file() -> io::Result<File> {
    let local_app_data = std::env::var_os("LOCALAPPDATA").ok_or(io::ErrorKind::NotFound)?;
    let folder = PathBuf::from(local_app_data).join("Hangar");
    fs::create_dir_all(&folder)?;

    Dir::open(&folder)?.open_log(LOG_FILE, hangar_fs::LOG_LIMIT)
}

fn cannot_start(error: io::Error) -> Error {
    Error::step("start the session helper", error)
}
