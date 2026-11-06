//! Brings the guest to the host's `trust` state: Hangar's CA in the System keychain, and its
//! placeholder variables in every zsh and in the apps of the user at the screen.

use std::{
    process::{Command, Stdio},
    sync::atomic::{AtomicBool, Ordering},
    thread,
};

use hangar_error::{Error, Result};
use hangar_fs::{Dir, Owner};
use hangar_host_commands::TrustState;
use hangar_sys_macos as macos;

use crate::zshenv::{hangar_block_names, with_hangar_block};

const HANGAR_FOLDER: &str = "/Library/Application Support/Hangar";
const CA_FILE: &str = "hangar-secrets.pem";
/// `/etc` is a link to this folder, and the folder handle never follows a link.
const ETC: &str = "/private/etc";
const ZSHENV: &str = "zshenv";
const FILE_MODE: u32 = 0o644;
const SECURITY: &str = "/usr/bin/security";
const LAUNCHCTL: &str = "/bin/launchctl";
const SYSTEM_KEYCHAIN: &str = "/Library/Keychains/System.keychain";

/// Set while the user at the screen is asked to trust the CA, so a second `trust` command doesn't
/// open a second dialog.
static IS_ASKING: AtomicBool = AtomicBool::new(false);

pub(crate) fn reconcile(state: &TrustState) {
    hangar_error::note_failure("the agent tries again at its next start", put_ca(state));

    let variables = state.variables_with_node_ca(Some(&ca_path()));
    hangar_error::note_failure(
        "zsh and apps keep the variables they had",
        put_variables(&variables),
    );
}

/// The PEM file records what the keychain holds, so the keychain is only touched when it changes. A
/// CA in place that isn't trusted yet is asked for again, since its last dialog may have found
/// nobody at the screen or been cancelled.
fn put_ca(state: &TrustState) -> Result<()> {
    let folder = open_hangar_folder()?;
    let wanted = state.ca_pem();
    let installed = folder
        .read_file(CA_FILE)
        .map_err(|error| Error::file("read", ca_path(), error))?;

    if installed.as_deref() == wanted.as_deref().map(str::as_bytes) {
        if wanted.is_some() && !is_trusted() {
            ask_for_trust();
        }
        return Ok(());
    }

    match wanted {
        Some(pem) => install_ca(&folder, &pem),
        None => remove_ca(&folder),
    }
}

/// Root can add the CA to the System keychain, but only a person can trust it.
fn install_ca(folder: &Dir, pem: &str) -> Result<()> {
    folder
        .replace_file(CA_FILE, pem.as_bytes(), FILE_MODE, Owner::Root)
        .map_err(|error| Error::file("write", ca_path(), error))?;

    remove_hangar_certificates()?;
    add_ca_file()?;
    ask_for_trust();
    Ok(())
}

/// The file goes last, so a keychain that refuses is tried again at the next start.
fn remove_ca(folder: &Dir) -> Result<()> {
    remove_hangar_certificates()?;

    folder
        .unlink(CA_FILE)
        .map_err(|error| Error::file("remove", ca_path(), error))
}

fn ca_path() -> String {
    format!("{HANGAR_FOLDER}/{CA_FILE}")
}

/// Root's folder: it holds what root trusts.
fn open_hangar_folder() -> Result<Dir> {
    std::fs::create_dir_all(HANGAR_FOLDER)
        .map_err(|error| Error::file("create", HANGAR_FOLDER, error))?;
    Dir::open(HANGAR_FOLDER).map_err(|error| Error::file("open", HANGAR_FOLDER, error))
}

fn add_ca_file() -> Result<()> {
    run(
        SECURITY,
        &["add-certificates", "-k", SYSTEM_KEYCHAIN, &ca_path()],
    )
}

/// For the SSL policy, as the apps that use the CA check it.
fn is_trusted() -> bool {
    Command::new(SECURITY)
        .args(["verify-cert", "-q", "-p", "ssl", "-c", &ca_path()])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

/// Admin trust settings need an administrator's password even from root, so macOS asks the user
/// at the screen in their own session. The dialog waits for them, so it runs on a thread of its
/// own and the host's other commands, like shutting down, aren't held up.
fn ask_for_trust() {
    let Some(uid) = macos::console_user_id() else {
        return;
    };
    if IS_ASKING.swap(true, Ordering::AcqRel) {
        return;
    }

    let started = thread::Builder::new()
        .name("trust dialog".into())
        .spawn(move || {
            let uid = uid.to_string();
            let ca_path = ca_path();
            let asked = run(LAUNCHCTL, &trust_dialog_arguments(&uid, &ca_path));
            hangar_error::note_failure("asked again with the host's next change or start", asked);
            IS_ASKING.store(false, Ordering::Release);
        });
    if started.is_err() {
        IS_ASKING.store(false, Ordering::Release);
    }
}

/// `security add-trusted-cert` in the user's session, as an admin trust setting for the SSL policy.
fn trust_dialog_arguments<'a>(uid: &'a str, ca_path: &'a str) -> [&'a str; 10] {
    [
        "asuser",
        uid,
        SECURITY,
        "add-trusted-cert",
        "-d",
        "-r",
        "trustRoot",
        "-k",
        SYSTEM_KEYCHAIN,
        ca_path,
    ]
}

