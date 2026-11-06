//! `hangar-agent report`: the system service that sends the guest's memory use to the host, shuts
//! the guest down when Hangar asks and puts Hangar's CA and placeholder variables in place.

use std::{
    fs::{File, OpenOptions},
    os::unix::fs::{FileTypeExt, OpenOptionsExt},
    process::{Command, Stdio},
    thread,
};

use hangar_host_commands::{HostCommand, follow_host_port};
use hangar_report::{self as report, Memory};

use crate::{port_path::is_virtio_port_path, screen, trust};

const REPORT_PORT: &str = "/dev/virtio-ports/io.baseguard.hangar.report";
const COMMAND_PORT: &str = "/dev/virtio-ports/io.baseguard.hangar.agent";

const MEMINFO: &str = "/proc/meminfo";

#[derive(Clone, Copy)]
enum Direction {
    FromHost,
    ToHost,
}

pub fn run() -> hangar_error::Result<()> {
    let started = thread::Builder::new()
        .name("host commands".into())
        .spawn(follow_host);
    hangar_error::note_failure("Hangar can't shut this guest down", started);

    report::send(
        || open_port(REPORT_PORT, Direction::ToHost),
        read_memory,
        || Some(has_screen()),
    )
}

/// The cloud kernels of Debian and Ubuntu drive no screen, so the VM's window stays on the boot
/// screen; the host then says so.
fn has_screen() -> bool {
    lists_a_screen("/sys/class/drm") || lists_a_screen("/sys/class/graphics")
}

fn lists_a_screen(folder: &str) -> bool {
    let Ok(entries) = std::fs::read_dir(folder) else {
        return false;
    };
    entries.flatten().any(|entry| {
        entry
            .file_name()
            .to_str()
            .is_some_and(screen::names_a_screen)
    })
}

fn follow_host() {
    follow_host_port(|| open_port(COMMAND_PORT, Direction::FromHost), obey);
}

fn obey(command: HostCommand) {
    match command {
        HostCommand::ShutDown => shut_down(),
        HostCommand::Trust(state) => trust::reconcile(&state),
    }
}

/// GNOME answers the power button with a dialog, so ACPI alone doesn't shut a desktop guest down.
fn shut_down() {
    let systemctl = crate::system_program("systemctl");
    let status = Command::new(&systemctl)
        .arg("poweroff")
        .stdin(Stdio::null())
        .status();
    hangar_error::note_failure(
        "the guest keeps running unless a shutdown is already under way",
        hangar_error::check_exit(systemctl, status),
    );
}

/// The service runs as root, so a port's link must lead to a virtio port device and nothing else.
fn open_port(path: &str, direction: Direction) -> Option<File> {
    let device = std::fs::canonicalize(path).ok()?;
    if !is_virtio_port_path(&device) {
        return None;
    }

    let port = OpenOptions::new()
        .read(matches!(direction, Direction::FromHost))
        .write(matches!(direction, Direction::ToHost))
        .custom_flags(libc::O_NOFOLLOW | libc::O_NOCTTY)
        .open(&device)
        .ok()?;

    let is_device = port.metadata().ok()?.file_type().is_char_device();
    if !is_device {
        return None;
    }
    Some(port)
}

fn read_memory() -> Option<Memory> {
    let meminfo = File::open(MEMINFO).ok()?;
    report::memory_from_meminfo(meminfo)
}
