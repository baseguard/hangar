//! Process-wide calls: folders, standard handles, memory, shutdown, message boxes and the handles
//! the other modules share.

use std::{
    ffi::{OsStr, OsString, c_void},
    fs::File,
    io,
    os::windows::{
        ffi::{OsStrExt, OsStringExt},
        io::IntoRawHandle,
    },
    path::{Path, PathBuf},
    ptr::{null, null_mut},
    slice,
    time::Duration,
};

use windows_sys::{
    Win32::{
        Foundation::{CloseHandle, ERROR_SHUTDOWN_IN_PROGRESS, HANDLE, HMODULE, LocalFree},
        Graphics::Gdi::HBRUSH,
        Storage::FileSystem::{MOVEFILE_DELAY_UNTIL_REBOOT, MoveFileExW},
        System::{
            Com::CoTaskMemFree,
            Console::{
                ATTACH_PARENT_PROCESS, AttachConsole, GetStdHandle, STD_ERROR_HANDLE,
                STD_OUTPUT_HANDLE, SetStdHandle,
            },
            LibraryLoader::{
                GetModuleHandleW, LOAD_LIBRARY_SEARCH_SYSTEM32, SetDefaultDllDirectories,
            },
            Shutdown::{
                InitiateSystemShutdownExW, SHTDN_REASON_FLAG_PLANNED, SHTDN_REASON_MAJOR_OTHER,
                SHTDN_REASON_MINOR_OTHER,
            },
            SystemInformation::{GetSystemDirectoryW, GlobalMemoryStatusEx, MEMORYSTATUSEX},
            Threading::INFINITE,
        },
        UI::{
            Shell::{FOLDERID_Profile, FOLDERID_ProgramFiles, SHGetKnownFolderPath},
            WindowsAndMessaging::{
                HCURSOR, MB_ICONERROR, MB_ICONINFORMATION, MB_OK, MB_SETFOREGROUND,
                MESSAGEBOX_STYLE, MessageBoxW, RegisterClassExW, WNDCLASSEXW, WNDPROC,
            },
        },
    },
    core::{BOOL, GUID, HRESULT, PWSTR},
};

use super::elevation::enable_privilege;

const MESSAGE_TITLE: &str = "Hangar Agent";
/// The privilege a process needs to shut Windows down, even as SYSTEM.
const SHUTDOWN_PRIVILEGE: &str = "SeShutdownPrivilege";
/// Room for the System32 path; it is short, `MAX_PATH` at most.
const SYSTEM_FOLDER_LENGTH: usize = 1024;

#[derive(Debug)]
pub(crate) struct Handle(pub(crate) HANDLE);

impl Drop for Handle {
    fn drop(&mut self) {
        // SAFETY: the handle was opened by the call that made this `Handle`, nothing else owns it,
        // and it is closed exactly once, here.
        unsafe { CloseHandle(self.0) };
    }
}

pub(crate) struct LocalMemory(pub(crate) *mut c_void);

impl Drop for LocalMemory {
    fn drop(&mut self) {
        // SAFETY: `LocalMemory` only wraps blocks a call handed over to be freed with `LocalFree`;
        // it is freed once, here, and `LocalFree` accepts null.
        unsafe { LocalFree(self.0) };
    }
}

/// Text as the NUL-terminated UTF-16 that Windows' `W` functions take.
pub fn wide(text: impl AsRef<OsStr>) -> Vec<u16> {
    let mut units: Vec<u16> = text.as_ref().encode_wide().collect();
    units.push(0);
    units
}

/// So a DLL planted beside the agent on the Tools share can't load.
pub fn load_dlls_from_system32_only() {
    // SAFETY: takes a flag value and has no other preconditions.
    unsafe { SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32) };
}

/// A Windows-subsystem program has no console, so it prints into its parent's, if any.
pub fn attach_to_parent_console() {
    // SAFETY: takes a constant and only reads the process's standard handles.
    let has_output = !unsafe { GetStdHandle(STD_OUTPUT_HANDLE) }.is_null();
    if !has_output {
        // SAFETY: takes a constant; failing leaves the process without a console, as before.
        unsafe { AttachConsole(ATTACH_PARENT_PROCESS) };
    }
}

/// From here on the process's stderr, panics included, goes to `file`; Rust's stderr looks the
/// handle up on every write.
pub fn send_stderr_to(file: File) -> io::Result<()> {
    // The handle stays open for the rest of the process: stderr is never closed.
    let handle = file.into_raw_handle();
    // SAFETY: `handle` is an open file handle that nothing closes.
    check(unsafe { SetStdHandle(STD_ERROR_HANDLE, handle) })
}

pub fn system32() -> io::Result<PathBuf> {
    let mut buffer = vec![0u16; SYSTEM_FOLDER_LENGTH];
    let capacity = u32::try_from(buffer.len())
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;
    // SAFETY: `buffer` is a local `Vec` of `capacity` units.
    let length = unsafe { GetSystemDirectoryW(buffer.as_mut_ptr(), capacity) } as usize;

    if length == 0 || length >= buffer.len() {
        return Err(io::Error::last_os_error());
    }

    Ok(PathBuf::from(OsString::from_wide(&buffer[..length])))
}

pub fn program_files() -> io::Result<PathBuf> {
    known_folder(&FOLDERID_ProgramFiles)
}

pub fn profile() -> io::Result<PathBuf> {
    known_folder(&FOLDERID_Profile)
}

pub fn show_info(text: &str) {
    message_box(text, MB_ICONINFORMATION);
}

pub fn show_error(text: &str) {
    message_box(text, MB_ICONERROR);
}

/// In bytes.
#[derive(Clone, Copy, Debug)]
pub struct PhysicalMemory {
    pub total: u64,
    pub available: u64,
}

