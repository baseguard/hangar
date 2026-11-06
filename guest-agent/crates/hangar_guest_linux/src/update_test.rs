use super::*;

#[test]
fn the_unit_runs_roots_copy_with_install_and_is_collected() {
    let arguments = install_unit_arguments(UPDATE_PROGRAM);

    assert_eq!(
        arguments,
        [
            "--collect",
            "--quiet",
            "--unit",
            "hangar-agent-update.service",
            "/usr/local/libexec/hangar-agent-update",
            "install",
        ]
    );
}

#[test]
fn updating_without_root_says_to_use_sudo() {
    // As root this would update the agent on the machine running the tests.
    if hangar_sys_unix::is_root() {
        return;
    }

    let error = run(Sha256::of(b"")).map_err(|error| error.to_string());

    assert_eq!(
        error,
        Err("hangar-agent update needs root: run it with sudo.".to_string())
    );
}
