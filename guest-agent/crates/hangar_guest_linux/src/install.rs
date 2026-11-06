//! `hangar-agent install`: puts the agent in place from Hangar's Tools share and starts it.

use std::{fs, os::unix::fs::MetadataExt, path::Path, process::Command};

use hangar_error::Error;
use hangar_fs::{Dir, Owner};
use hangar_sys_linux::gtk;

use crate::update::UPDATE_PROGRAM;

/// The units start the agent from here.
const PROGRAM: &str = "/usr/local/libexec/hangar-agent";
pub(crate) const THIS_PROGRAM: &str = "/proc/self/exe";
const SHARED_FOLDERS: &str = "/mnt/hangar";
/// The report service writes Hangar's variables here but, with `ProtectSystem=strict`, can't
/// create the folders in /etc itself.
const VARIABLE_FOLDERS: [&str; 2] = ["/etc/profile.d", "/etc/environment.d"];

const REPORT_SERVICE: &str = "hangar-agent.service";
const EXEC_SERVICE: &str = "hangar-exec.service";
const SHARED_FOLDERS_MOUNT: &str = "mnt-hangar.mount";
const CLIPBOARD_HELPER: &str = "hangar-clipboard.service";

const PROGRAM_MODE: u32 = 0o755;
const CONFIG_MODE: u32 = 0o644;

struct ConfigFile {
    path: &'static str,
    contents: &'static str,
}

const SYSTEM_UNITS: [ConfigFile; 3] = [
    ConfigFile {
        path: "/etc/systemd/system/hangar-agent.service",
        contents: include_str!("units/hangar-agent.service"),
    },
    ConfigFile {
        path: "/etc/systemd/system/hangar-exec.service",
        contents: include_str!("units/hangar-exec.service"),
    },
    ConfigFile {
        path: "/etc/systemd/system/mnt-hangar.mount",
        contents: include_str!("units/mnt-hangar.mount"),
    },
];

const CLIPBOARD_UNIT: ConfigFile = ConfigFile {
    path: "/etc/systemd/user/hangar-clipboard.service",
    contents: include_str!("units/hangar-clipboard.service"),
};

/// Tags the SPICE port `uaccess`. The port belongs to root; with the tag, logind lets the user at
/// the active seat open it, so the clipboard helper in their session can.
const CLIPBOARD_PORT_RULE: ConfigFile = ConfigFile {
    path: "/etc/udev/rules.d/70-hangar-clipboard.rules",
    contents: include_str!("units/70-hangar-clipboard.rules"),
};

pub fn run() -> hangar_error::Result<()> {
    if !hangar_sys_unix::is_root() {
        return Err(Error::NeedsRoot);
    }

    install_agent_files()?;
    remove_update_copy_if_running_it();
    create_variable_folders()?;
    start_system_services()?;
    mount_shared_folders()?;

    if gtk::is_installed() {
        install_clipboard_helper()?;
        restart_clipboard_helpers_for_logged_in_users();
    }

    println!("Hangar's agent is installed.");
    Ok(())
}

fn install_agent_files() -> hangar_error::Result<()> {
    let program =
        fs::read(THIS_PROGRAM).map_err(|error| Error::step("read this program", error))?;
    write_root_file(PROGRAM, &program, PROGRAM_MODE)?;

    for unit in &SYSTEM_UNITS {
        write_config_file(unit)?;
    }
    Ok(())
}

/// The update's root-only copy is only needed until the agent is in place; a leftover is no matter.
fn remove_update_copy_if_running_it() {
    let Ok(running) = fs::read_link(THIS_PROGRAM) else {
        return;
    };
    if running != Path::new(UPDATE_PROGRAM) {
        return;
    }
    let _removed = fs::remove_file(UPDATE_PROGRAM);
}

fn create_variable_folders() -> hangar_error::Result<()> {
    for folder in VARIABLE_FOLDERS {
        fs::create_dir_all(folder).map_err(|error| Error::file("create", folder, error))?;
    }
    Ok(())
}

fn start_system_services() -> hangar_error::Result<()> {
    systemctl(&["daemon-reload"])?;
    systemctl(&["enable", REPORT_SERVICE, EXEC_SERVICE])?;
    systemctl(&["restart", REPORT_SERVICE, EXEC_SERVICE])
}

