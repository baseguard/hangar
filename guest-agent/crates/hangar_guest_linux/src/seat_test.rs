use super::*;

const SEAT: &str = "# This is private data. Do not parse.\nIS_SEAT0=1\nACTIVE=2\nACTIVE_UID=1000\n";

#[test]
fn the_user_at_the_screen_is_active() {
    assert!(is_active_user(SEAT, 1000));
}

#[test]
fn only_a_users_own_session_counts_as_someone_at_the_screen() {
    let greeter = "# This is private data. Do not parse.\nUID=113\nUSER=Debian-gdm\nACTIVE=1\nCLASS=greeter\n";
    let user = "UID=1000\nUSER=dev\nACTIVE=1\nCLASS=user\n";

    assert_eq!(active_session(SEAT), Some("2"));
    assert!(!is_user_session(greeter));
    assert!(is_user_session(user));
}

#[test]
fn a_session_name_that_isnt_plain_is_ignored() {
    assert_eq!(active_session("ACTIVE=../../etc/passwd\n"), None);
    assert_eq!(active_session("ACTIVE=\n"), None);
    assert_eq!(active_session("IS_SEAT0=1\n"), None);
}

#[test]
fn the_record_names_the_user_at_the_screen() {
    assert_eq!(active_user(SEAT), Some(1000));
    assert_eq!(active_user("IS_SEAT0=1\n"), None);
}

#[test]
fn other_users_are_not() {
    assert!(!is_active_user(SEAT, 1001));
    assert!(!is_active_user(SEAT, 0));
}

#[test]
fn an_unreadable_record_means_nobody() {
    let unreadable = Err(io::ErrorKind::NotFound.into());

    assert!(!is_at_the_screen(unreadable, 1000));
    assert!(is_at_the_screen(Ok(SEAT.to_string()), 1000));
}

#[test]
fn a_missing_or_garbled_record_means_nobody() {
    assert!(!is_active_user("", 1000));
    assert!(!is_active_user("IS_SEAT0=1\nACTIVE=2\n", 1000));
    assert!(!is_active_user("ACTIVE_UID=x1000\n", 1000));
    assert!(!is_active_user("ACTIVE_UID=-1\n", 1000));
}
