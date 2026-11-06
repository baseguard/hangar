//! `hangar-agent take`: the host runs it through `hangar exec`, as the user at the screen, with
//! the dropped files as a tar archive on stdin, and it places them in the `HangarDrop` folder in
//! that user's home. The home comes from the account, not from HOME: a command `hangar exec`
//! starts has only a plain login environment, and the account is what the user's own sessions use
//! too.

#[cfg(any(target_os = "macos", windows))]
use std::process::{Command, Stdio};
use std::{
    fs,
    io::{self, Read},
    path::Path,
};

use hangar_error::{Error, Result};
use hangar_fs::Dir;

use crate::{copy_in, home, open_real_folder, report_skipped};

const DROP_FOLDER: &str = "HangarDrop";

/// Places the archive on stdin in `HangarDrop`, then shows the folder.
pub fn take() -> Result<()> {
    let home = home().map_err(|error| Error::step("find your home folder", error))?;
    let folder = home.join(DROP_FOLDER);

    let skipped = take_into(&folder, io::stdin().lock())?;
    report_skipped(skipped);

    show_folder(&folder);
    Ok(())
}

/// Every top item of the archive in `input` goes into `folder`, made if missing, under a name
/// nothing there had; how many links and special files it left out.
fn take_into(folder: &Path, input: impl Read) -> Result<usize> {
    let label = folder.display().to_string();
    let opened = open_or_make(folder).map_err(|error| Error::file("open", &label, error))?;

    copy_in::extract_items(opened, &label, input)
}

fn open_or_make(folder: &Path) -> io::Result<Dir> {
    fs::create_dir_all(folder)?;
    open_real_folder(folder)
}

/// Best effort and never waited for: the files are in place whether or not a window shows them.
#[cfg(any(target_os = "macos", windows))]
fn show_folder(folder: &Path) {
    let shown = folder_viewer()
        .arg(folder)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    hangar_error::note_failure("the files are in place anyway", shown);
}

/// `hangar exec` runs commands in the user's own login session through `launchctl asuser`, so
/// `open` reaches their Finder.
#[cfg(target_os = "macos")]
fn folder_viewer() -> Command {
    Command::new("/usr/bin/open")
}

/// The session helper runs commands on the user's desktop.
#[cfg(windows)]
fn folder_viewer() -> Command {
    Command::new("explorer.exe")
}

/// Not on Linux: `hangar exec` starts commands with none of the desktop session's variables
/// (`DISPLAY`, `WAYLAND_DISPLAY`, the session bus), so `xdg-open` can't reach the file manager.
#[cfg(target_os = "linux")]
fn show_folder(_folder: &Path) {}

#[cfg(all(test, unix))]
#[path = "drop_test.rs"]
mod tests;
