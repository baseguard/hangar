//! `install` copies the agent into place and runs `setup`, which starts it, puts the system part in
//! place as root and installs the tools. `update` replaces an installed agent for Hangar.

mod homebrew;
mod sudo;
mod tools;
mod update;

use std::{
    env, fs,
    io::{self, Write},
    os::unix::fs::PermissionsExt,
    path::Path,
    process::{Command, Stdio},
    thread::sleep,
    time::Duration,
};

use hangar_error::{Error, Result};
use hangar_fs::{Dir, Owner};

use homebrew::{BREW, add_homebrew_to_profile, install_homebrew};
use sudo::{PipedSudo, ask_for_sudo};
use tools::{has_command_line_tools, install_command_line_tools};
pub use update::update;

const LABEL: &str = "io.baseguard.hangar.guest-agent";
const AGENT_FOLDER: &str = "Library/Application Support/Hangar";
const AGENT: &str = "hangar-agent";
/// The system part; its program and plist are root's, outside anything a user can change.
const DAEMON_LABEL: &str = "io.baseguard.hangar.guest-daemon";
const HELPER_FOLDER: &str = "/Library/PrivilegedHelperTools";
const DAEMONS_FOLDER: &str = "/Library/LaunchDaemons";
/// launchd can refuse a bootstrap while the job it just booted out is still stopping.
const BOOTSTRAP_ATTEMPTS: u32 = 10;
const BOOTSTRAP_PAUSE: Duration = Duration::from_millis(500);

pub fn run() -> Result<()> {
    let home = home()?;
    copy_agent_into_place(&home, &read_this_program()?)?;

    setup()
}

fn copy_agent_into_place(home: &str, program: &[u8]) -> Result<()> {
    let folder = format!("{home}/{AGENT_FOLDER}");
    create_real_folder(&folder)?;

    replace_file(&folder, AGENT, program, 0o755, Owner::ThisUser)
}

pub fn setup() -> Result<()> {
    let home = home()?;
    if !is_executable(&installed_agent(&home)) {
        return Err(Error::Plain(
            "The guest agent isn't installed. Run hangar-agent install instead.",
        ));
    }

    // The new agent, which no longer reports, replaces this user's old one before the system part
    // starts: two writers would mix their report lines on the one port.
    start_agent(&home)?;

    let Some(sudo) = ask_for_sudo()? else {
        return Ok(());
    };
    put_system_part_in_place(&sudo, &home)?;
    if !has_command_line_tools() {
        install_command_line_tools(&sudo)?;
    }
    if !is_executable(BREW) {
        install_homebrew(&sudo)?;
    }

    add_homebrew_to_profile(&home)?;
    say("Hangar setup finished.");
    Ok(())
}

/// Runs this user's installed copy as root once; from then on root runs only its own copy. `setup`
/// runs in the user's own Terminal; `update` makes root's copy first (see `update`).
fn put_system_part_in_place(sudo: &PipedSudo, home: &str) -> Result<()> {
    let agent = installed_agent(home);
    sudo.run_showing_output(&[&agent, "install-daemon"])
}

/// `install-daemon`, run as root by `setup` and `update`: puts the system part in place and starts it. It reads
/// nothing from the environment, which `sudo` partly keeps from the user.
pub fn daemon() -> Result<()> {
    if !hangar_sys_unix::is_root() {
        return Err(Error::NeedsRoot);
    }

    let installed = put_daemon_in_place();
    remove_update_copy_if_running_it();
    installed
}

fn put_daemon_in_place() -> Result<()> {
    let program = read_this_program()?;
    create_real_folder(HELPER_FOLDER)?;
    replace_file(HELPER_FOLDER, DAEMON_LABEL, &program, 0o755, Owner::Root)?;

    let plist = launch_daemon_plist(&helper_path());
    let plist_name = format!("{DAEMON_LABEL}.plist");
    replace_file(
        DAEMONS_FOLDER,
        &plist_name,
        plist.as_bytes(),
        0o644,
        Owner::Root,
    )?;

    start_daemon(&format!("{DAEMONS_FOLDER}/{plist_name}"))
}

/// Root's copy for `update` is only needed until the system part is in place; a leftover is root's
/// and only takes space.
fn remove_update_copy_if_running_it() {
    let is_update_copy = env::current_exe()
        .and_then(fs::canonicalize)
        .is_ok_and(|running| running == Path::new(update::ROOT_COPY));
    if is_update_copy {
        clean_up(fs::remove_file(update::ROOT_COPY));
    }
}

fn helper_path() -> String {
    format!("{HELPER_FOLDER}/{DAEMON_LABEL}")
}

fn start_daemon(plist: &str) -> Result<()> {
    let service = format!("system/{DAEMON_LABEL}");

    if is_loaded(&service) {
        // A job that doesn't stop makes the bootstrap below fail, which is retried.
        succeeds_quietly("/bin/launchctl", &["bootout", &service]);
    }

    if !bootstrap("system", plist, &service) {
        return Err(Error::Plain(
            "launchd didn't start the agent's system part.",
        ));
    }

    Ok(())
}

