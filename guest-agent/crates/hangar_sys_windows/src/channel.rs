//! Pipe and port handles for the clipboard and exec relays.

use std::{
    ffi::OsString,
    io,
    os::windows::ffi::OsStringExt,
    path::PathBuf,
    ptr::{null, null_mut},
};

use windows_sys::Win32::{
    Foundation::{
        ERROR_BROKEN_PIPE, ERROR_IO_PENDING, ERROR_NO_DATA, ERROR_PIPE_CONNECTED, GENERIC_READ,
        GENERIC_WRITE, INVALID_HANDLE_VALUE,
    },
    Security::{
        Authorization::{
            ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1, SE_KERNEL_OBJECT,
        },
        SECURITY_ATTRIBUTES,
    },
    Storage::FileSystem::{
        CreateFileW, FILE_FLAG_FIRST_PIPE_INSTANCE, FILE_FLAG_OVERLAPPED, OPEN_EXISTING,
        PIPE_ACCESS_DUPLEX, ReadFile, SECURITY_IDENTIFICATION, SECURITY_SQOS_PRESENT, WriteFile,
    },
    System::{
        IO::{CancelIoEx, GetOverlappedResult, OVERLAPPED},
        Pipes::{
            ConnectNamedPipe, CreateNamedPipeW, DisconnectNamedPipe, GetNamedPipeClientProcessId,
            GetNamedPipeClientSessionId, GetNamedPipeServerSessionId, PIPE_READMODE_BYTE,
            PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE, PIPE_UNLIMITED_INSTANCES, PIPE_WAIT,
            PeekNamedPipe,
        },
        RemoteDesktop::{ProcessIdToSessionId, WTSGetActiveConsoleSessionId},
        Threading::{
            CreateEventW, GetCurrentProcessId, OpenProcess, PROCESS_NAME_WIN32,
            PROCESS_QUERY_LIMITED_INFORMATION, QueryFullProcessImageNameW,
        },
    },
};

use super::{Account, Handle, LocalMemory, check, owner_is, size_u32, wide};

const PIPE_BUFFER: u32 = 64 * 1024;
/// Room for a program's path: the longest path Windows allows, in UTF-16 units.
const PROGRAM_PATH_LENGTH: usize = 32 * 1024;

/// Opened for overlapped I/O: on a plain handle a read waiting for the host holds up every write.
#[derive(Debug)]
pub struct Channel {
    handle: Handle,
}

// SAFETY: a `Channel` holds only a kernel handle, which any thread may use. Every read and write
// brings its own event and `OVERLAPPED` and waits for its call to end before returning, so calls
// from several threads at once share no memory.
unsafe impl Send for Channel {}

// SAFETY: as for `Send` above: `&Channel` calls share nothing but the kernel handle.
unsafe impl Sync for Channel {}

impl Channel {
    pub fn open(path: &str) -> io::Result<Channel> {
        let path = wide(path);
        // The pipe's server may only identify this process, never act as it. Anyone can make a
        // pipe of this name first, so callers check who serves it before sending anything.
        let flags = FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION;
        // SAFETY: `path` is NUL-terminated (`wide`) and outlives the call; no security attributes
        // or template file.
        let handle = unsafe {
            CreateFileW(
                path.as_ptr(),
                GENERIC_READ | GENERIC_WRITE,
                0,
                null(),
                OPEN_EXISTING,
                flags,
                null_mut(),
            )
        };

        if handle == INVALID_HANDLE_VALUE {
            return Err(io::Error::last_os_error());
        }

        Ok(Channel {
            handle: Handle(handle),
        })
    }

    pub fn client_process_id(&self) -> Option<u32> {
        let mut process = 0;
        // SAFETY: `self.handle` is open: `Channel` owns it until drop; `process` is a local.
        let known = unsafe { GetNamedPipeClientProcessId(self.handle.0, &raw mut process) } != 0;
        known.then_some(process)
    }

    pub fn client_session_id(&self) -> Option<u32> {
        let mut session = 0;
        // SAFETY: `self.handle` is open: `Channel` owns it until drop; `session` is a local.
        let known = unsafe { GetNamedPipeClientSessionId(self.handle.0, &raw mut session) } != 0;
        known.then_some(session)
    }

    pub fn server_session_id(&self) -> Option<u32> {
        let mut session = 0;
        // SAFETY: `self.handle` is open: `Channel` owns it until drop; `session` is a local.
        let known = unsafe { GetNamedPipeServerSessionId(self.handle.0, &raw mut session) } != 0;
        known.then_some(session)
    }

    /// False once the client closed its end, as when its process ended.
    pub fn is_connected(&self) -> bool {
        let mut available = 0;
        // SAFETY: `self.handle` is open: `Channel` owns it until drop; with no buffer nothing is
        // read, and `available` is a local the call writes.
        let peeked = unsafe {
            PeekNamedPipe(
                self.handle.0,
                null_mut(),
                0,
                null_mut(),
                &raw mut available,
                null_mut(),
            )
        };
        peeked != 0
    }

