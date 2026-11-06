//! `update --sha256 <hex>`, which Hangar runs through `hangar exec` as the user at the screen, with
//! the user's password as the one line on stdin when it has one.
//!
//! Root runs only its own copy of the agent, and only once root has checked its hash: any program
//! running as this user can change the user's copy up to the moment root would run it. Putting the
//! system part in place restarts the daemon that runs `hangar exec`'s commands, so `sudo` runs that
//! last step detached, in a session of its own; the rest is done before `update` returns.

use std::{
    fs,
    io::{self, BufRead, Read},
    os::unix::fs::MetadataExt,
    process::Stdio,
};

use hangar_error::{Error, Result};
use hangar_sha256::Sha256;

use super::{
    HELPER_FOLDER, copy_agent_into_place, home, installed_agent, read_this_program, start_agent,
    sudo::PipedSudo,
};

/// Root's copy for the update; `install-daemon` removes it once the system part is in place.
pub(super) const ROOT_COPY: &str =
    "/Library/PrivilegedHelperTools/io.baseguard.hangar.guest-daemon.update";
const LOG_FOLDER: &str = "Library/Logs/Hangar";
const LOG_FILE: &str = "update.log";
/// Longer than any password; more is not read.
const PASSWORD_LINE_LIMIT: u64 = 4096;

/// Checks the password and the copied agent before anything changes, so either one wrong leaves
/// the old agent whole.
pub fn update(copied_agent: Sha256) -> Result<()> {
    let home = home()?;
    let password = read_password_line()?;
    let sudo = PipedSudo::for_update(password.as_deref())?;

    let program = read_this_program()?;
    if Sha256::of(&program) != copied_agent {
        return Err(Error::CopiedAgentChanged);
    }
    copy_agent_into_place(&home, &program)?;
    start_agent(&home)?;

    make_root_copy(&sudo, &installed_agent(&home), copied_agent)?;
    sudo.start_detached(&[ROOT_COPY, "install-daemon"], update_log(&home))
}

/// Root can't run a copy it can't trust: the user's copy could be a link to a file only root may
/// read, so root's copy is root's alone, and in a folder only root can change.
fn make_root_copy(sudo: &PipedSudo, agent: &str, copied_agent: Sha256) -> Result<()> {
    sudo.run(&["/bin/mkdir", "-p", HELPER_FOLDER])?;
    check_only_root_can_write(HELPER_FOLDER)?;
    sudo.run(&[
        "/usr/bin/install",
        "-o",
        "root",
        "-g",
        "wheel",
        "-m",
        "700",
        agent,
        ROOT_COPY,
    ])?;

    if hash_as_root(sudo, ROOT_COPY)? != copied_agent {
        remove_root_copy(sudo);
        return Err(Error::CopiedAgentChanged);
    }
    Ok(())
}

/// Root's copy of bytes that aren't the agent Hangar copied in must not stay where root runs it.
fn remove_root_copy(sudo: &PipedSudo) {
    hangar_error::note_failure(
        "root's copy of the changed agent stays behind",
        sudo.run(&["/bin/rm", "-f", ROOT_COPY]),
    );
}

/// A folder the user made, or one others can write, would let the user swap root's copy.
fn check_only_root_can_write(folder: &str) -> Result<()> {
    let metadata =
        fs::symlink_metadata(folder).map_err(|error| Error::file("check", folder, error))?;

    let is_roots_own = metadata.is_dir() && metadata.uid() == 0 && metadata.mode() & 0o022 == 0;
    if !is_roots_own {
        return Err(Error::file(
            "use",
            folder,
            "it should be a folder only root can change",
        ));
    }
    Ok(())
}

/// `shasum` prints the hash, then the path.
fn hash_as_root(sudo: &PipedSudo, path: &str) -> Result<Sha256> {
    let printed = sudo.output(&["/usr/bin/shasum", "-a", "256", path])?;
    let hex = printed.split_whitespace().next().unwrap_or_default();

    Sha256::from_hex(hex).ok_or(Error::Plain("shasum didn't print a SHA-256 hash."))
}

/// Nobody watches the detached step, so what it prints goes to the user's log folder; without the
/// file it goes nowhere.
fn update_log(home: &str) -> Stdio {
    match crate::open_log_file(&format!("{home}/{LOG_FOLDER}"), LOG_FILE) {
        Ok(log) => Stdio::from(log),
        Err(_unopened) => Stdio::null(),
    }
}

fn read_password_line() -> Result<Option<String>> {
    let mut line = String::new();
    io::stdin()
        .lock()
        .take(PASSWORD_LINE_LIMIT)
        .read_line(&mut line)
        .map_err(|error| Error::step("read the password", error))?;

    Ok(password_in_line(&line).map(str::to_string))
}

/// The line without its line ending; `None` for an empty one, which means Hangar has no password.
fn password_in_line(line: &str) -> Option<&str> {
    let without_newline = line.strip_suffix('\n').unwrap_or(line);
    let password = without_newline
        .strip_suffix('\r')
        .unwrap_or(without_newline);

    (!password.is_empty()).then_some(password)
}

#[cfg(test)]
#[path = "update_test.rs"]
mod tests;
