//! Hangar's unattended install runs this once; only putting the agent in place can fail it.

use std::{
    ffi::OsStr,
    fs::{self, File},
    io::{self, Write},
    os::windows::process::CommandExt,
    path::Path,
    process::{Command, ExitStatus, Stdio},
    thread::sleep,
    time::{Duration, Instant},
};

use windows_sys::Win32::System::Threading::CREATE_NO_WINDOW;

use super::{LOG_FILE, folder, install, keep_leftover_file, secure_folder};
use hangar_error::{Error, Result};
use hangar_sys_windows::{
    self as sys, devices,
    service::{RunAs, Settings, Start},
};

const VIRTIO_GPU: &str = r"PCI\VEN_1AF4&DEV_1050";
const BASIC_DISPLAY: &str = r"ROOT\BASICDISPLAY\0000";
const GPU_START_TIMEOUT: Duration = Duration::from_secs(120);
const GPU_CHECK_INTERVAL: Duration = Duration::from_secs(5);
const WINFSP_PACKAGE: &str = "winfsp.msi";
/// msiexec's exit status for "installed; restart Windows to finish".
const MSI_RESTART_REQUIRED: i32 = 3010;
/// The host's shared folders are mounted on this drive.
const SHARES_DRIVE: &str = "Z:";
const SHARES: &str = "VirtioFsSvc";
const SHARES_BINARY: &str = "virtiofs.exe";
const SHARES_DEPENDENCIES: [&str; 2] = ["WinFsp.Launcher", "VirtioFsDrv"];
const VIRTIOFS_KEY: &str = r"SOFTWARE\VirtIO-FS";
const MOUNT_TIMEOUT: Duration = Duration::from_secs(15);
const MOUNT_CHECK_INTERVAL: Duration = Duration::from_secs(1);
const TERMINAL_SERVER: &str = r"System\CurrentControlSet\Control\Terminal Server";
/// netsh arguments that turn on Windows' own Remote Desktop firewall rules.
const ENABLE_REMOTE_DESKTOP_RULES: [&str; 7] = [
    "advfirewall",
    "firewall",
    "set",
    "rule",
    "group=@FirewallAPI.dll,-28752",
    "new",
    "enable=yes",
];
const PING_RULE: &str = "name=Hangar: ping";
const REMOVE_PING_RULES: [&str; 5] = ["advfirewall", "firewall", "delete", "rule", PING_RULE];
/// netsh arguments that add the ping rule: echo requests in, from anywhere, on every profile.
const ADD_PING_RULE: [&str; 9] = [
    "advfirewall",
    "firewall",
    "add",
    "rule",
    PING_RULE,
    "dir=in",
    "action=allow",
    "protocol=icmpv4:8,any",
    "profile=any",
];

pub fn run() -> Result<()> {
    let folder = folder()?;
    secure_folder(&folder).map_err(|error| Error::file("use", folder.display(), error))?;

    let mut log = Log::create(&folder);
    keep_awake(&mut log);
    use_virtio_display(&mut log);
    mount_shared_folders(&folder, &mut log);
    open_firewall(&mut log);

    if let Err(error) = install::put_in_place(None) {
        log.line(&error.to_string());
        return Err(error);
    }

    keep_leftover_file(fs::remove_file(folder.join(WINFSP_PACKAGE)));
    log.line(install::INSTALLED);
    Ok(())
}

struct Log {
    file: Option<File>,
}

impl Log {
    fn create(folder: &Path) -> Log {
        Log {
            file: File::create(folder.join(LOG_FILE)).ok(),
        }
    }

    fn line(&mut self, text: &str) {
        println!("{text}");

        let Some(file) = &mut self.file else { return };
        if writeln!(file, "{text}").is_err() {
            // The line is printed; a file that couldn't take it won't take the next ones either.
            self.file = None;
        }
    }

    fn if_failed(&mut self, step: &str, result: io::Result<()>) {
        if let Err(error) = result {
            self.line(&format!("{step} failed: {error}"));
        }
    }
}

fn keep_awake(log: &mut Log) {
    let settings: [&[&str]; 3] = [
        &["/hibernate", "off"],
        &["/change", "standby-timeout-ac", "0"],
        &["/change", "monitor-timeout-ac", "0"],
    ];

    for arguments in settings {
        if !system_tool_succeeds("powercfg.exe", arguments) {
            log.line(&format!("powercfg {} failed", arguments.join(" ")));
        }
    }
}

