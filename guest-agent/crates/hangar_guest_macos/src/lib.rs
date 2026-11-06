//! The agent on macOS guests: a per-user process that launchd keeps running in each session, and a
//! system part that launchd runs as root.

#![cfg(target_os = "macos")]
#![forbid(unsafe_code)]

pub mod agent;
mod clipboard;
pub mod install;
pub mod report;
mod trust;
mod zshenv;

use std::{
    fs::{self, File},
    io,
};

use hangar_fs::Dir;
use hangar_sys_macos as macos;

/// launchd sends stderr nowhere, so a person finds the failures in `folder`. Without the file they
/// go nowhere, as before.
fn send_failures_to_log_file(folder: &str, file: &str) {
    let _unlogged = open_log_file(folder, file).and_then(|log| macos::send_stderr_to(&log));
}

fn open_log_file(folder: &str, file: &str) -> io::Result<File> {
    fs::create_dir_all(folder)?;
    Dir::open(folder)?.open_log(file, hangar_fs::LOG_LIMIT)
}

/// Every signed-in user runs this agent; only the one at the screen may use the clipboard. Nobody
/// is at the screen while the login window shows.
fn is_at_the_screen() -> bool {
    macos::console_user_id() == Some(hangar_sys_unix::user_id())
}
