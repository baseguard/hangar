//! Who runs a command, and the environment it starts with.

use std::process::Command;

use hangar_sys_unix::Account;

/// The user at the guest's screen, or else the VM's own account the host names. Never root:
/// a command that needs root says `sudo` itself.
pub fn choose_account(
    at_screen: Option<Account>,
    vm_account: Option<&str>,
    find: impl Fn(&str) -> Option<Account>,
) -> Result<Account, String> {
    if let Some(account) = at_screen.filter(|account| account.uid != 0) {
        return Ok(account);
    }

    let Some(name) = vm_account else {
        return Err(
            "Nobody is signed in at the guest's screen, and the VM has no account set; \
                    set one with: hangar set <vm> --ssh-user <name>"
                .into(),
        );
    };
    let Some(account) = find(name) else {
        return Err(format!(
            "Nobody is signed in at the guest's screen, and the VM's account '{name}' isn't in \
             the guest."
        ));
    };
    if account.uid == 0 {
        return Err(
            "hangar exec doesn't run commands as root; put sudo in front of the command.".into(),
        );
    }
    Ok(account)
}

/// A command that starts in `account`'s home with a plain login environment: nothing of the
/// agent's own environment goes along.
pub fn user_command(
    program: &str,
    arguments: &[String],
    account: &Account,
    path: &str,
    tty: bool,
) -> Command {
    let mut command = Command::new(program);
    command
        .args(arguments)
        .env_clear()
        .env("HOME", &account.home)
        .env("USER", &account.name)
        .env("LOGNAME", &account.name)
        .env("SHELL", &account.shell)
        .env("PATH", path)
        .env("LANG", "en_US.UTF-8")
        .current_dir(&account.home);
    if tty {
        command.env("TERM", "xterm-256color");
    }
    command
}

#[cfg(test)]
#[path = "account_test.rs"]
mod tests;
