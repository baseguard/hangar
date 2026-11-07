//! `hangar-agent cp-out`, `cp-in` and `take`, the guest's side of `hangar cp` and of dropping
//! files into the VM: the host runs them through `hangar exec`, as the user at the screen, and a
//! tar archive moves over the command's stdout or stdin. The host reads and writes the same archive
//! format; a change to it goes in both. `ls` lists one folder the same way, for browsing.

#![forbid(unsafe_code)]

mod copy_in;
mod copy_out;
mod drop;
mod entry_name;
mod list;
mod tar_reader;
mod tar_writer;
#[cfg(test)]
#[path = "lib_test.rs"]
mod tests;

use std::{
    fs, io,
    path::{Path, PathBuf},
};

use hangar_error::Error;
use hangar_fs::Dir;

pub use drop::take;

/// The modes the archive's entries are written and placed with: the host's own ids and bits mean
/// nothing in the guest.
const FOLDER_MODE: u32 = 0o755;
const EXECUTABLE_MODE: u32 = 0o755;
const FILE_MODE: u32 = 0o644;

/// Writes the archive of the file or folder at `path` to stdout.
pub fn copy_out(path: &str) -> hangar_error::Result<()> {
    let skipped = copy_out::write_archive(path, io::stdout().lock())?;
    report_skipped(skipped);
    Ok(())
}

/// Places the archive on stdin at `destination`.
pub fn copy_in(destination: &str) -> hangar_error::Result<()> {
    let skipped = copy_in::extract_archive(destination, io::stdin().lock())?;
    report_skipped(skipped);
    Ok(())
}

/// Writes the listing of the folder at `path` to stdout as JSON; a relative path, or none, starts
/// at the user's home.
pub fn list_folder(path: Option<&str>) -> hangar_error::Result<()> {
    let home = home().map_err(|error| Error::step("find your home folder", error))?;
    let folder = list::folder_path(&home, path)?;

    let listing = list::read_listing(&folder, list::MOST_ENTRIES)?;
    list::write_listing(&listing, io::stdout().lock())
}

/// The host shows this line as it is.
fn report_skipped(skipped: usize) {
    if skipped > 0 {
        eprintln!("skipped {skipped} links or special files");
    }
}

/// The user's own path may go through links, such as macOS's /tmp; only the archive's entries,
/// inside the folder opened here, may not.
fn open_real_folder(path: &Path) -> io::Result<Dir> {
    Dir::open(fs::canonicalize(path)?)
}

/// The home comes from the account, not from HOME: a command `hangar exec` starts has only a plain
/// login environment, and the account is what the user's own sessions use too.
#[cfg(unix)]
fn home() -> io::Result<PathBuf> {
    let account = hangar_sys_unix::current_account().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            "this user isn't in the password database",
        )
    })?;
    Ok(PathBuf::from(account.home))
}

#[cfg(windows)]
fn home() -> io::Result<PathBuf> {
    hangar_sys_windows::profile()
}
