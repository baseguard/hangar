use super::*;

#[test]
fn raw_mode_needs_a_terminal() -> io::Result<()> {
    let file = std::fs::File::open("/dev/null")?;

    assert!(make_raw(&file).is_err());

    Ok(())
}

#[test]
fn temporary_folders_are_private() -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;

    let folder = temporary_folder("hangar-test")?;

    let mode = std::fs::metadata(&folder)?.permissions().mode();
    assert_eq!(mode & 0o777, 0o700);

    std::fs::remove_dir(folder)
}
