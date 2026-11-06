use super::*;

#[test]
fn a_user_sudo_refuses_is_told_from_a_wrong_password() {
    assert!(is_refused_user(
        "admin is not in the sudoers file.  This incident will be reported.\n"
    ));
    assert!(is_refused_user(
        "Sorry, user guest is not allowed to run sudo on mac.\n"
    ));
    assert!(!is_refused_user(
        "Sorry, try again.\nsudo: no password was provided\n"
    ));
}
