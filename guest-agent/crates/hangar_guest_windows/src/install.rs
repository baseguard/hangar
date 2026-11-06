//! `install` runs in two halves: the elevated one installs, the unelevated one starts the helper.
//!
//! `update --sha256 <hex>`, which Hangar runs through `hangar exec`, starts only the elevated half,
//! which installs only bytes with the hash Hangar gave for the agent it copied in.

use std::{
    fs::{self, OpenOptions},
    io::{self, Read, Write},
    os::windows::{fs::OpenOptionsExt, process::CommandExt},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread::sleep,
    time::{Duration, Instant},
};

use windows_sys::Win32::{
    Foundation::{
        ERROR_ACCESS_DENIED, ERROR_CANCELLED, ERROR_SERVICE_ALREADY_RUNNING,
        ERROR_SERVICE_DOES_NOT_EXIST,
    },
    Storage::FileSystem::FILE_SHARE_READ,
    System::Threading::CREATE_BREAKAWAY_FROM_JOB,
};

use super::{BINARY, SERVICE, folder, keep_leftover_file, secure_folder, service};
use hangar_error::{Error, Result};
use hangar_fs::verbatim;
use hangar_sha256::{FLAG, Sha256};
use hangar_sys_windows::{
    self as sys,
    service::{RunAs, Service, Settings, Start},
};

const ELEVATED: &str = "--elevated";
const ELEVATED_USAGE: &str = "usage: hangar-agent install [--elevated [--sha256 <hex>]]";
pub(crate) const SESSION_HELPER_COMMAND: &str = "session";
const RUN_KEY: &str = r"SOFTWARE\Microsoft\Windows\CurrentVersion\Run";
const RUN_VALUE: &str = "Hangar Session";
const SERVICE_DISPLAY_NAME: &str = "Hangar Agent";
const SERVICE_DESCRIPTION: &str = "Reports this VM's memory use to Hangar, shares the clipboard, \
                                   runs hangar exec's commands, keeps Hangar's certificate \
                                   authority in place and shuts Windows down when Hangar asks.";
pub(crate) const INSTALLED: &str = "Hangar's agent is installed.";
const INSTALLED_SIGN_OUT: &str =
    "Hangar's agent is installed. Sign out of Windows and back in to finish.";
/// The service shuts Windows down and starts the session helper as the user at the screen; its
/// ports, pipes and log file are reached through their access lists, not privileges.
const SERVICE_PRIVILEGES: [&str; 5] = [
    "SeShutdownPrivilege",
    "SeChangeNotifyPrivilege",
    "SeTcbPrivilege",
    "SeAssignPrimaryTokenPrivilege",
    "SeIncreaseQuotaPrivilege",
];
const RESTART_DELAY: Duration = Duration::from_secs(5);
const FAILURE_RESET_PERIOD: Duration = Duration::from_hours(24);
const STOP_TIMEOUT: Duration = Duration::from_secs(30);
const STOP_CHECK_INTERVAL: Duration = Duration::from_millis(250);

enum ElevatedHalf {
    Installed,
    Failed,
    Declined,
}

/// Which half of the install this process runs.
enum Half {
    /// Started through UAC by the unelevated half, which waits for its exit status.
    Elevated,
    /// Started by `update` with the hash of the agent Hangar copied in; nobody waits for it.
    ElevatedForUpdate(Sha256),
    /// Started by a person or Hangar's unattended install.
    Unelevated,
}

impl Half {
    /// `arguments` start with the command; `None` for an elevated half with arguments it doesn't
    /// take, such as a hash that isn't valid.
    fn of(arguments: &[String]) -> Option<Half> {
        match arguments {
            [_command, flag] if flag == ELEVATED => Some(Half::Elevated),
            [_command, flag, hash @ ..] if flag == ELEVATED => {
                Sha256::from_flag(hash).map(Half::ElevatedForUpdate)
            }
            _ => Some(Half::Unelevated),
        }
    }
}

pub fn run(arguments: &[String]) -> Result<()> {
    let half = Half::of(arguments).ok_or(Error::Usage(ELEVATED_USAGE))?;

    match half {
        Half::Elevated => install_as_elevated_half(),
        Half::ElevatedForUpdate(copied_agent) => install_for_update(copied_agent),
        Half::Unelevated if sys::is_elevated() => {
            install_as_administrator();
            Ok(())
        }
        Half::Unelevated => {
            install_through_uac();
            Ok(())
        }
    }
}

