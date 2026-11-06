//! The guest's end of a vsock port: a listener that lets only the host in, and its connections.

use std::{
    io::{self, Read, Write},
    mem::zeroed,
    os::fd::{AsRawFd, FromRawFd, OwnedFd},
};

/// How many connections may wait to be accepted.
const BACKLOG: libc::c_int = 16;
/// Close-on-exec from the start on Linux, so a command another connection starts in that moment
/// can't inherit the descriptor. macOS has no such flag; there `close_on_exec` follows at once,
/// and commands start through `sudo`, which closes what they would inherit.
#[cfg(target_os = "linux")]
const SOCKET_TYPE: libc::c_int = libc::SOCK_STREAM | libc::SOCK_CLOEXEC;
#[cfg(not(target_os = "linux"))]
const SOCKET_TYPE: libc::c_int = libc::SOCK_STREAM;

/// A vsock port the guest listens on.
#[derive(Debug)]
pub struct VsockListener(OwnedFd);

/// One connection from the host; reads and writes may come from different threads.
#[derive(Debug)]
pub struct VsockStream(OwnedFd);

impl VsockListener {
    /// On Linux, a port below 1024 takes root to bind, so no other user can listen on it first.
    pub fn bind(port: u32) -> io::Result<VsockListener> {
        // SAFETY: `socket` takes plain values and returns a new descriptor or -1.
        let fd = unsafe { libc::socket(libc::AF_VSOCK, SOCKET_TYPE, 0) };
        let listener = VsockListener(owned(fd)?);
        close_on_exec(&listener.0)?;

        let address = address(libc::VMADDR_CID_ANY, port);
        // SAFETY: `address` is a valid `sockaddr_vm` that outlives the call, with its size.
        let bound = unsafe {
            libc::bind(
                listener.0.as_raw_fd(),
                (&raw const address).cast(),
                address_len(),
            )
        };
        if bound != 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: the descriptor is an open, bound socket.
        if unsafe { libc::listen(listener.0.as_raw_fd(), BACKLOG) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(listener)
    }

    /// The next connection from the host. A connection from anywhere else, such as a process in
    /// the guest itself through Linux's vsock loopback, is closed unanswered.
    pub fn accept_from_host(&self) -> io::Result<VsockStream> {
        loop {
            // SAFETY: an all-zero `sockaddr_vm` is a valid value for `accept` to fill.
            let mut peer: libc::sockaddr_vm = unsafe { zeroed() };
            let mut peer_len = address_len();
            let fd = accept(&self.0, &mut peer, &mut peer_len);
            let connection = match owned(fd) {
                Ok(connection) => connection,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            };
            close_on_exec(&connection)?;

            let peer_cid = peer.svm_cid;
            if peer_cid == libc::VMADDR_CID_HOST {
                return Ok(VsockStream(connection));
            }
        }
    }
}

impl VsockStream {
    pub fn try_clone(&self) -> io::Result<VsockStream> {
        let copy = self.0.try_clone()?;
        Ok(VsockStream(copy))
    }

    /// Ends the connection both ways, which also wakes a thread reading it.
    pub fn shut_down(&self) {
        // SAFETY: the descriptor is an open socket; shutting down one that is closed just fails.
        unsafe { libc::shutdown(self.0.as_raw_fd(), libc::SHUT_RDWR) };
    }
}

impl Read for VsockStream {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        // SAFETY: `buffer` is valid for writes of its length.
        let count =
            unsafe { libc::read(self.0.as_raw_fd(), buffer.as_mut_ptr().cast(), buffer.len()) };
        usize::try_from(count).map_err(|_negative| io::Error::last_os_error())
    }
}

impl Write for VsockStream {
    fn write(&mut self, data: &[u8]) -> io::Result<usize> {
        // SAFETY: `data` is valid for reads of its length.
        let count = unsafe { libc::write(self.0.as_raw_fd(), data.as_ptr().cast(), data.len()) };
        usize::try_from(count).map_err(|_negative| io::Error::last_os_error())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// See `SOCKET_TYPE`.
#[cfg(target_os = "linux")]
fn accept(
    listener: &OwnedFd,
    peer: &mut libc::sockaddr_vm,
    peer_len: &mut libc::socklen_t,
) -> libc::c_int {
    // SAFETY: `peer` and `peer_len` outlive the call and describe the same buffer.
    unsafe {
        libc::accept4(
            listener.as_raw_fd(),
            std::ptr::from_mut(peer).cast(),
            peer_len,
            libc::SOCK_CLOEXEC,
        )
    }
}

#[cfg(not(target_os = "linux"))]
fn accept(
    listener: &OwnedFd,
    peer: &mut libc::sockaddr_vm,
    peer_len: &mut libc::socklen_t,
) -> libc::c_int {
    // SAFETY: `peer` and `peer_len` outlive the call and describe the same buffer.
    unsafe {
        libc::accept(
            listener.as_raw_fd(),
            std::ptr::from_mut(peer).cast(),
            peer_len,
        )
    }
}

fn owned(fd: libc::c_int) -> io::Result<OwnedFd> {
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: `fd` is a new descriptor that nothing else owns.
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

/// So a command the agent starts doesn't keep the port or a connection open.
fn close_on_exec(fd: &OwnedFd) -> io::Result<()> {
    // SAFETY: the descriptor is open; FD_CLOEXEC is the only descriptor flag.
    if unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn address(cid: u32, port: u32) -> libc::sockaddr_vm {
    libc::sockaddr_vm {
        svm_len: u8::try_from(size_of::<libc::sockaddr_vm>()).unwrap_or(u8::MAX),
        svm_family: libc::sa_family_t::try_from(libc::AF_VSOCK).unwrap_or_default(),
        svm_reserved1: 0,
        svm_port: port,
        svm_cid: cid,
    }
}

#[cfg(not(target_os = "macos"))]
fn address(cid: u32, port: u32) -> libc::sockaddr_vm {
    libc::sockaddr_vm {
        svm_family: libc::sa_family_t::try_from(libc::AF_VSOCK).unwrap_or_default(),
        svm_reserved1: 0,
        svm_port: port,
        svm_cid: cid,
        svm_zero: [0; 4],
    }
}

fn address_len() -> libc::socklen_t {
    libc::socklen_t::try_from(size_of::<libc::sockaddr_vm>()).unwrap_or(libc::socklen_t::MAX)
}
