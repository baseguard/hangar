use std::{error, fs::Permissions, process};

use hangar_sys_macos as macos;

use super::{homebrew::*, tools::*, *};

type TestResult = std::result::Result<(), Box<dyn error::Error>>;

fn test_folder(name: &str) -> std::result::Result<String, Box<dyn error::Error>> {
    let folder = env::temp_dir().join(format!("hangar-{name}-{}", process::id()));
    fs::create_dir_all(&folder)?;
    let folder = folder.to_str().ok_or("the temporary folder isn't UTF-8")?;
    Ok(folder.to_string())
}

#[test]
fn the_daemon_plist_runs_roots_copy_and_escapes_its_path() {
    let plist = launch_daemon_plist("/Library/a&b/<c>");

    assert!(plist.contains("<string>/Library/a&amp;b/&lt;c&gt;</string>"));
    assert!(plist.contains("<string>io.baseguard.hangar.guest-daemon</string>"));
    assert!(plist.contains("<string>report</string>"));
    assert!(!plist.contains("EnvironmentVariables"));
}

#[test]
fn installing_the_system_part_without_root_writes_nothing() {
    // As root this would install the system part on the machine running the tests.
    if hangar_sys_unix::is_root() {
        return;
    }

    let error = daemon().map_err(|error| error.to_string());

    assert_eq!(error, Err("Run this with sudo.".to_string()));
}

#[test]
fn the_plist_escapes_the_program_path() {
    let plist = launch_agent_plist("/Users/a&b/<c>/hangar-agent");

    assert!(plist.contains("<string>/Users/a&amp;b/&lt;c&gt;/hangar-agent</string>"));
    assert!(plist.contains("<string>io.baseguard.hangar.guest-agent</string>"));
    assert!(!plist.contains("a&b"));
}

#[test]
fn the_profile_gets_the_brew_line_once_and_keeps_its_mode() -> TestResult {
    let home = test_folder("profile")?;
    let profile = format!("{home}/.zprofile");
    fs::write(&profile, "export A=1")?;
    fs::set_permissions(&profile, Permissions::from_mode(0o600))?;

    add_homebrew_to_profile(&home)?;
    add_homebrew_to_profile(&home)?;

    let expected = format!("export A=1\neval \"$({BREW} shellenv)\"\n");
    assert_eq!(fs::read_to_string(&profile)?, expected);
    assert_eq!(permission_bits(&profile), Some(0o600));

    fs::remove_dir_all(home)?;
    Ok(())
}

#[test]
fn a_profile_that_isnt_text_is_left_alone() -> TestResult {
    let home = test_folder("binary-profile")?;
    let profile = format!("{home}/.zprofile");
    fs::write(&profile, b"export B=\xff\n")?;

    assert!(add_homebrew_to_profile(&home).is_err());
    assert_eq!(fs::read(&profile)?, b"export B=\xff\n");

    fs::remove_dir_all(home)?;
    Ok(())
}

#[test]
fn a_link_is_never_replaced() -> TestResult {
    let folder = test_folder("replace")?;
    let target = format!("{folder}/target");
    fs::write(&target, "keep")?;
    std::os::unix::fs::symlink(&target, format!("{folder}/link"))?;

    assert!(replace_file(&folder, "link", b"new", 0o644, Owner::ThisUser).is_err());
    assert_eq!(fs::read_to_string(&target)?, "keep");

    fs::remove_dir_all(folder)?;
    Ok(())
}

#[test]
fn the_tools_marker_never_follows_a_planted_link() -> TestResult {
    let folder = test_folder("marker")?;
    let marker = format!("{folder}/marker");
    let target = format!("{folder}/victim");
    fs::write(&target, "keep")?;
    std::os::unix::fs::symlink(&target, &marker)?;

    assert!(!mark_tools_wanted(&marker));
    assert_eq!(fs::read_to_string(&target)?, "keep");

    fs::remove_file(&marker)?;
    assert!(mark_tools_wanted(&marker));
    assert!(Path::new(&marker).is_file());

    fs::remove_dir_all(folder)?;
    Ok(())
}

#[test]
fn the_last_tools_label_is_installed() {
    let list = concat!(
        "Software Update found the following new or updated software:\n",
        "* Label: Command Line Tools for Xcode-16.0\r\n",
        "\tTitle: Command Line Tools for Xcode, Version: 16.0\n",
        "* Label: Safari18.1\n",
        "* Label: Command Line Tools for Xcode-16.1\n",
        "  * Label: Command Line Tools for Xcode-99 (indented, so not a label line)\n",
    );

    let label = command_line_tools_label(list);
    let none = command_line_tools_label("No new software available.\n");

    assert_eq!(label, Some("Command Line Tools for Xcode-16.1"));
    assert_eq!(none, None);
}

#[test]
fn digests_are_sha256() {
    let digest = |data: &[u8]| macos::sha256(data).map(|digest| hex(&digest));

    assert_eq!(
        digest(b"abc").as_deref(),
        Some("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    );

    assert_eq!(
        digest(b"").as_deref(),
        Some("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    );
}