fn use_virtio_display(log: &mut Log) {
    let gpu_started = wait_until(GPU_START_TIMEOUT, GPU_CHECK_INTERVAL, || {
        devices::display_adapter_started(VIRTIO_GPU)
    });

    if !gpu_started {
        log.line("The virtio GPU didn't start; the basic display adapter stays on.");
        return;
    }

    if devices::display_adapter_started(BASIC_DISPLAY) {
        log.if_failed(
            "Turning off the basic display adapter",
            devices::disable_device(BASIC_DISPLAY),
        );
    }
}

fn mount_shared_folders(folder: &Path, log: &mut Log) {
    install_winfsp(&folder.join(WINFSP_PACKAGE), log);

    log.if_failed(
        "Setting the shared folders' drive",
        sys::set_registry_text(VIRTIOFS_KEY, "MountPoint", SHARES_DRIVE),
    );
    log.if_failed(
        "Installing the shared folders service",
        install_shares_service(folder),
    );
    log.if_failed(
        "Starting the shared folders service",
        install::start_service(SHARES),
    );

    let shares_root = format!("{SHARES_DRIVE}\\");
    let mounted = wait_until(MOUNT_TIMEOUT, MOUNT_CHECK_INTERVAL, || {
        Path::new(&shares_root).exists()
    });

    if mounted {
        log.line(&format!("Shared folders: mounted at {SHARES_DRIVE}"));
    } else {
        log.line("Shared folders: none mounted");
    }
}

fn install_winfsp(package: &Path, log: &mut Log) {
    let arguments = [
        OsStr::new("/i"),
        package.as_os_str(),
        OsStr::new("/qn"),
        OsStr::new("/norestart"),
    ];

    let status = run_system_tool("msiexec.exe", &arguments);

    let code = status.as_ref().ok().and_then(ExitStatus::code);
    if matches!(code, Some(0 | MSI_RESTART_REQUIRED)) {
        return;
    }

    if let Err(failure) =
        hangar_error::check_exit(format!("Installing {}", package.display()), status)
    {
        log.line(&failure.to_string());
    }
}

fn install_shares_service(folder: &Path) -> io::Result<()> {
    let program = folder.join(SHARES_BINARY);
    let shares = Settings {
        name: SHARES,
        display_name: "Hangar Shared Folders",
        program: &program,
        arguments: &[],
        dependencies: &SHARES_DEPENDENCIES,
        start: Start::Automatic,
        run_as: RunAs::LocalSystem,
    };

    install::create_or_update_service(&shares)?;
    Ok(())
}

fn open_firewall(log: &mut Log) {
    let remote_desktop_on = sys::registry_number(TERMINAL_SERVER, "fDenyTSConnections") == Some(0);
    if remote_desktop_on && !system_tool_succeeds("netsh.exe", &ENABLE_REMOTE_DESKTOP_RULES) {
        log.line("Could not allow Remote Desktop through the firewall.");
    }

    allow_ping(log);
}

/// netsh adds another copy of a rule each time it's asked, so earlier copies are removed first.
fn allow_ping(log: &mut Log) {
    remove_ping_rules();

    if !system_tool_succeeds("netsh.exe", &ADD_PING_RULE) {
        log.line("Could not allow ping through the firewall.");
    }
}

/// netsh also exits with 1 when there's no rule yet, so its result says nothing; only the add's
/// result counts.
fn remove_ping_rules() {
    system_tool_succeeds("netsh.exe", &REMOVE_PING_RULES);
}

fn wait_until(timeout: Duration, interval: Duration, ready: impl Fn() -> bool) -> bool {
    let deadline = Instant::now() + timeout;

    while !ready() {
        if Instant::now() >= deadline {
            return false;
        }
        sleep(interval);
    }

    true
}

/// The full System32 path keeps a same-named program elsewhere on the search path from running.
fn run_system_tool(name: &str, arguments: &[&OsStr]) -> io::Result<ExitStatus> {
    let program = sys::system32()?.join(name);

    Command::new(program)
        .args(arguments)
        .creation_flags(CREATE_NO_WINDOW)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
}

fn system_tool_succeeds(name: &str, arguments: &[&str]) -> bool {
    let arguments: Vec<&OsStr> = arguments.iter().map(OsStr::new).collect();
    run_system_tool(name, &arguments).is_ok_and(|status| status.success())
}
