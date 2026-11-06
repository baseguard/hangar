//! The Command Line Tools, installed through Software Update the way `xcode-select --install` does.

use std::{
    fs::{self, OpenOptions},
    os::unix::fs::OpenOptionsExt,
    process::{Command, Stdio},
    thread::sleep,
    time::Duration,
};

use hangar_error::{Error, Result};

use super::{clean_up, say, succeeds_quietly, sudo::PipedSudo};

/// While this file exists, `softwareupdate -l` lists the Command Line Tools. It is the file
/// `xcode-select --install` creates for the same purpose.
const TOOLS_MARKER: &str = "/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress";
const TOOLS_LIST_ATTEMPTS: u32 = 20;
/// The listing can take minutes to include the tools.
const TOOLS_LIST_PAUSE: Duration = Duration::from_secs(30);

/// `xcode-select -p` names the Command Line Tools folder only when they are installed.
pub(super) fn has_command_line_tools() -> bool {
    succeeds_quietly("/usr/bin/xcode-select", &["-p"])
}

pub(super) fn install_command_line_tools(sudo: &PipedSudo) -> Result<()> {
    say("Installing the Command Line Tools");

    let marked = mark_tools_wanted(TOOLS_MARKER);

    let installed = install_listed_tools(sudo);

    if marked {
        clean_up(fs::remove_file(TOOLS_MARKER));
    }

    installed
}

/// Only a marker made here is removed later, and a link another user planted in `/tmp` is never
/// followed or truncated.
pub(super) fn mark_tools_wanted(marker: &str) -> bool {
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .custom_flags(libc::O_NOFOLLOW)
        .mode(0o644)
        .open(marker)
        .is_ok()
}

fn install_listed_tools(sudo: &PipedSudo) -> Result<()> {
    let label = wait_for_tools_label()?;

    sudo.run_showing_output(&["/usr/sbin/softwareupdate", "-i", &label])
}

fn wait_for_tools_label() -> Result<String> {
    for attempt in 1..=TOOLS_LIST_ATTEMPTS {
        let list = software_update_list();
        if let Some(label) = command_line_tools_label(&list) {
            return Ok(label.to_string());
        }

        if attempt < TOOLS_LIST_ATTEMPTS {
            sleep(TOOLS_LIST_PAUSE);
        }
    }

    Err(Error::Plain(
        "Software Update didn't offer the Command Line Tools.",
    ))
}

/// A listing that fails reads as empty and is asked again.
fn software_update_list() -> String {
    let output = Command::new("/usr/sbin/softwareupdate")
        .arg("-l")
        .stderr(Stdio::null())
        .output();

    match output {
        Ok(output) => String::from_utf8_lossy(&output.stdout).into_owned(),
        Err(_) => String::new(),
    }
}

/// The last label is usually the newest.
pub(super) fn command_line_tools_label(list: &str) -> Option<&str> {
    let mut label = None;

    for line in list.lines() {
        if let Some(name) = line.strip_prefix("* Label: ")
            && name.starts_with("Command Line Tools")
        {
            label = Some(name);
        }
    }

    label
}
