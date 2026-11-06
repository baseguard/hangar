use super::*;

#[test]
fn only_plain_user_names_are_restarted() {
    let listing = "1000 dev no active\n1001 a@b no active\n1002 ünal no active\n\n\
                   1003 ana.k_2 no online\n";

    assert_eq!(user_names(listing), vec!["dev", "ana.k_2"]);
}

#[test]
fn failures_name_the_command_and_its_status() {
    assert!(run_program("true", &[]).is_ok());

    let failed = run_program("false", &["--ignored"]).map_err(|error| error.to_string());
    assert_eq!(
        failed,
        Err("false --ignored failed (exit status 1).".to_string())
    );
}

#[test]
fn a_folder_the_user_owns_is_not_roots_own() -> Result<(), Box<dyn std::error::Error>> {
    let folder = std::env::temp_dir().join(format!("hangar-root-check-{}", std::process::id()));
    fs::create_dir_all(&folder)?;
    let path = folder.to_str().ok_or("the temporary folder isn't UTF-8")?;

    let opened = open_roots_folder(path).map(|_folder| ());

    fs::remove_dir_all(&folder)?;
    // As root the folder would be root's own.
    assert!(opened.is_err() || hangar_sys_unix::is_root());
    Ok(())
}
