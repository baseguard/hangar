//! The guest's end of a vsock port, through virtio-win's viosock socket provider: a listener that
//! lets only the host in, and its connections.

use std::{
    io::{self, Read, Write},
    mem::zeroed,
    sync::OnceLock,
};

use windows_sys::Win32::Networking::WinSock::{
    INVALID_SOCKET, SD_BOTH, SOCK_STREAM, SOCKADDR, SOCKET, SOCKET_ERROR, WSADATA, WSAEINTR,
    WSAGetLastError, WSAStartup, accept, bind, closesocket, listen, recv, send, shutdown, socket,
};

use super::size_u32;

/// viosock's address family; Windows has no name for it.
const AF_VSOCK: u16 = 40;
const VMADDR_CID_ANY: u32 = u32::MAX;
const VMADDR_CID_HOST: u32 = 2;
/// Winsock 2.2.
const WINSOCK_VERSION: u16 = 0x0202;
/// How many connections may wait to be accepted.
const BACKLOG: i32 = 16;

/// viosock's `SOCKADDR_VM`: 12 bytes, without the padding Linux's has.
#[repr(C)]
struct VsockAddress {
    family: u16,
    reserved: u16,
    port: u32,
    cid: u32,
}

/// A vsock port the guest listens on.
#[derive(Debug)]
pub struct VsockListener(Socket);

/// One connection from the host; reads and writes may come from different threads.
#[derive(Debug)]
pub struct VsockStream(Socket);

#[derive(Debug)]
struct Socket(SOCKET);

impl Drop for Socket {
    fn drop(&mut self) {
        // SAFETY: the socket is open and owned by this value alone.
        unsafe { closesocket(self.0) };
    }
}

impl VsockListener {
    pub fn bind(port: u32) -> io::Result<VsockListener> {
        start_winsock()?;
        // SAFETY: `socket` takes plain values and returns a new socket or `INVALID_SOCKET`.
        let handle = unsafe { socket(i32::from(AF_VSOCK), SOCK_STREAM, 0) };
        if handle == INVALID_SOCKET {
            return Err(last_error());
        }
        let listener = VsockListener(Socket(handle));

        let address = VsockAddress {
            family: AF_VSOCK,
            reserved: 0,
            port,
            cid: VMADDR_CID_ANY,
        };
        // SAFETY: `address` is a valid `SOCKADDR_VM` that outlives the call, with its size.
        let bound = unsafe {
            bind(
                listener.0.0,
                (&raw const address).cast::<SOCKADDR>(),
                address_len(),
            )
        };
        if bound == SOCKET_ERROR {
            return Err(last_error());
        }
        // SAFETY: the socket is open and bound.
        if unsafe { listen(listener.0.0, BACKLOG) } == SOCKET_ERROR {
            return Err(last_error());
        }
        Ok(listener)
    }

    /// The next connection from the host. A connection from anywhere else, or one whose address
    /// the provider doesn't give, is closed unanswered.
    pub fn accept_from_host(&self) -> io::Result<VsockStream> {
        loop {
            // SAFETY: an all-zero `SOCKADDR_VM` is a valid value for `accept` to fill.
            let mut peer: VsockAddress = unsafe { zeroed() };
            let mut peer_len = address_len();
            // SAFETY: `peer` and `peer_len` outlive the call and describe the same buffer.
            let handle = unsafe {
                accept(
                    self.0.0,
                    (&raw mut peer).cast::<SOCKADDR>(),
                    &raw mut peer_len,
                )
            };
            if handle == INVALID_SOCKET {
                let error = last_error();
                if error.raw_os_error() == Some(WSAEINTR) {
                    continue;
                }
                return Err(error);
            }
            let connection = VsockStream(Socket(handle));

            let is_whole_address = peer_len == address_len() && peer.family == AF_VSOCK;
            if is_whole_address && peer.cid == VMADDR_CID_HOST {
                return Ok(connection);
            }
        }
    }
}

impl VsockStream {
    /// Ends the connection both ways, which also wakes a thread reading it.
    pub fn shut_down(&self) {
        // SAFETY: the socket is open; shutting down one that is already shut just fails.
        unsafe { shutdown(self.0.0, SD_BOTH) };
    }
}

impl Read for &VsockStream {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let length = i32::try_from(buffer.len()).unwrap_or(i32::MAX);
        // SAFETY: `buffer` is writable for at least `length` bytes.
        let count = unsafe { recv(self.0.0, buffer.as_mut_ptr(), length, 0) };
        usize::try_from(count).map_err(|_negative| last_error())
    }
}

impl Write for &VsockStream {
    fn write(&mut self, data: &[u8]) -> io::Result<usize> {
        let length = i32::try_from(data.len()).unwrap_or(i32::MAX);
        // SAFETY: `data` is readable for at least `length` bytes.
        let count = unsafe { send(self.0.0, data.as_ptr(), length, 0) };
        usize::try_from(count).map_err(|_negative| last_error())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// Once per process; Winsock counts the starts, and the agent never stops it.
fn start_winsock() -> io::Result<()> {
    static STARTED: OnceLock<i32> = OnceLock::new();
    let result = *STARTED.get_or_init(|| {
        // SAFETY: an all-zero `WSADATA` is a valid value for `WSAStartup` to fill.
        let mut data: WSADATA = unsafe { zeroed() };
        // SAFETY: `data` outlives the call.
        unsafe { WSAStartup(WINSOCK_VERSION, &raw mut data) }
    });
    if result != 0 {
        return Err(io::Error::from_raw_os_error(result));
    }
    Ok(())
}

fn last_error() -> io::Error {
    // SAFETY: has no preconditions.
    io::Error::from_raw_os_error(unsafe { WSAGetLastError() })
}

fn address_len() -> i32 {
    i32::try_from(size_u32::<VsockAddress>()).unwrap_or(i32::MAX)
}
