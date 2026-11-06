//! Homebrew, from its installer at a pinned commit, and the line in `.zprofile` that puts it on the
//! path.

use std::{fs, io, os::unix::fs::PermissionsExt, process::Command};

use hangar_error::{Error, Result};
use hangar_fs::Owner;
use hangar_sys_macos as macos;

use super::{clean_up, replace_file, run_program, say, sudo::PipedSudo};

pub(super) const BREW: &str = "/opt/homebrew/bin/brew";
/// Homebrew's installer at a pinned commit.
const HOMEBREW_INSTALLER: &str = "https://raw.githubusercontent.com/Homebrew/install/85d1a3fc80d8a63932f632aca8f787de11d14a64/install.sh";
const HOMEBREW_DIGEST: &str = "5f333bbe53bc490e51e7ccb1df8779b3dd6ee73a1a7379efda216edb08ccb148";
const HOMEBREW_SIZE_LIMIT_BYTES: &str = "1048576";

/// The installer is pinned to a known commit and checked against its SHA-256 before it runs.
pub(super) fn install_homebrew(sudo: &PipedSudo) -> Result<()> {
    say("Installing Homebrew");

    let folder =
        TemporaryFolder::new().map_err(|error| Error::step("save Homebrew's installer", error))?;
    let installer = format!("{}/install.sh", folder.path);

    download_homebrew_installer(&installer)?;

    run_homebrew_installer(&installer, sudo)
}

fn download_homebrew_installer(path: &str) -> Result<()> {
    let arguments = [
        "--fail",
        "--silent",
        "--show-error",
        "--location",
        "--proto",
        "=https",
        "--proto-redir",
        "=https",
        "--max-filesize",
        HOMEBREW_SIZE_LIMIT_BYTES,
        "--output",
        path,
        HOMEBREW_INSTALLER,
    ];

    run_program("/usr/bin/curl", &arguments)?;

    let script = fs::read(path).map_err(|error| Error::step("read Homebrew's installer", error))?;

    if !is_pinned_homebrew_installer(&script) {
        return Err(Error::Plain(
            "Homebrew's installer didn't match the version Hangar expects.",
        ));
    }

    Ok(())
}

fn is_pinned_homebrew_installer(script: &[u8]) -> bool {
    macos::sha256(script).is_some_and(|digest| hex(&digest) == HOMEBREW_DIGEST)
}

#[expect(
    clippy::format_collect,
    reason = "a 32-byte digest, once per setup: the plain form reads best"
)]
pub(super) fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// `NONINTERACTIVE` stops the installer from asking questions; its own `sudo` calls use the
/// password `sudo` remembers, so it is remembered just before.
fn run_homebrew_installer(path: &str, sudo: &PipedSudo) -> Result<()> {
    sudo.let_sudo_remember_password()?;

    let mut command = Command::new("/bin/bash");
    command.arg(path).env("NONINTERACTIVE", "1");
    hangar_error::check_exit("Homebrew's installer", command.status())
}

/// Only this user can open it.
struct TemporaryFolder {
    path: String,
}

impl TemporaryFolder {
    fn new() -> io::Result<TemporaryFolder> {
        let path = macos::temporary_folder("hangar")?;
        Ok(TemporaryFolder { path })
    }
}

impl Drop for TemporaryFolder {
    fn drop(&mut self) {
        clean_up(fs::remove_dir_all(&self.path));
    }
}

/// The profile keeps its permission bits, and one that can't be read as text is left alone.
pub(super) fn add_homebrew_to_profile(home: &str) -> Result<()> {
    let path = format!("{home}/.zprofile");
    let text = read_profile(&path)?;

    if text.contains("brew shellenv") {
        return Ok(());
    }

    let mode = permission_bits(&path).unwrap_or(0o644);
    replace_file(
        home,
        ".zprofile",
        profile_with_homebrew(&text).as_bytes(),
        mode,
        Owner::ThisUser,
    )
}

fn read_profile(path: &str) -> Result<String> {
    match fs::read_to_string(path) {
        Ok(text) => Ok(text),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(String::new()),
        Err(error) => Err(Error::file("read", path, error)),
    }
}

fn profile_with_homebrew(text: &str) -> String {
    let separator = if text.is_empty() || text.ends_with('\n') {
        ""
    } else {
        "\n"
    };
    format!("{text}{separator}eval \"$({BREW} shellenv)\"\n")
}

pub(super) fn permission_bits(path: &str) -> Option<u32> {
    let metadata = fs::metadata(path).ok()?;
    Some(metadata.permissions().mode() & 0o777)
}