/// Returns once the elevated half runs, without waiting for it: it stops the service that carries
/// `hangar exec`, which would end this command first. The service then starts the session helper.
pub fn update(copied_agent: Sha256) -> Result<()> {
    let this_program =
        std::env::current_exe().map_err(|error| Error::step("find this program", error))?;
    let hash = copied_agent.to_string();
    let arguments = ["install", ELEVATED, FLAG, &hash];

    let started = if sys::is_elevated() {
        start_elevated_half_outside_job(&this_program, &arguments)
    } else {
        // UAC's service starts the half, outside this command's job.
        sys::start_elevated(&this_program, &arguments.join(" "))
    };

    match started {
        Ok(()) => Ok(()),
        Err(error) if error.raw_os_error() == Some(ERROR_CANCELLED.cast_signed()) => Err(
            Error::Plain("The administrator prompt in the guest was declined."),
        ),
        Err(error) => Err(Error::step("start the update as administrator", error)),
    }
}

/// Already elevated, runas would start the half in this command's job, which exec ends when the
/// connection drops; jobs of an exec before agent 29 refuse the breakaway, so it then starts inside.
fn start_elevated_half_outside_job(this_program: &Path, arguments: &[&str]) -> io::Result<()> {
    match start_elevated_half_directly(this_program, arguments, CREATE_BREAKAWAY_FROM_JOB) {
        Err(error) if error.raw_os_error() == Some(ERROR_ACCESS_DENIED.cast_signed()) => {
            start_elevated_half_directly(this_program, arguments, 0)
        }
        started => started,
    }
}

fn start_elevated_half_directly(
    this_program: &Path,
    arguments: &[&str],
    creation_flags: u32,
) -> io::Result<()> {
    Command::new(this_program)
        .args(arguments)
        .creation_flags(creation_flags)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map(drop)
}

/// A running program can be moved aside, so the new binary goes in before the service stops, and the
/// old one is removed only once the new one runs; `copied_agent` comes from `update`.
pub(crate) fn put_in_place(copied_agent: Option<Sha256>) -> Result<()> {
    let folder = folder()?;
    let binary = folder.join(BINARY);
    let new_binary = new_binary_bytes(&binary, copied_agent)?;

    secure_folder(&folder).map_err(|error| Error::file("use", folder.display(), error))?;
    let old_binary = match new_binary {
        Some(bytes) => replace_binary(&folder, &bytes)?,
        None => None,
    };

    if let Err(error) = restart_agent_service(&binary) {
        start_old_agent_again(&binary, old_binary.as_deref());
        return Err(error);
    }
    if let Some(old) = old_binary {
        remove_now_or_at_restart(&old);
    }

    start_session_helper_at_sign_in(&binary)
}

fn restart_agent_service(binary: &Path) -> Result<()> {
    stop_service(SERVICE).map_err(|error| Error::step("stop Hangar's agent", error))?;
    install_agent_service(binary)?;
    start_service(SERVICE).map_err(|error| Error::step("start Hangar's agent", error))
}

/// Best effort, after the new agent didn't start: the guest would otherwise have no agent until it
/// restarts, and nobody may be there to notice. Failures go to the log with the update's own error.
fn start_old_agent_again(binary: &Path, old: Option<&Path>) {
    if let Some(old) = old
        && let Err(error) = fs::rename(old, verbatim(binary))
    {
        service::note_in_log(&Error::file("put back", old.display(), error));
    }

    if let Err(error) = start_service(SERVICE) {
        service::note_in_log(&Error::step("start Hangar's agent again", error));
    }
}

/// Its exit status tells the unelevated half whether to go on. Without UAC, Windows starts this
/// half unelevated; asking again would chain waiting installers without end.
fn install_as_elevated_half() -> Result<()> {
    check_elevated()?;
    let installed = put_in_place(None);

    if let Err(error) = &installed {
        sys::show_error(&error.to_string());
    }

    installed
}

