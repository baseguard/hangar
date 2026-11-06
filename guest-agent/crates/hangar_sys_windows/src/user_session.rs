//! The user signed in to a session, and starting a program as them on their desktop, as Explorer
//! would; only SYSTEM may do either.

use std::{
    io,
    path::Path,
    ptr::{null, null_mut},
};

use windows_sys::Win32::{
    Foundation::{ERROR_CTX_WINSTATION_NOT_FOUND, ERROR_NO_TOKEN},
    System::{
        RemoteDesktop::WTSQueryUserToken,
        Threading::{
            CREATE_UNICODE_ENVIRONMENT, CreateProcessAsUserW, PROCESS_INFORMATION, STARTUPINFOW,
        },
    },
};

use super::{
    Handle, UserEnvironment, check, elevation::enable_privilege, program_command_line, size_u32,
    wide,
};

/// What `CreateProcessAsUserW` needs to give a new program another user's token.
const START_AS_USER_PRIVILEGES: [&str; 2] =
    ["SeAssignPrimaryTokenPrivilege", "SeIncreaseQuotaPrivilege"];
/// What `WTSGetActiveConsoleSessionId` gives while no session is attached to the console.
const NO_SESSION: u32 = u32::MAX;
/// The desktop a signed-in user sees.
const USER_DESKTOP: &str = r"winsta0\default";

/// Holds the user's primary token: for an administrator the filtered one, without elevation.
#[derive(Debug)]
pub struct SignedInUser {
    token: Handle,
}

impl SignedInUser {
    /// `None` while nobody is signed in to `session`. The caller needs `SeTcbPrivilege`.
    pub fn of_session(session: u32) -> io::Result<Option<SignedInUser>> {
        if session == NO_SESSION {
            return Ok(None);
        }

        let mut token = null_mut();
        // SAFETY: `token` is a local the call writes; on success the handle is ours to close.
        if unsafe { WTSQueryUserToken(session, &raw mut token) } != 0 {
            return Ok(Some(SignedInUser {
                token: Handle(token),
            }));
        }

        let error = io::Error::last_os_error();
        let means_nobody = [ERROR_NO_TOKEN, ERROR_CTX_WINSTATION_NOT_FOUND]
            .map(|code| Some(code.cast_signed()))
            .contains(&error.raw_os_error());
        if means_nobody {
            return Ok(None);
        }
        Err(error)
    }

    /// Starts `program` with `arguments` as this user, with their environment; it isn't waited
    /// for.
    pub fn start(&self, program: &Path, arguments: &[&str]) -> io::Result<()> {
        for privilege in START_AS_USER_PRIVILEGES {
            enable_privilege(privilege)?;
        }
        let environment = UserEnvironment::of(&self.token)?;
        let program_name = wide(program);
        let mut line = wide(program_command_line(program, arguments)?);
        let mut desktop = wide(USER_DESKTOP);

        // SAFETY: `STARTUPINFOW` is plain C data, and all zeros is a valid value for it.
        let mut startup: STARTUPINFOW = unsafe { std::mem::zeroed() };
        startup.cb = size_u32::<STARTUPINFOW>();
        startup.lpDesktop = desktop.as_mut_ptr();
        // SAFETY: `PROCESS_INFORMATION` is plain C data, and all zeros is a valid value for it.
        let mut created: PROCESS_INFORMATION = unsafe { std::mem::zeroed() };

        // SAFETY: the token is open while `self` lives; `program_name` and `desktop` are
        // NUL-terminated and `line` is too and writable, as the call wants; the environment block,
        // `startup` and `created` outlive the call. No handles are inherited.
        check(unsafe {
            CreateProcessAsUserW(
                self.token.0,
                program_name.as_ptr(),
                line.as_mut_ptr(),
                null(),
                null(),
                0,
                CREATE_UNICODE_ENVIRONMENT,
                environment.block(),
                null(),
                &raw const startup,
                &raw mut created,
            )
        })?;

        // The program runs on its own; only the handles to it are closed.
        drop(Handle(created.hProcess));
        drop(Handle(created.hThread));
        Ok(())
    }
}