    pub fn owner_is(&self, account: Account) -> io::Result<bool> {
        owner_is(self.handle.0, SE_KERNEL_OBJECT, account)
    }

    pub fn read(&self, buffer: &mut [u8]) -> io::Result<usize> {
        let event = new_event()?;
        let mut overlapped = overlapped_for(&event);
        let length = u32::try_from(buffer.len()).unwrap_or(u32::MAX);

        // SAFETY: `self.handle` is open: `Channel` owns it until drop. `buffer` is writable for at
        // least `length` bytes, and it and `overlapped` outlive the read: `wait_for` waits for it.
        let started = check(unsafe {
            ReadFile(
                self.handle.0,
                buffer.as_mut_ptr(),
                length,
                null_mut(),
                &raw mut overlapped,
            )
        });

        match self.wait_for(started, &overlapped) {
            Ok(count) => Ok(count as usize),
            Err(error) if error.raw_os_error() == Some(ERROR_BROKEN_PIPE.cast_signed()) => Ok(0),
            Err(error) => Err(error),
        }
    }

    pub fn write_all(&self, mut data: &[u8]) -> io::Result<()> {
        while !data.is_empty() {
            let written = self.write(data)?;
            if written == 0 {
                return Err(io::ErrorKind::WriteZero.into());
            }
            data = &data[written..];
        }

        Ok(())
    }

    /// Breaks the client's connection to this instance; reads and writes on either end fail from
    /// then on, also one that is waiting.
    pub fn disconnect(&self) {
        // SAFETY: `self.handle` is an open server end: `Channel` owns it until drop.
        unsafe { DisconnectNamedPipe(self.handle.0) };
    }

    pub fn cancel(&self) {
        // SAFETY: `self.handle` is open: `Channel` owns it until drop. A null `OVERLAPPED` cancels
        // every call on it; with nothing pending the call fails harmlessly.
        unsafe { CancelIoEx(self.handle.0, null()) };
    }

    fn write(&self, data: &[u8]) -> io::Result<usize> {
        let event = new_event()?;
        let mut overlapped = overlapped_for(&event);
        let length = u32::try_from(data.len()).unwrap_or(u32::MAX);

        // SAFETY: `self.handle` is open: `Channel` owns it until drop. `data` is readable for at
        // least `length` bytes, and it and `overlapped` outlive the write: `wait_for` waits for it.
        let started = check(unsafe {
            WriteFile(
                self.handle.0,
                data.as_ptr(),
                length,
                null_mut(),
                &raw mut overlapped,
            )
        });

        Ok(self.wait_for(started, &overlapped)? as usize)
    }

    /// A client that opened and closed this instance before it was connected leaves it unusable
    /// (`ERROR_NO_DATA`); disconnecting resets it, so the instance keeps the pipe's name.
    fn wait_for_client(&self) -> io::Result<()> {
        loop {
            match self.connect_client() {
                Err(error) if error.raw_os_error() == Some(ERROR_NO_DATA.cast_signed()) => {
                    self.disconnect();
                }
                connected => return connected,
            }
        }
    }

    fn connect_client(&self) -> io::Result<()> {
        let event = new_event()?;
        let mut overlapped = overlapped_for(&event);

        // SAFETY: `self.handle` is open: `Channel` owns it until drop. `overlapped` outlives the
        // call because `wait_for` waits until it has ended.
        let started = check(unsafe { ConnectNamedPipe(self.handle.0, &raw mut overlapped) });

        match started {
            // A client that opened the pipe before this call is already connected.
            Err(error) if error.raw_os_error() == Some(ERROR_PIPE_CONNECTED.cast_signed()) => {
                Ok(())
            }
            started => {
                self.wait_for(started, &overlapped)?;
                Ok(())
            }
        }
    }

    fn wait_for(&self, started: io::Result<()>, overlapped: &OVERLAPPED) -> io::Result<u32> {
        if let Err(error) = started
            && error.raw_os_error() != Some(ERROR_IO_PENDING.cast_signed())
        {
            return Err(error);
        }

        let mut count = 0;
        // SAFETY: callers pass the `overlapped` of a call they just started on `self.handle`;
        // waiting (`TRUE`) returns only once that call has ended.
        check(unsafe { GetOverlappedResult(self.handle.0, overlapped, &raw mut count, 1) })?;

        Ok(count)
    }
}

impl io::Read for &Channel {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        Channel::read(self, buffer)
    }
}

/// A pipe with an instance per client, for clients that each need a connection of their own.
#[derive(Debug)]
pub struct PipeInstances {
    path: String,
    access: String,
    /// The instance the next client gets. One always waits, also after a client closed it before
    /// it was connected, so the name never goes free for another process to take.
    waiting: Channel,
}