/// Every certificate named like Hangar's, including the CAs of VMs this one was cloned from. Their
/// trust settings stay: removing those needs a person too, and without the certificate they match
/// nothing.
fn remove_hangar_certificates() -> Result<()> {
    for hash in hangar_certificate_hashes(&list_hangar_certificates()?) {
        run(
            SECURITY,
            &["delete-certificate", "-Z", &hash, SYSTEM_KEYCHAIN],
        )?;
    }
    Ok(())
}

/// `security` fails when nothing matches, so only a program that can't start is an error.
fn list_hangar_certificates() -> Result<String> {
    let output = Command::new(SECURITY)
        .args([
            "find-certificate",
            "-a",
            "-Z",
            "-c",
            hangar_host_commands::HANGAR_CA_PREFIX,
            SYSTEM_KEYCHAIN,
        ])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .map_err(|error| Error::step("list Hangar's CAs in the System keychain", error))?;

    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// The SHA-256 hashes in `security find-certificate -Z` output whose label starts with
/// Hangar's prefix; `-c` alone also matches the name in the middle.
fn hangar_certificate_hashes(listing: &str) -> Vec<String> {
    let mut hashes = Vec::new();
    let mut hash: Option<&str> = None;

    for line in listing.lines() {
        if let Some(found) = line.strip_prefix("SHA-256 hash: ") {
            hash = Some(found.trim());
            continue;
        }

        let label = line.trim().strip_prefix("\"labl\"<blob>=\"");
        let is_hangar_ca = label
            .and_then(|label| label.strip_suffix('"'))
            .is_some_and(hangar_host_commands::is_hangar_ca_name);
        if is_hangar_ca && let Some(hash) = hash.take() {
            hashes.push(hash.to_string());
        }
    }
    hashes
}

fn put_variables(variables: &[(String, String)]) -> Result<()> {
    let removed_names = put_shell_variables(variables)?;
    set_app_variables(variables, &removed_names)
}

/// Returns the names Hangar's block had that it no longer has.
fn put_shell_variables(variables: &[(String, String)]) -> Result<Vec<String>> {
    let path = format!("{ETC}/{ZSHENV}");
    let etc = Dir::open(ETC).map_err(|error| Error::file("open", ETC, error))?;
    let installed_bytes = etc
        .read_file(ZSHENV)
        .map_err(|error| Error::file("read", &path, error))?
        .unwrap_or_default();
    let installed = String::from_utf8_lossy(&installed_bytes);

    let wanted = with_hangar_block(&installed, variables);
    if wanted != installed {
        let contents = (!wanted.is_empty()).then_some(wanted.as_bytes());
        etc.update_file(ZSHENV, contents, FILE_MODE, Owner::Root)
            .map_err(|error| Error::file("update", &path, error))?;
    }

    let removed_names = hangar_block_names(&installed)
        .into_iter()
        .filter(|name| !variables.iter().any(|(wanted, _)| wanted == name))
        .collect();
    Ok(removed_names)
}

/// launchd hands its environment to every app it starts in the user's session. It is set again on
/// every command, since a session starts without it; nobody at the screen means nothing to set.
fn set_app_variables(variables: &[(String, String)], removed_names: &[String]) -> Result<()> {
    let Some(uid) = macos::console_user_id() else {
        return Ok(());
    };
    let uid = uid.to_string();

    if !removed_names.is_empty() {
        let mut arguments = vec!["asuser", uid.as_str(), LAUNCHCTL, "unsetenv"];
        arguments.extend(removed_names.iter().map(String::as_str));
        run(LAUNCHCTL, &arguments)?;
    }

    if !variables.is_empty() {
        let mut arguments = vec!["asuser", uid.as_str(), LAUNCHCTL, "setenv"];
        for (name, value) in variables {
            arguments.extend([name.as_str(), value.as_str()]);
        }
        run(LAUNCHCTL, &arguments)?;
    }
    Ok(())
}

fn run(program: &str, arguments: &[&str]) -> Result<()> {
    let status = Command::new(program)
        .args(arguments)
        .stdin(Stdio::null())
        .status();
    let subcommand = arguments.first().copied().unwrap_or_default();
    hangar_error::check_exit(format!("{program} {subcommand}"), status)
}

#[cfg(test)]
#[path = "trust_test.rs"]
mod tests;
