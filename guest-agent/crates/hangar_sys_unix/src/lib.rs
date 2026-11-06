//! Unix system calls shared by the macOS and Linux agents: the user checks, port waits, and for
//! `hangar exec` the vsock port, accounts, pseudo-terminals and a command's own session.

#![cfg(unix)]

mod vsock;

use std::{
    ffi::{CStr, CString, c_char},
    fs::File,
    io,
    os::{
        fd::{AsFd, AsRawFd, FromRawFd},
        unix::process::CommandExt,
    },
    process::Command,
    ptr::null_mut,
    time::Duration,
};

pub use vsock::{VsockListener, VsockStream};

#[cfg(target_os = "macos")]
const TIOCSCTTY: libc::c_ulong = 0x2000_7461;
#[cfg(target_os = "macos")]
const TIOCSWINSZ: libc::c_ulong = 0x8008_7467;
#[cfg(not(target_os = "macos"))]
use libc::{TIOCSCTTY, TIOCSWINSZ};

/// Large enough for any entry of the password database.
const PASSWD_BUFFER: usize = 16 * 1024;
/// More groups than any account in a guest belongs to.
const GROUP_LIMIT: usize = 256;

/// The process runs with root's rights, as under `sudo` or as a launchd daemon.
pub fn is_root() -> bool {
    effective_uid() == 0
}

pub fn effective_uid() -> u32 {
    // SAFETY: `geteuid` takes no arguments and POSIX guarantees it always succeeds.
    unsafe { libc::geteuid() }
}

pub fn user_id() -> u32 {
    // SAFETY: `getuid` has no preconditions and can't fail.
    unsafe { libc::getuid() }
}

