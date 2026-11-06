#![forbid(unsafe_code)]
#![cfg_attr(windows, windows_subsystem = "windows")]

use std::process::ExitCode;

use hangar_error::{Error, Result};
#[cfg(target_os = "linux")]
use hangar_guest_linux as linux;
#[cfg(target_os = "macos")]
use hangar_guest_macos as macos;
#[cfg(windows)]
use hangar_guest_windows as windows;
use hangar_report as report;
use hangar_sha256::Sha256;

#[cfg(target_os = "linux")]
const USAGE: &str = concat!(
    "usage: hangar-agent install | update --sha256 <hex> | report | exec | clipboard",
    " | cp-out <path> | cp-in <path> | ls [path] | take | version"
);
#[cfg(target_os = "macos")]
const USAGE: &str = concat!(
    "usage: hangar-agent install | update --sha256 <hex> | setup | agent | report",
    " | install-daemon | cp-out <path> | cp-in <path> | ls [path] | take | version"
);
#[cfg(windows)]
const USAGE: &str = concat!(
    "usage: hangar-agent install | update --sha256 <hex> | setup | service | session",
    " | winpe-install <drive> | cp-out <path> | cp-in <path> | ls [path] | take | version"
);

/// Hangar matches the start of this sentence to ask for the password, so it goes out without the
/// prefix and with an exit status of its own.
const NEEDS_PASSWORD_EXIT: u8 = 2;

fn main() -> ExitCode {
    #[cfg(windows)]
    {
        hangar_sys_windows::load_dlls_from_system32_only();
        hangar_sys_windows::attach_to_parent_console();
    }

    let arguments: Vec<String> = std::env::args().skip(1).collect();

    match run(&arguments) {
        Ok(()) => ExitCode::SUCCESS,
        Err(Error::NeedsPassword) => {
            eprintln!("{}", Error::NeedsPassword);
            ExitCode::from(NEEDS_PASSWORD_EXIT)
        }
        Err(error) => {
            eprintln!("hangar-agent: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run(arguments: &[String]) -> Result<()> {
    let command = arguments.first().map(String::as_str).unwrap_or_default();

    match command {
        "version" => {
            println!("{}", report::version());
            Ok(())
        }

        // `hangar cp` runs these through `hangar exec`, as the user at the screen.
        "cp-out" => hangar_copy::copy_out(only_path(arguments)?),
        "cp-in" => hangar_copy::copy_in(only_path(arguments)?),
        // The host's file browser runs it the same way, one folder at a time.
        "ls" => hangar_copy::list_folder(optional_path(arguments)?),
        // A drop: the host streams the dropped files the same way.
        "take" => {
            no_arguments(arguments)?;
            hangar_copy::take()
        }

        #[cfg(target_os = "linux")]
        "install" => linux::install::run(),
        // Hangar replaces an installed agent with these, through `hangar exec`.
        #[cfg(target_os = "linux")]
        "update" => linux::update::run(copied_agent_hash(arguments)?),
        #[cfg(target_os = "linux")]
        "report" => linux::report::run(),
        #[cfg(target_os = "linux")]
        "exec" => linux::exec::run(),
        #[cfg(target_os = "linux")]
        "clipboard" => linux::clipboard::run(),

        // A double-click in Finder starts the agent without a command, which means install.
        #[cfg(target_os = "macos")]
        "" | "install" => macos::install::run(),
        #[cfg(target_os = "macos")]
        "update" => macos::install::update(copied_agent_hash(arguments)?),
        #[cfg(target_os = "macos")]
        "setup" => macos::install::setup(),
        #[cfg(target_os = "macos")]
        "agent" => macos::agent::run(),
        #[cfg(target_os = "macos")]
        "report" => macos::report::run(),
        #[cfg(target_os = "macos")]
        "install-daemon" => macos::install::daemon(),

        // Windows+R and a double-click start the agent without a command, which means install.
        #[cfg(windows)]
        "" | "install" => windows::install::run(arguments),
        #[cfg(windows)]
        "update" => windows::install::update(copied_agent_hash(arguments)?),
        #[cfg(windows)]
        "setup" => windows::setup::run(),
        #[cfg(windows)]
        "service" => windows::service::run(),
        #[cfg(windows)]
        "session" => windows::session::run(),
        // The install media's answer file runs this in Windows PE.
        #[cfg(windows)]
        "winpe-install" => windows::winpe_install::run(arguments),

        _ => Err(Error::Usage(USAGE)),
    }
}

/// Hangar runs `update --sha256 <hex>`, naming the agent it copied in by its hash; without one the
/// update is refused, so unchecked bytes are never installed.
fn copied_agent_hash(arguments: &[String]) -> Result<Sha256> {
    arguments
        .get(1..)
        .and_then(Sha256::from_flag)
        .ok_or(Error::Usage(USAGE))
}

fn no_arguments(arguments: &[String]) -> Result<()> {
    match arguments {
        [_command] => Ok(()),
        _ => Err(Error::Usage(USAGE)),
    }
}

/// The one path after the command.
fn only_path(arguments: &[String]) -> Result<&str> {
    match arguments {
        [_command, path] => Ok(path),
        _ => Err(Error::Usage(USAGE)),
    }
}

/// The path after the command, if there is one.
fn optional_path(arguments: &[String]) -> Result<Option<&str>> {
    match arguments {
        [_command] => Ok(None),
        [_command, path] => Ok(Some(path)),
        _ => Err(Error::Usage(USAGE)),
    }
}
