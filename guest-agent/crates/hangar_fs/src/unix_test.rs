use std::{
    error::Error,
    fs,
    os::unix::fs::symlink,
    path::PathBuf,
    sync::atomic::{AtomicUsize, Ordering},
};

use super::*;

type TestResult = Result<(), Box<dyn Error>>;

static NEXT: AtomicUsize = AtomicUsize::new(0);

fn folder() -> Result<(PathBuf, Dir), Box<dyn Error>> {
    let unique = NEXT.fetch_add(1, Ordering::Relaxed);
    let path = std::env::temp_dir().join(format!("hangar-fs-{}-{unique}", std::process::id()));

    fs::create_dir_all(&path)?;
    let dir = Dir::open(&path)?;
    Ok((path, dir))
}

#[test]
fn a_folder_that_is_a_link_is_refused() -> TestResult {
    let (path, _) = folder()?;
    symlink(&path, path.join("link"))?;

    let opened = Dir::open(path.join("link"));

    assert!(opened.is_err());

    fs::remove_dir_all(path)?;
    Ok(())
}

#[test]
fn a_log_past_its_limit_moves_aside_and_starts_empty() -> TestResult {
    let (path, dir) = folder()?;
    fs::write(path.join("agent.log.old"), "older")?;
    fs::write(path.join("agent.log"), "0123456789")?;

    let small = dir.open_log("agent.log", 10)?.metadata()?.len();
    let after_the_limit = dir.open_log("agent.log", 9)?.metadata()?.len();

    assert_eq!(small, 10);
    assert_eq!(after_the_limit, 0);
    assert_eq!(
        fs::read_to_string(path.join("agent.log.old"))?,
        "0123456789"
    );

    fs::remove_dir_all(path)?;
    Ok(())
}

#[test]
fn a_log_is_never_opened_through_a_link() -> TestResult {
    let (path, dir) = folder()?;
    fs::write(path.join("elsewhere"), "")?;
    symlink(path.join("elsewhere"), path.join("agent.log"))?;

    let opened = dir.open_log("agent.log", 10);

    assert!(opened.is_err());

    fs::remove_dir_all(path)?;
    Ok(())
}

#[test]
fn replacing_refuses_a_link_and_keeps_its_target() -> TestResult {
    let (path, dir) = folder()?;
    fs::write(path.join("target"), "kept")?;
    symlink(path.join("target"), path.join("settings"))?;

    let replaced = dir.replace_file("settings", b"new", 0o644, Owner::ThisUser);

    assert!(replaced.is_err());
    assert_eq!(fs::read_to_string(path.join("target"))?, "kept");

    fs::remove_dir_all(path)?;
    Ok(())
}

#[test]
fn updating_writes_only_what_changed_and_removes_for_none() -> TestResult {
    let (path, dir) = folder()?;

    let created = dir.update_file("settings", Some(b"one"), 0o644, Owner::ThisUser)?;
    let unchanged = dir.update_file("settings", Some(b"one"), 0o644, Owner::ThisUser)?;
    let changed = dir.update_file("settings", Some(b"two"), 0o644, Owner::ThisUser)?;
    let contents = fs::read_to_string(path.join("settings"))?;
    let removed = dir.update_file("settings", None, 0o644, Owner::ThisUser)?;
    let already_gone = dir.update_file("settings", None, 0o644, Owner::ThisUser)?;

    assert_eq!(
        [created, unchanged, changed, removed, already_gone],
        [true, false, true, true, false]
    );
    assert_eq!(contents, "two");
    assert!(!path.join("settings").exists());

    fs::remove_dir_all(path)?;
    Ok(())
}
