//! The agent on Windows guests; elsewhere only the pure `policy` module builds, so its tests run
//! on any host.

#![cfg(any(windows, test))]
#![forbid(unsafe_code)]

#[cfg(windows)]
mod clipboard;
#[cfg(windows)]
mod exec;
#[cfg(windows)]
mod exec_relay;
#[cfg(windows)]
mod facts;
#[cfg(windows)]
mod helper_watch;
#[cfg(windows)]
pub mod install;
mod policy;
#[cfg(windows)]
pub mod service;
#[cfg(windows)]
pub mod session;
#[cfg(windows)]
pub mod setup;
#[cfg(windows)]
mod trust;
#[cfg(windows)]
pub mod winpe_install;
mod winpe_plan;

#[cfg(windows)]
use std::{fs, io, path::Path, path::PathBuf};

#[cfg(windows)]
use hangar_error::{Error, Result};
#[cfg(windows)]
use hangar_sys_windows as sys;

#[cfg(windows)]
pub(crate) const SERVICE: &str = "HangarAgent";
#[cfg(windows)]
pub(crate) const BINARY: &str = "hangar-agent.exe";
#[cfg(windows)]
pub(crate) const LOG_FILE: &str = "setup.log";

/// Every signed-in user runs a session helper; only the one on the VM's display may use the
/// clipboard and `hangar exec`.
#[cfg(windows)]
fn is_at_the_screen() -> bool {
    policy::is_console_session(
        sys::channel::current_session_id(),
        sys::channel::console_session_id(),
    )
}

#[cfg(windows)]
pub(crate) fn folder() -> Result<PathBuf> {
    let program_files =
        sys::program_files().map_err(|error| Error::step("find Program Files", error))?;
    Ok(program_files.join("Hangar"))
}

/// Made if missing, then checked: SYSTEM runs the agent from it.
#[cfg(windows)]
pub(crate) fn secure_folder(path: &Path) -> io::Result<()> {
    if let Err(error) = fs::create_dir(path)
        && error.kind() != io::ErrorKind::AlreadyExists
    {
        return Err(error);
    }

    let folder = sys::open_without_following(path)?;
    policy::check_agent_folder(path, &folder)
}

/// A file that couldn't be removed only takes space; nothing reads it.
#[cfg(windows)]
pub(crate) fn keep_leftover_file(removal: io::Result<()>) {
    hangar_error::note_failure("the file stays behind", removal);
}
