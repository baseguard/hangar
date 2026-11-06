use super::*;

#[test]
fn the_password_is_the_line_without_its_ending() {
    assert_eq!(password_in_line("secret\n"), Some("secret"));
    assert_eq!(password_in_line("secret\r\n"), Some("secret"));
    assert_eq!(password_in_line("secret"), Some("secret"));
    assert_eq!(password_in_line(" two words \n"), Some(" two words "));
}

#[test]
fn an_empty_line_or_no_line_means_no_password() {
    assert_eq!(password_in_line(""), None);
    assert_eq!(password_in_line("\n"), None);
    assert_eq!(password_in_line("\r\n"), None);
}

#[test]
fn roots_copy_is_beside_the_system_part_in_roots_folder() {
    let expected = format!("{HELPER_FOLDER}/{}.update", super::super::DAEMON_LABEL);

    assert_eq!(ROOT_COPY, expected);
}

#[test]
fn a_folder_the_user_owns_is_not_roots_own() -> std::result::Result<(), Box<dyn std::error::Error>>
{
    let folder = std::env::temp_dir().join(format!("hangar-root-check-{}", std::process::id()));
    fs::create_dir_all(&folder)?;
    let path = folder.to_str().ok_or("the temporary folder isn't UTF-8")?;

    let checked = check_only_root_can_write(path).map_err(|error| error.to_string());

    fs::remove_dir_all(&folder)?;
    // As root the folder would be root's own.
    assert!(checked.is_err() || hangar_sys_unix::is_root());
    Ok(())
}