pub fn physical_memory() -> Option<PhysicalMemory> {
    // SAFETY: `MEMORYSTATUSEX` is plain data for which all-zero bytes are a valid value.
    let mut status: MEMORYSTATUSEX = unsafe { std::mem::zeroed() };
    status.dwLength = size_u32::<MEMORYSTATUSEX>();

    // SAFETY: `status` is a local whose `dwLength`, set above, says which structure it is.
    let ok = unsafe { GlobalMemoryStatusEx(&raw mut status) };

    if ok == 0 {
        return None;
    }

    Some(PhysicalMemory {
        total: status.ullTotalPhys,
        available: status.ullAvailPhys,
    })
}

pub fn shut_down() -> io::Result<()> {
    enable_privilege(SHUTDOWN_PRIVILEGE)?;
    let reason = SHTDN_REASON_MAJOR_OTHER | SHTDN_REASON_MINOR_OTHER | SHTDN_REASON_FLAG_PLANNED;

    // InitiateShutdownW fails from session 0, where the service runs, while a user is signed in.
    // SAFETY: null machine name and message mean this machine and no message; the rest are values.
    check(unsafe { InitiateSystemShutdownExW(null(), null(), 0, 0, 0, reason) })
}

pub fn is_shutdown_in_progress(error: &io::Error) -> bool {
    error.raw_os_error() == Some(ERROR_SHUTDOWN_IN_PROGRESS.cast_signed())
}

pub fn delete_at_restart(path: &Path) -> io::Result<()> {
    let path = wide(path);
    // SAFETY: `path` is NUL-terminated (`wide`) and outlives the call; a null new name deletes.
    check(unsafe { MoveFileExW(path.as_ptr(), null(), MOVEFILE_DELAY_UNTIL_REBOOT) })
}

pub(crate) fn check(ok: BOOL) -> io::Result<()> {
    if ok == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

pub(crate) fn status(code: u32) -> io::Result<()> {
    if code != 0 {
        return Err(io::Error::from_raw_os_error(code.cast_signed()));
    }
    Ok(())
}

pub(crate) fn hresult(code: HRESULT) -> io::Result<()> {
    if code < 0 {
        return Err(io::Error::from_raw_os_error(code));
    }
    Ok(())
}

/// `duration` in milliseconds for a wait or timer, kept short of `INFINITE`.
pub(crate) fn milliseconds(duration: Duration) -> u32 {
    let longest = INFINITE - 1;
    u32::try_from(duration.as_millis())
        .unwrap_or(longest)
        .min(longest)
}

#[expect(
    clippy::cast_possible_truncation,
    reason = "Windows structures and the values passed with them are far smaller than 4 GiB"
)]
pub(crate) const fn size_u32<T>() -> u32 {
    size_of::<T>() as u32
}

/// Registers the window class `class` (NUL-terminated UTF-16) for this process.
pub(crate) fn register_class(
    class: &[u16],
    procedure: WNDPROC,
    cursor: HCURSOR,
    background: HBRUSH,
) -> io::Result<()> {
    let info = WNDCLASSEXW {
        cbSize: size_u32::<WNDCLASSEXW>(),
        style: 0,
        lpfnWndProc: procedure,
        cbClsExtra: 0,
        cbWndExtra: 0,
        hInstance: this_module(),
        hIcon: null_mut(),
        hCursor: cursor,
        hbrBackground: background,
        lpszMenuName: null(),
        lpszClassName: class.as_ptr(),
        hIconSm: null_mut(),
    };

    // SAFETY: `info` is complete, and its class name, NUL-terminated by the callers' `wide`,
    // outlives the call; the system copies what it needs.
    check(i32::from(unsafe { RegisterClassExW(&raw const info) }))
}

pub(crate) fn this_module() -> HMODULE {
    // SAFETY: a null name asks for the program's own module, which is always loaded.
    unsafe { GetModuleHandleW(null()) }
}

fn known_folder(id: &GUID) -> io::Result<PathBuf> {
    let mut path: PWSTR = null_mut();
    // SAFETY: `id` is a borrowed `GUID`, and `path` receives a string freed below.
    let found = hresult(unsafe { SHGetKnownFolderPath(id, 0, null_mut(), &raw mut path) });

    let folder = match found {
        // SAFETY: on success the call put a NUL-terminated string in `path`, freed only after
        // this copy.
        Ok(()) => Ok(PathBuf::from(OsString::from_wide(unsafe {
            wide_text(path)
        }))),
        Err(error) => Err(error),
    };

    // SAFETY: the call hands the string to the caller to free with `CoTaskMemFree`, even when it
    // fails; it is freed once, here, after the copy above.
    unsafe { CoTaskMemFree(path.cast_const().cast()) };
    folder
}

/// # Safety
///
/// `text` must point at a NUL-terminated string that stays valid while the slice is used.
unsafe fn wide_text<'a>(text: *const u16) -> &'a [u16] {
    let mut length = 0;
    // SAFETY: the caller promises a NUL-terminated string, so every unit up to the NUL is readable.
    while unsafe { *text.add(length) } != 0 {
        length += 1;
    }

    // SAFETY: the `length` units before the NUL were just read, so they are valid.
    unsafe { slice::from_raw_parts(text, length) }
}

fn message_box(text: &str, icon: MESSAGEBOX_STYLE) {
    let (text, title) = (wide(text), wide(MESSAGE_TITLE));

    // SAFETY: both strings are NUL-terminated (`wide`) locals that outlive the call; no owner
    // window is needed.
    // A message box that can't show leaves nothing else to tell the person through.
    unsafe {
        MessageBoxW(
            null_mut(),
            text.as_ptr(),
            title.as_ptr(),
            MB_OK | MB_SETFOREGROUND | icon,
        )
    };
}
