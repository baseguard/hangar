//! Grows the system's APFS container into space Hangar added to the disk.
//!
//! When Hangar grows a macOS VM's disk, the host only moves `RecoveryOS` to the new end and writes
//! the partition table; the container is grown here, by the guest's own macOS, so the host never
//! reads the guest's file systems.

use std::{
    io::Write,
    process::{Command, Stdio},
};

use hangar_error::{Error, Exit, Result};

const DISKUTIL: &str = "/usr/sbin/diskutil";
const PLUTIL: &str = "/usr/bin/plutil";
/// Less is left alone: growing first checks the whole container, which takes a while.
const SMALLEST_GROWTH: u64 = 1 << 30;

/// The system part starts once after each boot, so a disk Hangar grew is used from the next start.
pub(crate) fn grow_system_container() {
    hangar_error::note_failure(
        "the system's container keeps its size",
        grow_if_there_is_room(),
    );
}

fn grow_if_there_is_room() -> Result<()> {
    let container = system_container()?;
    let limits = output_of(
        DISKUTIL,
        &["apfs", "resizeContainer", &container, "limits", "-plist"],
        None,
    )?;
    let current = plist_number(&limits, "CurrentSize")?;
    let maximum = plist_number(&limits, "MaximumSize")?;
    if !has_room(current, maximum) {
        return Ok(());
    }

    println!("Growing {container}, the system's container, into the space Hangar added.");
    output_of(
        DISKUTIL,
        &["apfs", "resizeContainer", &container, "0"],
        None,
    )
    .map(|_| ())
}

fn has_room(current: u64, maximum: u64) -> bool {
    maximum.saturating_sub(current) >= SMALLEST_GROWTH
}

/// The container `/` lives in, like `disk3`.
fn system_container() -> Result<String> {
    let info = output_of(DISKUTIL, &["info", "-plist", "/"], None)?;
    let container = plist_text(&info, "APFSContainerReference")?;
    if is_disk_name(&container) {
        Ok(container)
    } else {
        Err(Error::step(
            "find the system's container",
            format!("diskutil named it {container:?}"),
        ))
    }
}

/// `diskN`, the only kind of name passed on to diskutil.
fn is_disk_name(name: &str) -> bool {
    name.strip_prefix("disk").is_some_and(|number| {
        !number.is_empty() && number.bytes().all(|byte| byte.is_ascii_digit())
    })
}

fn plist_number(plist: &[u8], key: &str) -> Result<u64> {
    let text = plist_text(plist, key)?;
    text.parse().map_err(|_not_a_number| {
        Error::step("read the container's size", format!("{key} is {text:?}"))
    })
}

fn plist_text(plist: &[u8], key: &str) -> Result<String> {
    let value = output_of(
        PLUTIL,
        &["-extract", key, "raw", "-o", "-", "-"],
        Some(plist),
    )?;
    Ok(String::from_utf8_lossy(&value).trim().to_string())
}

fn output_of(program: &str, arguments: &[&str], input: Option<&[u8]>) -> Result<Vec<u8>> {
    let mut child = Command::new(program)
        .args(arguments)
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| Error::program(program, Exit::NotStarted(error.to_string())))?;
    // The pipe closes at the end of this block, which tells the tool its input has ended.
    if let (Some(input), Some(mut stdin)) = (input, child.stdin.take()) {
        stdin
            .write_all(input)
            .map_err(|error| Error::step("hand a disk tool its input", error))?;
    }

    let output = child
        .wait_with_output()
        .map_err(|error| Error::step("read a disk tool's output", error))?;
    hangar_error::check_exit(program, Ok(output.status))?;
    Ok(output.stdout)
}

#[cfg(test)]
#[path = "grow_disk_test.rs"]
mod tests;