/// Nobody sees a message box during an update, so failures go to the agent's log.
fn install_for_update(copied_agent: Sha256) -> Result<()> {
    let installed = check_elevated().and_then(|()| put_in_place(Some(copied_agent)));

    if let Err(error) = &installed {
        service::note_in_log(error);
    }

    installed
}

fn check_elevated() -> Result<()> {
    if !sys::is_elevated() {
        return Err(Error::Plain(
            "Windows didn't run the installer as administrator.",
        ));
    }
    Ok(())
}

/// An elevated helper would run `hangar exec`'s commands elevated; the helper starts at sign-in.
fn install_as_administrator() {
    match put_in_place(None) {
        Ok(()) => sys::show_info(INSTALLED_SIGN_OUT),
        Err(error) => sys::show_error(&error.to_string()),
    }
}

/// Only this unelevated half starts the session helper, so its commands run unelevated.
fn install_through_uac() {
    match run_elevated_half() {
        Ok(ElevatedHalf::Installed) => start_session_helper_and_confirm(),
        // The elevated half showed its failure, and a declined prompt needs no message.
        Ok(ElevatedHalf::Failed | ElevatedHalf::Declined) => {}
        Err(error) => sys::show_error(&Error::step("install Hangar's agent", error).to_string()),
    }
}

fn run_elevated_half() -> io::Result<ElevatedHalf> {
    let this_program = std::env::current_exe()?;
    let ran = sys::run_elevated(&this_program, &format!("install {ELEVATED}"));

    match ran {
        Ok(0) => Ok(ElevatedHalf::Installed),
        Ok(_) => Ok(ElevatedHalf::Failed),
        Err(error) if error.raw_os_error() == Some(ERROR_CANCELLED.cast_signed()) => {
            Ok(ElevatedHalf::Declined)
        }
        Err(error) => Err(error),
    }
}

/// A helper that can't start now starts at the next sign-in, so the message then asks for one.
fn start_session_helper_and_confirm() {
    match start_session_helper() {
        Ok(()) => sys::show_info(INSTALLED),
        Err(_) => sys::show_info(INSTALLED_SIGN_OUT),
    }
}

fn start_session_helper() -> Result<()> {
    let binary = folder()?.join(BINARY);
    let started = Command::new(&binary).arg(SESSION_HELPER_COMMAND).spawn();

    if let Err(error) = started {
        return Err(Error::file("start", binary.display(), error));
    }

    Ok(())
}

/// For an update the bytes are installed as checked: a cut-off copy, or one renamed and replaced
/// after UAC started it, is never installed. `None` when this program is the installed one.
fn new_binary_bytes(installed: &Path, copied_agent: Option<Sha256>) -> Result<Option<Vec<u8>>> {
    let this_program =
        std::env::current_exe().map_err(|error| Error::step("find this program", error))?;

    let Some(copied_agent) = copied_agent else {
        if same_file(&this_program, installed) {
            return Ok(None);
        }
        return read_this_program(&this_program).map(Some);
    };

    let bytes = read_this_program(&this_program)?;
    if Sha256::of(&bytes) != copied_agent {
        return Err(Error::CopiedAgentChanged);
    }
    Ok(Some(bytes))
}

fn read_this_program(this_program: &Path) -> Result<Vec<u8>> {
    read_whole_file(this_program)
        .map_err(|error| Error::file("read", this_program.display(), error))
}

fn same_file(first: &Path, second: &Path) -> bool {
    let (Ok(first), Ok(second)) = (fs::canonicalize(first), fs::canonicalize(second)) else {
        return false;
    };

    first.as_os_str().eq_ignore_ascii_case(second.as_os_str())
}

/// Reads all of `path` while nobody may write to it.
fn read_whole_file(path: &Path) -> io::Result<Vec<u8>> {
    let mut file = OpenOptions::new()
        .read(true)
        .share_mode(FILE_SHARE_READ)
        .open(verbatim(path))?;

    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    Ok(bytes)
}

