//! Who gets the clipboard pipe and where SYSTEM runs the agent from. The facts come from the
//! system through the traits here, so the tests run on any host with fake ones.

use std::{
    io,
    path::{Path, PathBuf},
    time::Duration,
};

/// How long the console's user may be without a session helper before the service starts one;
/// longer than Windows takes to run the Run value's helper after a sign-in.
pub(crate) const HELPER_GRACE: Duration = Duration::from_secs(10);
/// A helper the service started may wait this long to take over from one that doesn't quit.
pub(crate) const HELPER_START_PAUSE: Duration = Duration::from_secs(30);

/// `O:SY` makes SYSTEM the owner, which the helper checks: a pipe SYSTEM makes is otherwise owned
/// by Administrators, so any of them could have made it. Interactive users may read and write, but
/// not add instances of their own: `GW` would include `FILE_CREATE_PIPE_INSTANCE`.
#[cfg_attr(
    not(windows),
    expect(dead_code, reason = "only the Windows service serves the pipes")
)]
pub(crate) const PIPE_ACCESS: &str = "O:SYD:P(A;;GA;;;SY)(A;;0x12019b;;;IU)";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Account {
    System,
    Administrators,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ItemKind {
    Folder,
    /// A symbolic link, junction or other reparse point.
    Link,
    Other,
}

/// What each end of the clipboard pipe can learn about the other.
pub(crate) trait PipeFacts {
    fn client_process_id(&self) -> Option<u32>;
    fn client_session_id(&self) -> Option<u32>;
    fn console_session_id(&self) -> u32;
    fn program_of(&self, process: u32) -> Option<PathBuf>;
    fn server_session_id(&self) -> Option<u32>;
    fn server_owned_by(&self, account: Account) -> io::Result<bool>;
}

/// An item opened without following a link at its end.
pub(crate) trait ItemFacts {
    fn kind(&self) -> io::Result<ItemKind>;
    fn owned_by(&self, account: Account) -> io::Result<bool>;
}

/// The service relays the clipboard only to its own program in the console session, the one on
/// the VM's display.
pub(crate) fn client_is_console_helper(pipe: &impl PipeFacts, this_program: &Path) -> bool {
    let (Some(process), Some(session)) = (pipe.client_process_id(), pipe.client_session_id())
    else {
        return false;
    };

    if session != pipe.console_session_id() {
        return false;
    }

    pipe.program_of(process)
        .is_some_and(|client| same_path(&client, this_program))
}

/// Every signed-in user runs a session helper; only the one on the VM's display may use the
/// clipboard and `hangar exec`.
#[cfg(windows)]
pub(crate) fn is_console_session(own: Option<u32>, console: u32) -> bool {
    own == Some(console)
}

/// Whether the service starts a session helper for the user at the screen, who has had none
/// waiting for `missing_for`; a helper that arrived within the grace time is busy, not missing.
pub(crate) fn should_start_helper(
    missing_for: Duration,
    since_helper_arrived: Option<Duration>,
    since_last_start: Option<Duration>,
) -> bool {
    let has_arrived_lately = since_helper_arrived.is_some_and(|since| since < HELPER_GRACE);
    let has_waited_for_last = since_last_start.is_none_or(|since| since >= HELPER_START_PAUSE);
    missing_for >= HELPER_GRACE && !has_arrived_lately && has_waited_for_last
}

/// A pipe of the same name made by anyone but the SYSTEM service could read the clipboard.
pub(crate) fn served_by_system(pipe: &impl PipeFacts) -> bool {
    pipe.server_session_id() == Some(0) && pipe.server_owned_by(Account::System).unwrap_or(false)
}

/// SYSTEM runs the agent from `path`, so a folder or link some user put there could hand SYSTEM
/// their program.
pub(crate) fn check_agent_folder(path: &Path, folder: &impl ItemFacts) -> io::Result<()> {
    if folder.kind()? != ItemKind::Folder {
        return Err(io::Error::other(format!(
            "{} is a link or the wrong kind of item.",
            path.display()
        )));
    }

    let trusted = folder.owned_by(Account::System)? || folder.owned_by(Account::Administrators)?;
    if !trusted {
        return Err(io::Error::other(format!(
            "{} isn't owned by SYSTEM or Administrators.",
            path.display()
        )));
    }

    Ok(())
}

fn same_path(first: &Path, second: &Path) -> bool {
    first.as_os_str().eq_ignore_ascii_case(second.as_os_str())
}

#[cfg(test)]
#[path = "policy_test.rs"]
mod tests;
