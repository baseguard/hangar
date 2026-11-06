use std::os::unix::process::ExitStatusExt;

use super::*;

#[test]
fn a_program_that_never_started_says_why() {
    let missing = io::Error::from(io::ErrorKind::NotFound);

    let error = check_exit("systemctl", Err(missing)).map_err(|error| error.to_string());

    assert_eq!(
        error,
        Err("Could not start systemctl: entity not found".to_string())
    );
}

#[test]
fn exit_codes_and_signals_are_told_apart() {
    let exited = check_exit("sudo", Ok(ExitStatus::from_raw(1 << 8)));
    let killed = check_exit("sudo", Ok(ExitStatus::from_raw(9)));
    let succeeded = check_exit("sudo", Ok(ExitStatus::from_raw(0)));

    assert_eq!(
        exited.map_err(|error| error.to_string()),
        Err("sudo failed (exit status 1).".to_string())
    );
    assert_eq!(
        killed.map_err(|error| error.to_string()),
        Err("sudo was stopped by a signal.".to_string())
    );
    assert!(succeeded.is_ok());
}

#[test]
fn a_changed_copy_says_so_in_the_sentence_hangar_shows() {
    assert_eq!(
        Error::CopiedAgentChanged.to_string(),
        "The copied agent changed before it could be installed."
    );
}