impl PipeInstances {
    /// `access` (SDDL) must not give clients `FILE_CREATE_PIPE_INSTANCE`, or they could add
    /// instances of their own.
    pub fn new(path: &str, access: &str) -> io::Result<PipeInstances> {
        Ok(PipeInstances {
            path: path.into(),
            access: access.into(),
            waiting: create_pipe(path, access, Instances::FirstOfMany)?,
        })
    }

    /// Waits for the next client and returns its instance, after making the one after it.
    pub fn next_client(&mut self) -> io::Result<Channel> {
        self.waiting.wait_for_client()?;
        let next = create_pipe(&self.path, &self.access, Instances::AnotherOfMany)?;
        Ok(std::mem::replace(&mut self.waiting, next))
    }
}

#[derive(Clone, Copy)]
enum Instances {
    /// First instance, with more to come from this process.
    FirstOfMany,
    AnotherOfMany,
}

fn create_pipe(path: &str, access: &str, instances: Instances) -> io::Result<Channel> {
    let security = security_descriptor(access)?;
    let attributes = SECURITY_ATTRIBUTES {
        nLength: size_u32::<SECURITY_ATTRIBUTES>(),
        lpSecurityDescriptor: security.0,
        bInheritHandle: 0,
    };

    let (first_flag, max_instances) = match instances {
        Instances::FirstOfMany => (FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_UNLIMITED_INSTANCES),
        Instances::AnotherOfMany => (0, PIPE_UNLIMITED_INSTANCES),
    };
    let path = wide(path);
    // SAFETY: `path` is NUL-terminated (`wide`); `attributes` and the descriptor `security` owns
    // are locals that outlive the call.
    let handle = unsafe {
        CreateNamedPipeW(
            path.as_ptr(),
            PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | first_flag,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            max_instances,
            PIPE_BUFFER,
            PIPE_BUFFER,
            0,
            &raw const attributes,
        )
    };

    if handle == INVALID_HANDLE_VALUE {
        return Err(io::Error::last_os_error());
    }

    Ok(Channel {
        handle: Handle(handle),
    })
}

fn security_descriptor(sddl: &str) -> io::Result<LocalMemory> {
    let text = wide(sddl);
    let mut descriptor = null_mut();

    // SAFETY: `text` is NUL-terminated (`wide`); `descriptor` receives a block that `LocalMemory`
    // frees with `LocalFree`; the size output is optional.
    check(unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            text.as_ptr(),
            SDDL_REVISION_1,
            &raw mut descriptor,
            null_mut(),
        )
    })?;

    Ok(LocalMemory(descriptor))
}

/// A new manual-reset event for one overlapped call.
fn new_event() -> io::Result<Handle> {
    // SAFETY: no security attributes and no name; the event starts unsignaled.
    let event = unsafe { CreateEventW(null(), 1, 0, null()) };

    if event.is_null() {
        return Err(io::Error::last_os_error());
    }

    Ok(Handle(event))
}

fn overlapped_for(event: &Handle) -> OVERLAPPED {
    // SAFETY: `OVERLAPPED` is plain data for which all-zero bytes are a valid value.
    let mut overlapped: OVERLAPPED = unsafe { std::mem::zeroed() };
    overlapped.hEvent = event.0;
    overlapped
}

/// The console session is the one on the VM's display.
pub fn console_session_id() -> u32 {
    // SAFETY: has no preconditions.
    unsafe { WTSGetActiveConsoleSessionId() }
}

/// `None` if Windows won't say which session this process runs in.
pub fn current_session_id() -> Option<u32> {
    let mut session = 0u32;
    // SAFETY: `GetCurrentProcessId` has no preconditions; `session` is a local the call writes on
    // success.
    let known = unsafe { ProcessIdToSessionId(GetCurrentProcessId(), &raw mut session) } != 0;
    known.then_some(session)
}

/// The full path of the program `process` runs, if this process may ask.
pub fn program_of(process: u32) -> Option<PathBuf> {
    // SAFETY: opens the process for querying its name only; the handle is closed by `Handle`.
    let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, process) };

    if handle.is_null() {
        return None;
    }

    let process = Handle(handle);
    let mut buffer = vec![0u16; PROGRAM_PATH_LENGTH];
    let mut length = u32::try_from(buffer.len()).ok()?;
    // SAFETY: `process` was opened above for querying and stays open until it drops; `buffer` is
    // a local `Vec` of `length` units; on success `length` holds the units written.
    let ok = unsafe {
        QueryFullProcessImageNameW(
            process.0,
            PROCESS_NAME_WIN32,
            buffer.as_mut_ptr(),
            &raw mut length,
        )
    };

    if ok == 0 {
        return None;
    }

    Some(PathBuf::from(OsString::from_wide(
        &buffer[..length as usize],
    )))
}
