//! Root for the system part, the tools and `update`: `sudo` without a password where it is set up
//! so, or with the user's password written to `sudo -S` through a pipe, so it never lands on disk.

use std::{
    env,
    io::{self, IsTerminal, Write},
    process::{Child, Command, Stdio},
};

use hangar_error::{Error, Exit, Result};
use hangar_sys_macos as macos;

use super::{say, succeeds_quietly};

/// `None`, after telling the user, when there is no terminal to ask for the password on. The
/// password is asked once and checked here, then reused for every step.
pub(super) fn ask_for_sudo() -> Result<Option<PipedSudo>> {
    if can_sudo_without_password() {
        return Ok(Some(PipedSudo { password: None }));
    }

    if !io::stdin().is_terminal() {
        say(
            "Open this in Terminal to finish: the agent's system part, the Command Line Tools and \
             Homebrew need your password.",
        );
        return Ok(None);
    }

    let sudo = PipedSudo {
        password: Some(read_user_password()?),
    };
    match sudo.check_password()? {
        PasswordCheck::Accepted => Ok(Some(sudo)),
        PasswordCheck::WrongPassword => Err(Error::Plain("sudo didn't accept the password.")),
        PasswordCheck::NotAnAdministrator => Err(Error::Plain(
            "Setting up Hangar's agent needs an administrator account.",
        )),
    }
}

/// What `sudo` said to the password; setup and `update` word a refusal each for their own reader.
enum PasswordCheck {
    Accepted,
    WrongPassword,
    NotAnAdministrator,
}

/// `sudo` without a password where it is set up so, or with the user's password, written to
/// `sudo -S` through a pipe.
pub(super) struct PipedSudo {
    /// `None` where `sudo` needs no password.
    password: Option<String>,
}

impl PipedSudo {
    /// Checks the password first, so a missing or wrong one changes nothing.
    pub(super) fn for_update(password: Option<&str>) -> Result<PipedSudo> {
        if can_sudo_without_password() {
            return Ok(PipedSudo { password: None });
        }

        let Some(password) = password else {
            return Err(Error::NeedsPassword);
        };
        let sudo = PipedSudo {
            password: Some(password.to_string()),
        };
        match sudo.check_password()? {
            PasswordCheck::Accepted => Ok(sudo),
            PasswordCheck::WrongPassword => Err(Error::NeedsPassword),
            PasswordCheck::NotAnAdministrator => Err(Error::Plain(
                "Updating Hangar's agent needs an administrator account in the VM.",
            )),
        }
    }

    /// Runs `arguments` (a program and its arguments) as root.
    pub(super) fn run(&self, arguments: &[&str]) -> Result<()> {
        let mut command = self.command(arguments);
        command.stdout(Stdio::null());

        let status = self.start(&mut command).and_then(|mut sudo| sudo.wait());
        hangar_error::check_exit(program_name(arguments), status)
    }

    /// Runs `arguments` as root, printing what it prints for the person watching in Terminal.
    pub(super) fn run_showing_output(&self, arguments: &[&str]) -> Result<()> {
        let mut command = self.command(arguments);

        let status = self.start(&mut command).and_then(|mut sudo| sudo.wait());
        hangar_error::check_exit(program_name(arguments), status)
    }

    /// Programs that run `sudo` themselves, like Homebrew's installer, can't get the password
    /// through a pipe; they use the one `sudo` remembers for this terminal for a few minutes.
    /// Without `-k`, so `sudo` remembers it.
    pub(super) fn let_sudo_remember_password(&self) -> Result<()> {
        if self.password.is_none() {
            return Ok(());
        }

        let mut command = Command::new("/usr/bin/sudo");
        command.args(["-S", "-p", "", "-v"]).stdout(Stdio::null());

        let status = self.start(&mut command).and_then(|mut sudo| sudo.wait());
        hangar_error::check_exit("sudo", status)
    }

    /// Runs `arguments` as root and returns what the program printed.
    pub(super) fn output(&self, arguments: &[&str]) -> Result<String> {
        let mut command = self.command(arguments);
        command.stdout(Stdio::piped());

        let name = program_name(arguments);
        let output = self
            .start(&mut command)
            .and_then(Child::wait_with_output)
            .map_err(|error| Error::program(name, Exit::NotStarted(error.to_string())))?;
        hangar_error::check_exit(name, Ok(output.status))?;

        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    }

    /// Starts `arguments` as root in a session of its own and returns without waiting; what it
    /// prints goes to `log`.
    pub(super) fn start_detached(&self, arguments: &[&str], log: Stdio) -> Result<()> {
        let mut command = self.command(arguments);
        command.stdout(Stdio::null()).stderr(log);
        hangar_sys_unix::start_in_own_session(&mut command, false, None)
            .map_err(|error| Error::step("start the update's system part", error))?;

        self.start(&mut command)
            .map(drop)
            .map_err(|error| Error::step("start the update's system part", error))
    }

    /// `sudo`'s English message tells a user who may not use `sudo` from a wrong password.
    fn check_password(&self) -> Result<PasswordCheck> {
        let mut command = self.command(&["/usr/bin/true"]);
        command
            .env("LC_ALL", "C")
            .stdout(Stdio::null())
            .stderr(Stdio::piped());

        let checked = self
            .start(&mut command)
            .and_then(Child::wait_with_output)
            .map_err(|error| Error::step("run sudo", error))?;
        if checked.status.success() {
            return Ok(PasswordCheck::Accepted);
        }

        if is_refused_user(&String::from_utf8_lossy(&checked.stderr)) {
            return Ok(PasswordCheck::NotAnAdministrator);
        }
        Ok(PasswordCheck::WrongPassword)
    }

    /// `-k` makes `sudo` ask every time, so it always reads the password line and the program never
    /// gets it as input; `-p ''` keeps its prompt out of the output.
    fn command(&self, arguments: &[&str]) -> Command {
        let mut command = Command::new("/usr/bin/sudo");
        match self.password {
            None => command.arg("-n"),
            Some(_) => command.args(["-k", "-S", "-p", ""]),
        };
        command.args(arguments);
        command
    }

    fn start(&self, command: &mut Command) -> io::Result<Child> {
        let Some(password) = &self.password else {
            return command.stdin(Stdio::null()).spawn();
        };

        let mut sudo = command.stdin(Stdio::piped()).spawn()?;
        if let Some(mut input) = sudo.stdin.take() {
            // A `sudo` that ends without reading fails on its own, which its exit status reports.
            let _unread = input.write_all(format!("{password}\n").as_bytes());
        }
        Ok(sudo)
    }
}

fn program_name<'a>(arguments: &[&'a str]) -> &'a str {
    let program = arguments.first().copied().unwrap_or("sudo");
    program.rsplit('/').next().unwrap_or(program)
}

fn is_refused_user(sudo_message: &str) -> bool {
    sudo_message.contains("not in the sudoers")
        || sudo_message.contains("is not allowed to run sudo")
}

/// -k ignores a cached sudo timestamp, which could expire while the Command Line Tools download.
fn can_sudo_without_password() -> bool {
    succeeds_quietly("/usr/bin/sudo", &["-n", "-k", "true"])
}

fn read_user_password() -> Result<String> {
    let user = env::var("USER").unwrap_or_default();
    let prompt =
        format!("Password for {user} (for Hangar's agent, the Command Line Tools and Homebrew): ");

    let password =
        macos::read_password(&prompt).ok_or(Error::Plain("Could not read the password."))?;

    if password.is_empty() {
        return Err(Error::Plain("The password can't be empty."));
    }

    Ok(password)
}

#[cfg(test)]
#[path = "sudo_test.rs"]
mod tests;