fn home() -> Result<String> {
    env::var("HOME").map_err(|_unset| Error::NoHome)
}

fn installed_agent(home: &str) -> String {
    format!("{home}/{AGENT_FOLDER}/{AGENT}")
}

fn read_this_program() -> Result<Vec<u8>> {
    read_real_program_file().map_err(|error| Error::step("read this program", error))
}

/// Read through the real path, in case the program was started through a link.
fn read_real_program_file() -> io::Result<Vec<u8>> {
    let path = fs::canonicalize(env::current_exe()?)?;
    fs::read(path)
}

/// When launchd won't start the agent now, it starts at the next login.
fn start_agent(home: &str) -> Result<()> {
    let plist_folder = format!("{home}/Library/LaunchAgents");
    create_real_folder(&plist_folder)?;

    let plist_name = format!("{LABEL}.plist");
    let plist = launch_agent_plist(&installed_agent(home));
    replace_file(
        &plist_folder,
        &plist_name,
        plist.as_bytes(),
        0o644,
        Owner::ThisUser,
    )?;

    let domain = format!("gui/{}", hangar_sys_unix::user_id());
    let service = format!("{domain}/{LABEL}");

    if is_loaded(&service) {
        // A job that doesn't stop makes the bootstrap below fail, which is retried.
        succeeds_quietly("/bin/launchctl", &["bootout", &service]);
    }

    if !bootstrap(&domain, &format!("{plist_folder}/{plist_name}"), &service) {
        say("The guest agent starts at the next login.");
    }

    Ok(())
}

fn is_loaded(service: &str) -> bool {
    succeeds_quietly("/bin/launchctl", &["print", service])
}

fn bootstrap(domain: &str, plist: &str, service: &str) -> bool {
    for _ in 0..BOOTSTRAP_ATTEMPTS {
        if succeeds_quietly("/bin/launchctl", &["bootstrap", domain, plist]) && is_loaded(service) {
            return true;
        }
        sleep(BOOTSTRAP_PAUSE);
    }
    false
}

fn launch_agent_plist(program: &str) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>KeepAlive</key>
	<true/>
	<key>Label</key>
	<string>{LABEL}</string>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>ProgramArguments</key>
	<array>
		<string>{}</string>
		<string>agent</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
"#,
        xml_escape(program)
    )
}

fn launch_daemon_plist(program: &str) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>KeepAlive</key>
	<true/>
	<key>Label</key>
	<string>{DAEMON_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>{}</string>
		<string>report</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
"#,
        xml_escape(program)
    )
}

fn xml_escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

fn is_executable(path: &str) -> bool {
    fs::metadata(path)
        .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}

/// A link to a folder is refused.
fn create_real_folder(path: &str) -> Result<()> {
    fs::create_dir_all(path).map_err(|error| Error::file("create", path, error))?;

    let is_folder = fs::symlink_metadata(path).is_ok_and(|metadata| metadata.is_dir());
    if !is_folder {
        return Err(Error::file(
            "use",
            path,
            "it should be a folder, not a link",
        ));
    }

    Ok(())
}

/// In one step, so a reader sees the old file or the whole new one; a link or folder with the
/// name is refused.
fn replace_file(folder: &str, name: &str, data: &[u8], mode: u32, owner: Owner) -> Result<()> {
    let path = format!("{folder}/{name}");
    let folder = Dir::open(folder).map_err(|error| Error::file("open", folder, error))?;

    folder
        .replace_file(name, data, mode, owner)
        .map_err(|error| Error::file("write", &path, error))
}

fn quiet(program: &str, arguments: &[&str]) -> Command {
    let mut command = Command::new(program);
    command
        .args(arguments)
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    command
}

fn succeeds_quietly(program: &str, arguments: &[&str]) -> bool {
    succeeded(&mut quiet(program, arguments))
}

fn succeeded(command: &mut Command) -> bool {
    command.status().is_ok_and(|status| status.success())
}

fn run_program(program: &str, arguments: &[&str]) -> Result<()> {
    let mut command = Command::new(program);
    command.args(arguments);

    let name = program.rsplit('/').next().unwrap_or(program);
    hangar_error::check_exit(name, command.status())
}

/// Progress lines are only for a person watching; setup goes on when there is nowhere to print.
fn say(line: &str) {
    hangar_error::note_failure("setup goes on", writeln!(io::stdout(), "{line}"));
}

/// Clean-up after a step that has already succeeded or failed with its own error: if it fails, a
/// stray file stays behind, private to this user or harmless.
fn clean_up(removal: io::Result<()>) {
    hangar_error::note_failure("a stray file stays behind", removal);
}

#[cfg(test)]
#[path = "../install_test.rs"]
mod tests;