/// Waits up to `timeout` for `port` to have bytes to read, or to report its end; false when the
/// time ran out first.
pub fn wait_readable(port: &impl AsFd, timeout: Duration) -> io::Result<bool> {
    let mut entry = libc::pollfd {
        fd: port.as_fd().as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };
    let milliseconds = libc::c_int::try_from(timeout.as_millis()).unwrap_or(libc::c_int::MAX);

    // SAFETY: `entry` is one valid `pollfd` whose fd stays open for the call.
    match unsafe { libc::poll(&raw mut entry, 1, milliseconds) } {
        -1 if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted => Ok(false),
        -1 => Err(io::Error::last_os_error()),
        0 => Ok(false),
        // A read of an fd poll can't watch would wait past any stop.
        _ if entry.revents & libc::POLLNVAL != 0 => Err(io::ErrorKind::InvalidInput.into()),
        _ => Ok(true),
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
    let name = CString::new(name).ok()?;
    lookup(|entry, buffer, result| {
        // SAFETY: `name` is NUL-terminated; `entry`, `buffer` and `result` point at locals of
        // `lookup` that outlive the call, and `buffer`'s length is passed with it.
        unsafe {
            libc::getpwnam_r(
                name.as_ptr(),
                entry,
                buffer.as_mut_ptr(),
                buffer.len(),
                result,
            )
        }
    })
}

/// The account this process runs as.
pub fn current_account() -> Option<Account> {
    account_with_id(user_id())
}

pub fn account_with_id(uid: u32) -> Option<Account> {
    lookup(|entry, buffer, result| {
        // SAFETY: as in `account_named`.
        unsafe { libc::getpwuid_r(uid, entry, buffer.as_mut_ptr(), buffer.len(), result) }
    })
}

fn lookup(
    call: impl FnOnce(&mut libc::passwd, &mut [c_char], &mut *mut libc::passwd) -> libc::c_int,
) -> Option<Account> {
    // SAFETY: `passwd` is plain C data, and all zeros is a valid value for it.
    let mut entry: libc::passwd = unsafe { std::mem::zeroed() };
    let mut buffer: Vec<c_char> = vec![0; PASSWD_BUFFER];
    let mut result = null_mut();
    if call(&mut entry, &mut buffer, &mut result) != 0 || result.is_null() {
        return None;
    }

    Some(Account {
        name: text(entry.pw_name)?,
        uid: entry.pw_uid,
        gid: entry.pw_gid,
        home: text(entry.pw_dir)?,
        shell: text(entry.pw_shell)?,
    })
}

fn text(pointer: *const c_char) -> Option<String> {
    if pointer.is_null() {
        return None;
    }
    // SAFETY: the password database's strings are NUL-terminated and live in the lookup's buffer,
    // which is still alive here.
    let text = unsafe { CStr::from_ptr(pointer) };
    text.to_str().ok().map(str::to_owned)
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
    let size = window_size(columns, rows);
    let mut controller = -1;
    let mut terminal = -1;
    // SAFETY: the two descriptors are locals the call writes; a null name and termios are
    // allowed; `size` outlives the call.
    let opened = unsafe {
        libc::openpty(
            &raw mut controller,
            &raw mut terminal,
            null_mut(),
            null_mut(),
            (&raw const size).cast_mut(),
        )
    };
    if opened != 0 {
        return Err(io::Error::last_os_error());
    }

    // SAFETY: `openpty` returned two new descriptors that nothing else owns.
    let (controller, terminal) =
        unsafe { (File::from_raw_fd(controller), File::from_raw_fd(terminal)) };
    close_on_exec(&controller)?;
    close_on_exec(&terminal)?;
    Ok(Pty {
        controller,
        terminal,
    })
}

/// glibc before 2.34 keeps `openpty` in libutil, so the POSIX calls open the pair instead.
#[cfg(not(target_os = "macos"))]
pub fn open_pty(columns: u16, rows: u16) -> io::Result<Pty> {
    // SAFETY: `posix_openpt` takes flags only and returns a new descriptor or -1.
    let raw = unsafe { libc::posix_openpt(libc::O_RDWR | libc::O_NOCTTY | libc::O_CLOEXEC) };
    if raw < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: `raw` is the new descriptor `posix_openpt` returned; nothing else owns it.
    let controller = unsafe { File::from_raw_fd(raw) };

    // SAFETY: `controller` is an open pseudo-terminal controller.
    if unsafe { libc::grantpt(controller.as_raw_fd()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: as above.
    if unsafe { libc::unlockpt(controller.as_raw_fd()) } != 0 {
        return Err(io::Error::last_os_error());
    }

    let mut name: [c_char; 128] = [0; 128];
    // SAFETY: `name` is a local buffer whose length is passed with it.
    if unsafe { libc::ptsname_r(controller.as_raw_fd(), name.as_mut_ptr(), name.len()) } != 0 {
        return Err(io::Error::last_os_error());
    }

    // SAFETY: `ptsname_r` wrote a NUL-terminated path into `name`.
    let raw = unsafe {
        libc::open(
            name.as_ptr(),
            libc::O_RDWR | libc::O_NOCTTY | libc::O_CLOEXEC,
        )
    };
    if raw < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: `raw` is the new descriptor `open` returned; nothing else owns it.
    let terminal = unsafe { File::from_raw_fd(raw) };
    set_terminal_size(&controller, columns, rows)?;
    Ok(Pty {
        controller,
        terminal,
    })
}

#[cfg(target_os = "macos")]
fn close_on_exec(file: &File) -> io::Result<()> {
    // SAFETY: `file` is an open descriptor; F_SETFD takes an int.
    if unsafe { libc::fcntl(file.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn window_size(columns: u16, rows: u16) -> libc::winsize {
    libc::winsize {
        ws_row: rows,
        ws_col: columns,
        ws_xpixel: 0,
        ws_ypixel: 0,
    }
}

/// Gives the command's terminal to its user, as `login` and `sshd` do, so programs that open it by
/// its path, like `screen`, can; the group stays the terminal group, with mode 0620.
pub fn give_terminal_to(terminal: &File, uid: u32) -> io::Result<()> {
    // SAFETY: `terminal` is an open descriptor; a group of -1 leaves the group as it is.
    if unsafe { libc::fchown(terminal.as_raw_fd(), uid, libc::gid_t::MAX) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: as above.
    if unsafe { libc::fchmod(terminal.as_raw_fd(), 0o620) } != 0 {
        return Err(io::Error::last_os_error());
    }
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
            if libc::setsid() < 0 {
                return Err(io::Error::last_os_error());
            }
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
    // SAFETY: `killpg` takes plain values; a group that is already gone just fails.
    unsafe { libc::killpg(group, libc::SIGKILL) };
}
