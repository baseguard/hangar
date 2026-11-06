//! Unix system calls shared by the macOS and Linux agents: the user checks, port waits, and for
//! `hangar exec` the vsock port, accounts, pseudo-terminals and a command's own session.

#![cfg(unix)]

mod vsock;

use std::{
    ffi::CString,
    fs::File,
    io,
    os::{
        fd::{AsFd, AsRawFd},
        unix::process::CommandExt,
    },
    process::Command,
    time::Duration,
};

use nix::{
    errno::Errno,
    poll::{PollFd, PollFlags, PollTimeout, poll},
    pty::Winsize,
    sys::{
        signal::{Signal, killpg},
        stat::{Mode, fchmod},
    },
    unistd::{Pid, Uid, User, fchown, geteuid, getuid, setsid},
};

pub use vsock::{VsockListener, VsockStream};

#[cfg(target_os = "macos")]
const TIOCSCTTY: libc::c_ulong = 0x2000_7461;
#[cfg(target_os = "macos")]
const TIOCSWINSZ: libc::c_ulong = 0x8008_7467;
#[cfg(not(target_os = "macos"))]
use libc::{TIOCSCTTY, TIOCSWINSZ};

/// More groups than any account in a guest belongs to.
const GROUP_LIMIT: usize = 256;

/// The process runs with root's rights, as under `sudo` or as a launchd daemon.
pub fn is_root() -> bool {
    effective_uid() == 0
}

pub fn effective_uid() -> u32 {
    geteuid().as_raw()
}

pub fn user_id() -> u32 {
    getuid().as_raw()
}

/// Waits up to `timeout` for `port` to have bytes to read, or to report its end; false when the
/// time ran out first.
pub fn wait_readable(port: &impl AsFd, timeout: Duration) -> io::Result<bool> {
    let mut entries = [PollFd::new(port.as_fd(), PollFlags::POLLIN)];
    let timeout = PollTimeout::try_from(timeout).unwrap_or(PollTimeout::MAX);

    match poll(&mut entries, timeout) {
        Err(Errno::EINTR) | Ok(0) => Ok(false),
        Err(error) => Err(error.into()),
        // A read of an fd poll can't watch would wait past any stop.
        Ok(_)
            if entries[0]
                .revents()
                .is_some_and(|events| events.contains(PollFlags::POLLNVAL)) =>
        {
            Err(io::ErrorKind::InvalidInput.into())
        }
        Ok(_) => Ok(true),
    }
}

/// An entry of the guest's password database.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Account {
    pub name: String,
    pub uid: u32,
    pub gid: u32,
    pub home: String,
    pub shell: String,
}

pub fn account_named(name: &str) -> Option<Account> {
    account(User::from_name(name))
}

/// The account this process runs as.
pub fn current_account() -> Option<Account> {
    account_with_id(user_id())
}

pub fn account_with_id(uid: u32) -> Option<Account> {
    account(User::from_uid(Uid::from_raw(uid)))
}

/// `None` for no such account, a failed lookup, or a home or shell that isn't UTF-8.
fn account(lookup: nix::Result<Option<User>>) -> Option<Account> {
    let user = lookup.ok()??;
    Some(Account {
        uid: user.uid.as_raw(),
        gid: user.gid.as_raw(),
        home: user.dir.to_str()?.to_owned(),
        shell: user.shell.to_str()?.to_owned(),
        name: user.name,
    })
}

/// A pseudo-terminal: the agent reads and writes `controller`; the command gets `terminal` as its
/// standard input, output and error.
#[derive(Debug)]
pub struct Pty {
    pub controller: File,
    pub terminal: File,
}

#[cfg(target_os = "macos")]
pub fn open_pty(columns: u16, rows: u16) -> io::Result<Pty> {
    let pair = nix::pty::openpty(&window_size(columns, rows), None)?;
    let pty = Pty {
        controller: File::from(pair.master),
        terminal: File::from(pair.slave),
    };
    close_on_exec(&pty.controller)?;
    close_on_exec(&pty.terminal)?;
    Ok(pty)
}

/// glibc before 2.34 keeps `openpty` in libutil, so the POSIX calls open the pair instead.
#[cfg(not(target_os = "macos"))]
pub fn open_pty(columns: u16, rows: u16) -> io::Result<Pty> {
    use std::{fs::OpenOptions, os::fd::OwnedFd, os::unix::fs::OpenOptionsExt};

    use nix::{
        fcntl::OFlag,
        pty::{grantpt, posix_openpt, ptsname_r, unlockpt},
    };

    let controller = posix_openpt(OFlag::O_RDWR | OFlag::O_NOCTTY | OFlag::O_CLOEXEC)?;
    grantpt(&controller)?;
    unlockpt(&controller)?;
    // Rust opens files close-on-exec.
    let terminal = OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NOCTTY)
        .open(ptsname_r(&controller)?)?;

    let controller = File::from(OwnedFd::from(controller));
    set_terminal_size(&controller, columns, rows)?;
    Ok(Pty {
        controller,
        terminal,
    })
}