fn mount_shared_folders() -> hangar_error::Result<()> {
    fs::create_dir_all(SHARED_FOLDERS)
        .map_err(|error| Error::file("create", SHARED_FOLDERS, error))?;

    systemctl(&["enable", SHARED_FOLDERS_MOUNT])?;
    if systemctl(&["start", SHARED_FOLDERS_MOUNT]).is_err() {
        println!("The shared folders are mounted at /mnt/hangar from the next start.");
    }
    Ok(())
}

fn install_clipboard_helper() -> hangar_error::Result<()> {
    allow_desktop_user_to_open_clipboard_port()?;
    write_config_file(&CLIPBOARD_UNIT)?;

    systemctl(&["--global", "enable", CLIPBOARD_HELPER])
}

fn allow_desktop_user_to_open_clipboard_port() -> hangar_error::Result<()> {
    write_config_file(&CLIPBOARD_PORT_RULE)?;

    udevadm(&["control", "--reload"])?;
    udevadm(&[
        "trigger",
        "--subsystem-match=virtio-ports",
        "--action=change",
    ])
}

fn restart_clipboard_helpers_for_logged_in_users() {
    for user in logged_in_users() {
        if let Err(error) = restart_clipboard_helper(&user) {
            println!("{error} The clipboard starts for {user} at the next login.");
        }
    }
}

fn restart_clipboard_helper(user: &str) -> hangar_error::Result<()> {
    let user_manager = format!("{user}@");

    systemctl(&["--user", "-M", &user_manager, "daemon-reload"])?;
    systemctl(&["--user", "-M", &user_manager, "restart", CLIPBOARD_HELPER])
}

fn logged_in_users() -> Vec<String> {
    let Ok(output) = Command::new(crate::system_program("loginctl"))
        .args(["list-users", "--no-legend"])
        .output()
    else {
        return Vec::new();
    };

    user_names(&String::from_utf8_lossy(&output.stdout))
}

/// The lines of `loginctl list-users --no-legend` start "UID USER".
fn user_names(listing: &str) -> Vec<String> {
    let mut names = Vec::new();
    for line in listing.lines() {
        let Some(name) = line.split_whitespace().nth(1) else {
            continue;
        };
        if is_plain_user_name(name) {
            names.push(name.to_string());
        }
    }
    names
}

/// `name` goes into `-M <name>@`, so anything but a plain user name is skipped.
fn is_plain_user_name(name: &str) -> bool {
    let is_plain = |byte: u8| byte.is_ascii_alphanumeric() || b"._-".contains(&byte);
    !name.is_empty() && name.bytes().all(is_plain)
}

fn systemctl(arguments: &[&str]) -> hangar_error::Result<()> {
    run_program(&crate::system_program("systemctl"), arguments)
}

fn udevadm(arguments: &[&str]) -> hangar_error::Result<()> {
    run_program(&crate::system_program("udevadm"), arguments)
}

pub(crate) fn run_program(program: &str, arguments: &[&str]) -> hangar_error::Result<()> {
    let status = Command::new(program).args(arguments).status();

    let mut command = vec![program];
    command.extend(arguments);
    hangar_error::check_exit(command.join(" "), status)
}

fn write_config_file(file: &ConfigFile) -> hangar_error::Result<()> {
    write_root_file(file.path, file.contents.as_bytes(), CONFIG_MODE)
}

/// Root owns the file, and nothing ever sees half of it.
pub(crate) fn write_root_file(path: &str, contents: &[u8], mode: u32) -> hangar_error::Result<()> {
    let Some((folder, name)) = path.rsplit_once('/') else {
        return Err(Error::file("write", path, "it has no folder"));
    };

    fs::create_dir_all(folder).map_err(|error| Error::file("create", folder, error))?;
    let folder = open_roots_folder(folder)?;

    folder
        .replace_file(name, contents, mode, Owner::Root)
        .map_err(|error| Error::file("write", path, error))
}

/// A folder others can change would let them swap a file root runs or reads after it was written.
fn open_roots_folder(path: &str) -> hangar_error::Result<Dir> {
    let folder = Dir::open(path).map_err(|error| Error::file("open", path, error))?;
    let metadata = folder
        .metadata()
        .map_err(|error| Error::file("check", path, error))?;

    let is_roots_own = metadata.uid() == 0 && metadata.mode() & 0o022 == 0;
    if !is_roots_own {
        return Err(Error::file(
            "use",
            path,
            "it should be a folder only root can change",
        ));
    }
    Ok(folder)
}

#[cfg(test)]
#[path = "install_test.rs"]
mod tests;