/// Windows can rename but not delete a running program, so the old copy moves aside, to the path
/// this returns, and stays there for the caller to remove: there is always an agent to run.
fn replace_binary(folder: &Path, bytes: &[u8]) -> Result<Option<PathBuf>> {
    let id = std::process::id();
    let target = verbatim(&folder.join(BINARY));
    let new = verbatim(&folder.join(format!("hangar-agent.{id}.new")));
    let old = verbatim(&folder.join(format!("hangar-agent.{id}.old")));

    if let Err(error) = write_new_file(&new, bytes) {
        keep_leftover_file(fs::remove_file(&new));
        return Err(Error::file("write", new.display(), error));
    }

    let swapped = swap_in(&new, &target, &old);
    if swapped.is_err() {
        keep_leftover_file(fs::remove_file(&new));
    }
    swapped
}

/// The path the old copy moved to; `None` when there was none.
fn swap_in(new: &Path, target: &Path, old: &Path) -> Result<Option<PathBuf>> {
    let replaces_old = fs::symlink_metadata(target).is_ok();
    if replaces_old {
        fs::rename(target, old)
            .map_err(|error| Error::file("move aside", target.display(), error))?;
    }

    if let Err(error) = fs::rename(new, target) {
        return Err(put_old_back(replaces_old, old, target, &error));
    }

    Ok(replaces_old.then(|| old.to_path_buf()))
}

/// After the new copy failed to move into place; the error says whether the old one is back.
fn put_old_back(replaces_old: bool, old: &Path, target: &Path, failure: &io::Error) -> Error {
    if !replaces_old {
        return Error::file("replace", target.display(), failure);
    }

    match fs::rename(old, target) {
        Ok(()) => Error::file("replace", target.display(), failure),
        Err(rollback) => Error::file(
            "replace",
            target.display(),
            format!(
                "{failure}, and putting the old copy back failed too ({rollback}); it is at {}",
                old.display()
            ),
        ),
    }
}

fn write_new_file(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut file = OpenOptions::new().write(true).create_new(true).open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

fn remove_now_or_at_restart(old: &Path) {
    if fs::remove_file(old).is_ok() {
        return;
    }

    keep_leftover_file(sys::delete_at_restart(old));
}

fn install_agent_service(binary: &Path) -> Result<()> {
    let agent = Settings {
        name: SERVICE,
        display_name: SERVICE_DISPLAY_NAME,
        program: binary,
        arguments: &["service"],
        dependencies: &[],
        start: Start::Automatic,
        run_as: RunAs::LocalSystem,
    };

    configure_agent_service(&agent).map_err(|error| Error::step("install Hangar's agent", error))
}

fn configure_agent_service(agent: &Settings) -> io::Result<()> {
    let service = create_or_update_service(agent)?;
    service.set_description(SERVICE_DESCRIPTION)?;
    service.require_privileges(&SERVICE_PRIVILEGES)?;
    service.restart_on_failure(RESTART_DELAY, FAILURE_RESET_PERIOD)
}

pub(crate) fn create_or_update_service(settings: &Settings) -> io::Result<Service> {
    let Some(existing) = Service::open_to_configure(settings.name)? else {
        return Service::create(settings);
    };

    existing.update(settings)?;
    Ok(existing)
}

pub(crate) fn start_service(name: &str) -> io::Result<()> {
    let Some(service) = Service::open_to_start(name)? else {
        return Err(io::Error::from_raw_os_error(
            ERROR_SERVICE_DOES_NOT_EXIST.cast_signed(),
        ));
    };

    match service.start() {
        Err(error) if error.raw_os_error() == Some(ERROR_SERVICE_ALREADY_RUNNING.cast_signed()) => {
            Ok(())
        }
        started => started,
    }
}

fn stop_service(name: &str) -> io::Result<()> {
    let Some(service) = Service::open_to_stop(name)? else {
        return Ok(());
    };

    // A service that isn't running refuses the stop; the state check below decides either way.
    hangar_error::note_failure("the state check decides", service.request_stop());

    let deadline = Instant::now() + STOP_TIMEOUT;
    while Instant::now() < deadline {
        if service.is_stopped()? {
            return Ok(());
        }
        sleep(STOP_CHECK_INTERVAL);
    }

    Err(io::Error::other(format!("The {name} service didn't stop.")))
}

fn start_session_helper_at_sign_in(binary: &Path) -> Result<()> {
    sys::program_command_line(binary, &[SESSION_HELPER_COMMAND])
        .and_then(|command| sys::set_registry_text(RUN_KEY, RUN_VALUE, &command))
        .map_err(|error| Error::step("start the session helper at sign-in", error))
}