#[cfg(target_os = "macos")]
fn close_on_exec(file: &File) -> io::Result<()> {
    use nix::fcntl::{FcntlArg, FdFlag, fcntl};

    fcntl(file, FcntlArg::F_SETFD(FdFlag::FD_CLOEXEC))?;
    Ok(())
}

fn window_size(columns: u16, rows: u16) -> Winsize {
    Winsize {
        ws_row: rows,
        ws_col: columns,
        ws_xpixel: 0,
        ws_ypixel: 0,
    }
}

/// Gives the command's terminal to its user, as `login` and `sshd` do, so programs that open it by
/// its path, like `screen`, can; the group stays the terminal group, with mode 0620.
pub fn give_terminal_to(terminal: &File, uid: u32) -> io::Result<()> {
    fchown(terminal, Some(Uid::from_raw(uid)), None)?;
    fchmod(terminal, Mode::from_bits_truncate(0o620))?;
    Ok(())
}

pub fn set_terminal_size(controller: &impl AsFd, columns: u16, rows: u16) -> io::Result<()> {
    let size = window_size(columns, rows);
    // SAFETY: the descriptor is open; TIOCSWINSZ reads a `winsize` that outlives the call.
    let set = unsafe { libc::ioctl(controller.as_fd().as_raw_fd(), TIOCSWINSZ, &raw const size) };
    if set != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Starts `command` in a session of its own, so the whole session can be ended at once.
///
/// With `has_terminal`, its standard input becomes the session's controlling terminal. With
/// `account`, the command runs as that user, with the user's groups.
pub fn start_in_own_session(
    command: &mut Command,
    has_terminal: bool,
    account: Option<&Account>,
) -> io::Result<()> {
    // Read before the fork: only async-signal-safe calls may run between fork and exec.
    let user = match account {
        Some(account) => Some((account.uid, account.gid, groups_of(account)?)),
        None => None,
    };

    // SAFETY: the closure makes only async-signal-safe system calls on values computed before the
    // fork, and allocates nothing.
    unsafe {
        command.pre_exec(move || {
            setsid()?;
            if has_terminal && libc::ioctl(0, TIOCSCTTY, 0) != 0 {
                return Err(io::Error::last_os_error());
            }
            if let Some((uid, gid, groups)) = &user {
                switch_user(*uid, *gid, groups)?;
            }
            Ok(())
        });
    }
    Ok(())
}

/// # Safety
///
/// Called between fork and exec: system calls only.
unsafe fn switch_user(uid: u32, gid: u32, groups: &[libc::gid_t]) -> io::Result<()> {
    #[cfg(target_os = "macos")]
    let count = libc::c_int::try_from(groups.len()).unwrap_or(0);
    #[cfg(not(target_os = "macos"))]
    let count = groups.len();

    // SAFETY: `groups` holds `count` group ids and outlives the call; the caller guarantees we're
    // between fork and exec, where these calls change only the child.
    unsafe {
        if libc::setgroups(count, groups.as_ptr()) != 0
            || libc::setgid(gid) != 0
            || libc::setuid(uid) != 0
        {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

/// macOS's `getgrouplist` takes and gives the ids as `int`; Linux uses `gid_t`.
#[cfg(target_os = "macos")]
type GroupId = libc::c_int;
#[cfg(not(target_os = "macos"))]
type GroupId = libc::gid_t;

fn groups_of(account: &Account) -> io::Result<Vec<libc::gid_t>> {
    let name = CString::new(account.name.as_str())?;
    let mut count = libc::c_int::try_from(GROUP_LIMIT).unwrap_or(libc::c_int::MAX);
    let mut groups: Vec<GroupId> = vec![0; GROUP_LIMIT];
    #[cfg(target_os = "macos")]
    let base = libc::c_int::try_from(account.gid).unwrap_or(-1);
    #[cfg(not(target_os = "macos"))]
    let base = account.gid;

    // SAFETY: `name` is NUL-terminated; `groups` has room for `count` entries.
    let listed =
        unsafe { libc::getgrouplist(name.as_ptr(), base, groups.as_mut_ptr(), &raw mut count) };
    if listed < 0 {
        return Err(io::Error::other("the user is in too many groups"));
    }
    groups.truncate(usize::try_from(count).unwrap_or(0));

    #[cfg(target_os = "macos")]
    let groups: Vec<libc::gid_t> = groups.into_iter().map(i32::cast_unsigned).collect();
    Ok(groups)
}

/// Ends every process in the session `start_in_own_session` gave the command whose id is `pid`.
pub fn kill_session(pid: u32) {
    let Ok(group) = libc::pid_t::try_from(pid) else {
        return;
    };
    // A group that is already gone just fails.
    killpg(Pid::from_raw(group), Signal::SIGKILL).unwrap_or(());
}
