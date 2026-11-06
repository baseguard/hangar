//! `update --sha256 <hex>`, which Hangar runs as root through `hangar exec` and `sudo`.
//!
//! Root installs only bytes with the hash Hangar gave for the agent it copied in. `install` restarts
//! the exec service, and systemd ends every process of a service it restarts, so `install` runs as a
//! unit of its own, and this returns once that unit started.

use std::{
    fs,
    process::{Command, Stdio},
};

use hangar_error::Error;
use hangar_sha256::Sha256;

use crate::install::{THIS_PROGRAM, run_program, write_root_file};

/// Root's own copy, so nothing the user can write runs as root. Not in /run, which Debian and
/// Ubuntu mount without exec rights.
pub(crate) const UPDATE_PROGRAM: &str = "/usr/local/libexec/hangar-agent-update";
const UPDATE_PROGRAM_MODE: u32 = 0o700;
const UPDATE_UNIT: &str = "hangar-agent-update.service";

pub fn run(copied_agent: Sha256) -> hangar_error::Result<()> {
    if !hangar_sys_unix::is_root() {
        return Err(Error::Plain(
            "hangar-agent update needs root: run it with sudo.",
        ));
    }

    if is_update_running() {
        return Err(Error::Plain(
            "An update of Hangar's agent is already running.",
        ));
    }

    copy_this_program_for_root(copied_agent)?;
    forget_failed_update_unit();
    start_install_unit()
}

fn is_update_running() -> bool {
    Command::new(crate::system_program("systemctl"))
        .args(["is-active", "--quiet", UPDATE_UNIT])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

/// `--collect` unloads a finished unit, but not one whose `systemd-run` was killed while it
/// started; a unit that isn't there is no matter.
fn forget_failed_update_unit() {
    let _reset = Command::new(crate::system_program("systemctl"))
        .args(["reset-failed", UPDATE_UNIT])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

/// Writes the very bytes it checked, so a cut-off or changed copy is never installed. A swap
/// before sudo started this copy can't be seen: /proc/self/exe is the copy itself.
fn copy_this_program_for_root(copied_agent: Sha256) -> hangar_error::Result<()> {
    let program =
        fs::read(THIS_PROGRAM).map_err(|error| Error::step("read this program", error))?;
    if Sha256::of(&program) != copied_agent {
        return Err(Error::CopiedAgentChanged);
    }

    write_root_file(UPDATE_PROGRAM, &program, UPDATE_PROGRAM_MODE)
}

/// systemd-run returns once the unit started; `--collect` unloads it afterwards even when it
/// failed, so the next update can use the same name.
fn start_install_unit() -> hangar_error::Result<()> {
    run_program(
        &crate::system_program("systemd-run"),
        &install_unit_arguments(UPDATE_PROGRAM),
    )
}

fn install_unit_arguments(program: &str) -> [&str; 6] {
    [
        "--collect",
        "--quiet",
        "--unit",
        UPDATE_UNIT,
        program,
        "install",
    ]
}

#[cfg(test)]
#[path = "update_test.rs"]
mod tests;
