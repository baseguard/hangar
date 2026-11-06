//! Running with administrator rights: whether this process has them, starting a program through UAC
//! when it doesn't, and the privilege a shutdown needs.

use std::{
    io,
    path::Path,
    ptr::{null, null_mut},
};

use windows_sys::Win32::{
    Foundation::{ERROR_NOT_ALL_ASSIGNED, GetLastError, LUID},
    Security::{
        AdjustTokenPrivileges, GetTokenInformation, LUID_AND_ATTRIBUTES, LookupPrivilegeValueW,
        SE_PRIVILEGE_ENABLED, TOKEN_ADJUST_PRIVILEGES, TOKEN_ELEVATION, TOKEN_PRIVILEGES,
        TOKEN_QUERY, TokenElevation,
    },
    System::Threading::{
        GetCurrentProcess, GetExitCodeProcess, INFINITE, OpenProcessToken, WaitForSingleObject,
    },
    UI::{
        Shell::{
            SEE_MASK_FLAG_NO_UI, SEE_MASK_NOASYNC, SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW,
            ShellExecuteExW,
        },
        WindowsAndMessaging::SW_HIDE,
    },
};

use super::{Handle, check, size_u32, system32, wide};

pub fn is_elevated() -> bool {
    let Ok(token) = open_own_token(TOKEN_QUERY) else {
        return false;
    };

    let mut elevation = TOKEN_ELEVATION { TokenIsElevated: 0 };
    let mut length = 0;
    // SAFETY: `token` was opened for querying and stays open until it drops; `elevation` is a
    // local `TOKEN_ELEVATION` of the size passed with it.
    let ok = unsafe {
        GetTokenInformation(
            token.0,
            TokenElevation,
            (&raw mut elevation).cast(),
            size_u32::<TOKEN_ELEVATION>(),
            &raw mut length,
        )
    };

    ok != 0 && elevation.TokenIsElevated != 0
}

/// A declined UAC prompt fails with `ERROR_CANCELLED`.
pub fn run_elevated(program: &Path, parameters: &str) -> io::Result<u32> {
    let process = start_through_uac(program, parameters)?;
    wait_for_exit_code(&process)
}

/// Returns once the user answered the UAC prompt and the program started; a declined prompt fails
/// with `ERROR_CANCELLED`.
pub fn start_elevated(program: &Path, parameters: &str) -> io::Result<()> {
    start_through_uac(program, parameters).map(drop)
}

fn start_through_uac(program: &Path, parameters: &str) -> io::Result<Handle> {
    let command = super::command_line::elevated_command(program, parameters)?;
    shell_execute_as_administrator(&system32()?.join("cmd.exe"), &command)
}

pub(crate) fn open_own_token(access: u32) -> io::Result<Handle> {
    let mut token = null_mut();
    // SAFETY: `token` receives a handle that the returned `Handle` then owns; the pseudo handle
    // from `GetCurrentProcess` needs no closing.
    check(unsafe { OpenProcessToken(GetCurrentProcess(), access, &raw mut token) })?;
    Ok(Handle(token))
}

pub(crate) fn enable_privilege(name: &str) -> io::Result<()> {
    let token = open_own_token(TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY)?;
    let name = wide(name);
    let mut luid = LUID {
        LowPart: 0,
        HighPart: 0,
    };
    // SAFETY: a null system name means this machine; `name` is NUL-terminated (`wide`) and `luid`
    // is a local.
    check(unsafe { LookupPrivilegeValueW(null(), name.as_ptr(), &raw mut luid) })?;

    let privileges = TOKEN_PRIVILEGES {
        PrivilegeCount: 1,
        Privileges: [LUID_AND_ATTRIBUTES {
            Luid: luid,
            Attributes: SE_PRIVILEGE_ENABLED,
        }],
    };
    // SAFETY: `token` was opened above for adjusting and stays open until it drops; `privileges`
    // is a complete one-entry list; the previous state isn't asked for, so null is allowed.
    check(unsafe {
        AdjustTokenPrivileges(token.0, 0, &raw const privileges, 0, null_mut(), null_mut())
    })?;

    // The call succeeds even when the token doesn't hold the privilege; only the last error says.
    // SAFETY: reads the calling thread's last error and has no preconditions.
    if unsafe { GetLastError() } == ERROR_NOT_ALL_ASSIGNED {
        return Err(io::Error::from_raw_os_error(
            ERROR_NOT_ALL_ASSIGNED.cast_signed(),
        ));
    }

    Ok(())
}

fn shell_execute_as_administrator(file: &Path, parameters: &str) -> io::Result<Handle> {
    let (verb, file, parameters) = (wide("runas"), wide(file), wide(parameters));
    // SAFETY: `SHELLEXECUTEINFOW` is plain data for which all-zero bytes are a valid value.
    let mut info: SHELLEXECUTEINFOW = unsafe { std::mem::zeroed() };
    info.cbSize = size_u32::<SHELLEXECUTEINFOW>();
    info.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
    info.lpVerb = verb.as_ptr();
    info.lpFile = file.as_ptr();
    info.lpParameters = parameters.as_ptr();
    info.nShow = SW_HIDE;

    // SAFETY: `info` is complete, and its strings are NUL-terminated (`wide`) locals that outlive
    // the call.
    check(unsafe { ShellExecuteExW(&raw mut info) })?;

    if info.hProcess.is_null() {
        return Err(io::ErrorKind::NotFound.into());
    }

    Ok(Handle(info.hProcess))
}

fn wait_for_exit_code(process: &Handle) -> io::Result<u32> {
    // SAFETY: `process` borrows a `Handle`, so the handle stays open during the call.
    unsafe { WaitForSingleObject(process.0, INFINITE) };

    let mut code = 0;
    // SAFETY: `process` stays open as above, and `code` is a local.
    check(unsafe { GetExitCodeProcess(process.0, &raw mut code) })?;
    Ok(code)
}
