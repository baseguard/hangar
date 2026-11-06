use super::*;

fn account(name: &str, uid: u32) -> Account {
    Account {
        name: name.into(),
        uid,
        gid: 20,
        home: format!("/Users/{name}"),
        shell: "/bin/zsh".into(),
    }
}

fn find(name: &str) -> Option<Account> {
    match name {
        "admin" => Some(account("admin", 501)),
        "root" => Some(account("root", 0)),
        _ => None,
    }
}

#[test]
fn the_user_at_the_screen_comes_first() {
    let chosen = choose_account(Some(account("dev", 502)), Some("admin"), find);

    assert_eq!(chosen.unwrap().name, "dev");
}

#[test]
fn the_vm_account_is_used_when_nobody_is_at_the_screen() {
    assert_eq!(
        choose_account(None, Some("admin"), find).unwrap().name,
        "admin"
    );
    assert_eq!(
        choose_account(Some(account("root", 0)), Some("admin"), find)
            .unwrap()
            .name,
        "admin"
    );
}

#[test]
fn root_and_unknown_accounts_are_refused_with_the_fix() {
    let root = choose_account(None, Some("root"), find).unwrap_err();
    let unknown = choose_account(None, Some("ghost"), find).unwrap_err();
    let none = choose_account(None, None, find).unwrap_err();

    assert!(root.contains("put sudo in front"));
    assert!(unknown.contains("'ghost' isn't in the guest"));
    assert!(none.contains("hangar set <vm> --ssh-user"));
}

#[test]
fn a_user_command_carries_only_the_users_environment() {
    let command = user_command(
        "ls",
        &["-la".into()],
        &account("dev", 502),
        "/usr/bin:/bin",
        true,
    );

    let variables: Vec<_> = command
        .get_envs()
        .map(|(key, _)| key.to_string_lossy().into_owned())
        .collect();
    assert_eq!(
        variables,
        ["HOME", "LANG", "LOGNAME", "PATH", "SHELL", "TERM", "USER"]
    );
    assert_eq!(
        command.get_current_dir().unwrap().to_str(),
        Some("/Users/dev")
    );
}
