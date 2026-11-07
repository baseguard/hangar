//! Process-wide macOS calls: memory, the console user, passwords, serial ports and temporary
//! folders.

use std::{
    ffi::{CStr, CString, c_char, c_void},
    fs::File,
    io,
    os::fd::{AsFd, AsRawFd},
    ptr::{null, null_mut},
};

use nix::{
    sys::termios::{SetArg, cfmakeraw, tcgetattr, tcsetattr},
    unistd::{dup2_stderr, mkdtemp},
};

/// `RPP_ECHO_OFF`: `readpassphrase` reads without echoing.
const RPP_ECHO_OFF: i32 = 0;
/// The longest password `readpassphrase` reads, NUL included; longer input is cut off.
const PASSWORD_LIMIT: usize = 256;

#[link(name = "SystemConfiguration", kind = "framework")]
unsafe extern "C" {
    fn SCDynamicStoreCopyConsoleUser(
        store: *const c_void,
        uid: *mut libc::uid_t,
        gid: *mut libc::gid_t,
    ) -> *const c_void;
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(object: *const c_void);
}

// readpassphrase, in libSystem.
unsafe extern "C" {
    fn readpassphrase(
        prompt: *const c_char,
        buffer: *mut c_char,
        size: usize,
        flags: i32,
    ) -> *mut c_char;
}

/// `hw.memsize`, in bytes.
pub fn physical_memory() -> Option<u64> {
    let mut total: u64 = 0;
    let mut size = size_of::<u64>();

    // SAFETY: the name is NUL-terminated, and `total` is writable for the `size` bytes passed.
    let result = unsafe {
        libc::sysctlbyname(
            c"hw.memsize".as_ptr(),
            (&raw mut total).cast(),
            &raw mut size,
            null_mut(),
            0,
        )
    };

    if result != 0 {
        return None;
    }

    Some(total)
}

/// `host_statistics64` with `HOST_VM_INFO64`.
pub fn vm_statistics() -> Option<libc::vm_statistics64> {
    // SAFETY: `vm_statistics64` is plain data for which all-zero bytes are a valid value.
    let mut statistics: libc::vm_statistics64 = unsafe { std::mem::zeroed() };
    let mut count = libc::HOST_VM_INFO64_COUNT;

    // SAFETY: `statistics` is writable for `count` integers, the size `HOST_VM_INFO64` fills.
    let result = unsafe {
        libc::host_statistics64(
            host_port(),
            libc::HOST_VM_INFO64,
            (&raw mut statistics).cast(),
            &raw mut count,
        )
    };

    if result != libc::KERN_SUCCESS {
        return None;
    }

    Some(statistics)
}

#[expect(
    deprecated,
    reason = "libc points to the mach2 crate for Mach calls; one call doesn't justify it"
)]
fn host_port() -> libc::mach_port_t {
    // SAFETY: `mach_host_self` has no preconditions and can't fail.
    unsafe { libc::mach_host_self() }
}

pub fn page_size() -> Option<u64> {
    // SAFETY: `sysconf` has no preconditions.
    let size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
    u64::try_from(size).ok()
}

/// `readpassphrase` puts the terminal back even when the user presses Control-C.
pub fn read_password(prompt: &str) -> Option<String> {
    let prompt = CString::new(prompt).ok()?;
    let mut buffer: [c_char; PASSWORD_LIMIT] = [0; PASSWORD_LIMIT];

    // SAFETY: `prompt` is NUL-terminated, and `buffer` is writable for the length passed.
    let read = unsafe {
        readpassphrase(
            prompt.as_ptr(),
            buffer.as_mut_ptr(),
            buffer.len(),
            RPP_ECHO_OFF,
        )
    };

    let password = if read.is_null() {
        None
    } else {
        // SAFETY: on success `readpassphrase` leaves a NUL-terminated string in `buffer`.
        let text = unsafe { CStr::from_ptr(buffer.as_ptr()) };
        Some(text.to_string_lossy().into_owned())
    };

    wipe(&mut buffer);
    password
}

/// A plain `fill(0)` of a buffer nobody reads again is a dead store the compiler may drop;
/// volatile writes it keeps.
fn wipe(buffer: &mut [c_char]) {
    for byte in buffer.iter_mut() {
        // SAFETY: `byte` is a valid, aligned element of `buffer`, borrowed mutably here.
        unsafe { std::ptr::write_volatile(byte, 0) };
    }
    std::sync::atomic::compiler_fence(std::sync::atomic::Ordering::SeqCst);
}

/// Puts a serial port in raw mode so bytes pass through unchanged. A tty's line discipline
/// would otherwise echo what the host sends, turn `\n` into `\r\n` and act on control bytes.
pub fn make_raw(port: &impl AsFd) -> io::Result<()> {
    let mut settings = tcgetattr(port)?;
    cfmakeraw(&mut settings);
    tcsetattr(port, SetArg::TCSANOW, &settings)?;
    Ok(())
}

/// A new folder only this user can open, inside the user's temporary folder.
pub fn temporary_folder(prefix: &str) -> io::Result<String> {
    let template = std::env::temp_dir().join(format!("{prefix}.XXXXXX"));
    mkdtemp(&template)?
        .into_os_string()
        .into_string()
        .map_err(|_not_utf8| io::Error::from(io::ErrorKind::InvalidData))
}

/// Only one opening of the port at a time, so another user's agent can't read along; root still
/// can.
pub fn make_exclusive(port: &impl AsFd) -> io::Result<()> {
    let fd = port.as_fd().as_raw_fd();
    let request = libc::c_ulong::try_from(libc::TIOCEXCL)
        .map_err(|_negative| io::Error::from(io::ErrorKind::InvalidInput))?;
    // SAFETY: `fd` stays open for the call; `TIOCEXCL` takes no argument.
    if unsafe { libc::ioctl(fd, request) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// From here on the process's stderr, panics included, goes to `file`.
/// fd 2 becomes a copy of `file`, which stays open after `file` closes.
pub fn send_stderr_to(file: &File) -> io::Result<()> {
    dup2_stderr(file)?;
    Ok(())
}

/// The user signed in at the screen; `None` at the login window, which runs as root.
pub fn console_user_id() -> Option<u32> {
    let mut uid: libc::uid_t = 0;
    // SAFETY: a null store asks for a temporary session; `uid` is a local the call writes; a null
    // group pointer is allowed.
    let name = unsafe { SCDynamicStoreCopyConsoleUser(null(), &raw mut uid, null_mut()) };
    if name.is_null() {
        return None;
    }

    // SAFETY: `name` is a CFString this code owns ("Copy" rule) and releases once.
    unsafe { CFRelease(name) };
    (uid != 0).then_some(uid)
}

#[cfg(test)]
#[path = "system_test.rs"]
mod tests;
