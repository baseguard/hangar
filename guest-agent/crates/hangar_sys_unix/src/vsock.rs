//! The guest's end of a vsock port: a listener that lets only the host in, and its connections.

use std::{
    fs::File,
    io::{self, Read, Write},
    os::fd::{AsRawFd, FromRawFd, OwnedFd},
};

use nix::{
    errno::Errno,
    fcntl::{FcntlArg, FdFlag, fcntl},
    sys::socket::{
        AddressFamily, Backlog, Shutdown, SockFlag, SockType, VsockAddr, bind, getpeername, listen,
        shutdown, socket,
    },
};

/// How many connections may wait to be accepted.
const BACKLOG: i32 = 16;
/// Close-on-exec from the start on Linux, so a command another connection starts in that moment
/// can't inherit the descriptor. macOS has no such flag; there `close_on_exec` follows at once,
/// and commands start through `sudo`, which closes what they would inherit.
#[cfg(target_os = "linux")]
const SOCKET_FLAGS: SockFlag = SockFlag::SOCK_CLOEXEC;
#[cfg(not(target_os = "linux"))]
const SOCKET_FLAGS: SockFlag = SockFlag::empty();

/// A vsock port the guest listens on.
#[derive(Debug)]
pub struct VsockListener(OwnedFd);

/// One connection from the host; reads and writes may come from different threads.
#[derive(Debug)]
pub struct VsockStream(File);

impl VsockListener {
    /// On Linux, a port below 1024 takes root to bind, so no other user can listen on it first.
    pub fn bind(port: u32) -> io::Result<VsockListener> {
        let listener = socket(AddressFamily::Vsock, SockType::Stream, SOCKET_FLAGS, None)?;
        close_on_exec(&listener)?;
        bind(
            listener.as_raw_fd(),
            &VsockAddr::new(libc::VMADDR_CID_ANY, port),
        )?;
        listen(&listener, Backlog::new(BACKLOG)?)?;
        Ok(VsockListener(listener))
    }

    /// The next connection from the host. A connection from anywhere else, such as a process in
    /// the guest itself through Linux's vsock loopback, is closed unanswered.
    pub fn accept_from_host(&self) -> io::Result<VsockStream> {
        loop {
            let connection = match accept(&self.0) {
                Ok(connection) => connection,
                Err(Errno::EINTR) => continue,
                Err(error) => return Err(error.into()),
            };
            close_on_exec(&connection)?;

            let is_from_host = getpeername::<VsockAddr>(connection.as_raw_fd())
                .is_ok_and(|peer| peer.cid() == libc::VMADDR_CID_HOST);
            if is_from_host {
                return Ok(VsockStream(File::from(connection)));
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
        // Shutting down a connection that is already closed just fails.
        shutdown(self.0.as_raw_fd(), Shutdown::Both).unwrap_or(());
    }
}

impl Read for VsockStream {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        self.0.read(buffer)
    }
}

impl Write for VsockStream {
    fn write(&mut self, data: &[u8]) -> io::Result<usize> {
        self.0.write(data)
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// See `SOCKET_FLAGS`.
fn accept(listener: &OwnedFd) -> nix::Result<OwnedFd> {
    #[cfg(target_os = "linux")]
    let fd = nix::sys::socket::accept4(listener.as_raw_fd(), SockFlag::SOCK_CLOEXEC)?;
    #[cfg(not(target_os = "linux"))]
    let fd = nix::sys::socket::accept(listener.as_raw_fd())?;

    // SAFETY: `accept` returned a new descriptor that nothing else owns.
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

/// So a command the agent starts doesn't keep the port or a connection open.
fn close_on_exec(fd: &OwnedFd) -> io::Result<()> {
    fcntl(fd, FcntlArg::F_SETFD(FdFlag::FD_CLOEXEC))?;
    Ok(())
}
