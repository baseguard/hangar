//! `report`: the system part, which launchd runs as root. It reports the guest's memory, obeys
//! the host's commands and runs `hangar exec`'s, also at the login window when nobody is signed in.

use std::{
    fs::{File, OpenOptions},
    os::unix::fs::{FileTypeExt, OpenOptionsExt},
    process::{Command, Stdio},
    thread,
};

use hangar_exec::{Launch, choose_account, user_command};
use hangar_exec_frames::StartRequest;
use hangar_host_commands::{HostCommand, follow_host_port};
use hangar_report::{self as report, Memory};
use hangar_sys_macos as macos;
use hangar_sys_unix::{account_named, account_with_id};

const REPORT_PORT: &str = "/dev/tty.io.baseguard.hangar.report";
const COMMAND_PORT: &str = "/dev/tty.io.baseguard.hangar.agent";
const LAUNCHCTL: &str = "/bin/launchctl";
const SUDO: &str = "/usr/bin/sudo";
/// Homebrew's folders first, as its shell setup puts them.
const EXEC_PATH: &str =
    "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
const SHUTDOWN: &str = "/sbin/shutdown";
const LOG_FOLDER: &str = "/Library/Logs/Hangar";
const LOG_FILE: &str = "daemon.log";

#[derive(Clone, Copy)]
enum Direction {
    FromHost,
    ToHost,
}

pub fn run() -> hangar_error::Result<()> {
    super::send_failures_to_log_file(LOG_FOLDER, LOG_FILE);

    let started = thread::Builder::new()
        .name("host commands".into())
        .spawn(follow_host);
    hangar_error::note_failure("Hangar can't shut this guest down", started);

    let started = thread::Builder::new()
        .name("exec".into())
        .spawn(follow_exec);
    hangar_error::note_failure("hangar exec can't run commands in this guest", started);

    report::send(
        || open_port(REPORT_PORT, Direction::ToHost),
        memory,
        || None,
    )
}

fn follow_host() {
    follow_host_port(|| open_port(COMMAND_PORT, Direction::FromHost), obey);
}

fn follow_exec() {
    hangar_exec::serve(launch);
}

/// The user at the screen gets the command in their own login session, through `launchctl
/// asuser`, so it reaches their keychain and apps; the VM's account at the login window has no
/// session to join. `sudo -u` switches the user and keeps the environment `user_command` sets.
fn launch(request: &StartRequest) -> Result<Launch, String> {
    let at_screen = macos::console_user_id().and_then(account_with_id);
    let screen_uid = at_screen.as_ref().map(|account| account.uid);
    let account = choose_account(at_screen, request.fallback_user.as_deref(), account_named)?;

    let mut arguments = Vec::new();
    let program = if screen_uid == Some(account.uid) {
        arguments.extend(["asuser".into(), account.uid.to_string(), SUDO.into()]);
        LAUNCHCTL
    } else {
        SUDO
    };
    arguments.extend(["-u".into(), account.name.clone(), "-H".into(), "--".into()]);
    arguments.extend(request.command.iter().cloned());

    let command = user_command(program, &arguments, &account, EXEC_PATH, request.tty);
    Ok(Launch {
        command,
        account,
        switches_user: false,
    })
}

fn obey(command: HostCommand) {
    match command {
        HostCommand::ShutDown => shut_down(),
        HostCommand::Trust(state) => super::trust::reconcile(&state),
    }
}

/// Like Linux's `systemctl poweroff`: Hangar's stop turns the guest off. Asking loginwindow
/// instead would let an app's save dialog hold the shutdown and needs an Automation prompt.
fn shut_down() {
    let status = Command::new(SHUTDOWN)
        .args(["-h", "now"])
        .stdin(Stdio::null())
        .status();
    hangar_error::note_failure(
        "the guest keeps running unless a shutdown is already under way",
        hangar_error::check_exit(SHUTDOWN, status),
    );
}

/// The ports are in devfs, where nobody can plant a link. A port that stays cooked isn't used: the
/// line discipline would echo and change the bytes.
fn open_port(path: &str, direction: Direction) -> Option<File> {
    let mut options = OpenOptions::new();
    match direction {
        Direction::FromHost => options.read(true),
        Direction::ToHost => options.write(true),
    };

    // O_NOCTTY: the port must not become the daemon's controlling terminal.
    let port = options
        .custom_flags(libc::O_NOFOLLOW | libc::O_NOCTTY | libc::O_CLOEXEC)
        .open(path)
        .ok()?;

    if !port.metadata().ok()?.file_type().is_char_device() {
        return None;
    }

    macos::make_exclusive(&port).ok()?;
    macos::make_raw(&port).ok()?;

    Some(port)
}

/// The guest's memory, with "used" counted like Activity Monitor's "Memory Used": app memory
/// (anonymous pages that can't be purged), plus wired memory, plus what the compressor holds.
fn memory() -> Option<Memory> {
    let total = macos::physical_memory()?;
    let pages = macos::vm_statistics()?;

    let app_pages =
        u64::from(pages.internal_page_count).saturating_sub(u64::from(pages.purgeable_count));
    let used_pages =
        app_pages + u64::from(pages.wire_count) + u64::from(pages.compressor_page_count);

    let used = used_pages.checked_mul(macos::page_size()?)?;
    Memory::new(total, used)
}
