//! The service manager: creating, configuring, starting and stopping a service, and running as one.

use std::{
    ffi::c_void,
    io,
    path::Path,
    ptr::{null, null_mut},
    sync::{
        OnceLock,
        atomic::{AtomicPtr, Ordering},
    },
    time::Duration,
};

use windows_sys::{
    Win32::{
        Foundation::{ERROR_CALL_NOT_IMPLEMENTED, ERROR_SERVICE_DOES_NOT_EXIST, NO_ERROR},
        System::Services::{
            ChangeServiceConfig2W, ChangeServiceConfigW, CloseServiceHandle, ControlService,
            CreateServiceW, OpenSCManagerW, OpenServiceW, QueryServiceStatus,
            RegisterServiceCtrlHandlerExW, SC_ACTION, SC_ACTION_RESTART, SC_HANDLE,
            SC_MANAGER_CONNECT, SC_MANAGER_CREATE_SERVICE, SERVICE_ACCEPT_SHUTDOWN,
            SERVICE_ACCEPT_STOP, SERVICE_ALL_ACCESS, SERVICE_AUTO_START,
            SERVICE_CONFIG_DESCRIPTION, SERVICE_CONFIG_FAILURE_ACTIONS,
            SERVICE_CONFIG_REQUIRED_PRIVILEGES_INFO, SERVICE_CONTROL_INTERROGATE,
            SERVICE_CONTROL_SHUTDOWN, SERVICE_CONTROL_STOP, SERVICE_DESCRIPTIONW,
            SERVICE_ERROR_NORMAL, SERVICE_FAILURE_ACTIONSW, SERVICE_QUERY_STATUS,
            SERVICE_REQUIRED_PRIVILEGES_INFOW, SERVICE_RUNNING, SERVICE_START, SERVICE_START_TYPE,
            SERVICE_STATUS, SERVICE_STATUS_CURRENT_STATE, SERVICE_STOP, SERVICE_STOPPED,
            SERVICE_TABLE_ENTRYW, SERVICE_WIN32_OWN_PROCESS, SetServiceStatus,
            StartServiceCtrlDispatcherW, StartServiceW,
        },
    },
    core::PWSTR,
};

use super::{check, milliseconds, program_command_line, wide};

#[derive(Debug)]
pub struct Settings<'a> {
    pub name: &'a str,
    pub display_name: &'a str,
    pub program: &'a Path,
    /// Plain words only; see [`program_command_line`].
    pub arguments: &'a [&'a str],
    pub dependencies: &'a [&'a str],
    pub start: Start,
    pub run_as: RunAs,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Start {
    /// When Windows starts.
    Automatic,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RunAs {
    LocalSystem,
}

impl Start {
    fn code(self) -> SERVICE_START_TYPE {
        match self {
            Start::Automatic => SERVICE_AUTO_START,
        }
    }
}

impl RunAs {
    /// Null: `CreateServiceW` then uses `LocalSystem`, and `ChangeServiceConfigW` keeps the
    /// account the service was created with.
    fn name(self) -> *const u16 {
        match self {
            RunAs::LocalSystem => null(),
        }
    }
}

#[derive(Debug)]
pub struct Service {
    handle: ServiceHandle,
}

struct Running {
    name: Vec<u16>,
    work: fn(),
}

/// The service manager calls `service_main` with no context argument, so it finds its work here.
static RUNNING: OnceLock<Running> = OnceLock::new();
/// `control` reports through this handle, which exists only after `control` is registered.
static STATUS: AtomicPtr<c_void> = AtomicPtr::new(null_mut());

/// Hands this thread to the service manager, which runs `work` on a thread of its own.
pub fn serve(name: &str, work: fn()) -> io::Result<()> {
    let name = wide(name);
    let running = Running {
        name: name.clone(),
        work,
    };

    if RUNNING.set(running).is_err() {
        return Err(io::ErrorKind::AlreadyExists.into());
    }

    let table = [
        SERVICE_TABLE_ENTRYW {
            lpServiceName: name.as_ptr().cast_mut(),
            lpServiceProc: Some(service_main),
        },
        SERVICE_TABLE_ENTRYW {
            lpServiceName: null_mut(),
            lpServiceProc: None,
        },
    ];

    // SAFETY: the table ends with an empty entry; its name is NUL-terminated (`wide`) and never
    // written; both are locals that outlive the call, which returns once the service has stopped.
    check(unsafe { StartServiceCtrlDispatcherW(table.as_ptr()) })
}

impl Service {
    pub fn open_to_configure(name: &str) -> io::Result<Option<Service>> {
        open(name, SERVICE_ALL_ACCESS)
    }

    pub fn open_to_start(name: &str) -> io::Result<Option<Service>> {
        open(name, SERVICE_START)
    }

    pub fn open_to_stop(name: &str) -> io::Result<Option<Service>> {
        open(name, SERVICE_STOP | SERVICE_QUERY_STATUS)
    }

    pub fn create(settings: &Settings) -> io::Result<Service> {
        let manager = open_manager(SC_MANAGER_CONNECT | SC_MANAGER_CREATE_SERVICE)?;
        let name = wide(settings.name);
        let display_name = wide(settings.display_name);
        let command = wide(&program_command_line(settings.program, settings.arguments)?);
        let dependencies = string_list(settings.dependencies);

        // SAFETY: `manager` stays open until it drops; the strings are locals NUL-terminated by
        // `wide` and `string_list` (the list doubly) that outlive the call; the account name is
        // null (LocalSystem), and no password goes with it.
        let service = unsafe {
            CreateServiceW(
                manager.0,
                name.as_ptr(),
                display_name.as_ptr(),
                SERVICE_ALL_ACCESS,
                SERVICE_WIN32_OWN_PROCESS,
                settings.start.code(),
                SERVICE_ERROR_NORMAL,
                command.as_ptr(),
                null(),
                null_mut(),
                dependencies.as_ptr(),
                settings.run_as.name(),
                null(),
            )
        };

        if service.is_null() {
            return Err(io::Error::last_os_error());
        }

        Ok(Service {
            handle: ServiceHandle(service),
        })
    }

    pub fn update(&self, settings: &Settings) -> io::Result<()> {
        let display_name = wide(settings.display_name);
        let command = wide(&program_command_line(settings.program, settings.arguments)?);
        let dependencies = string_list(settings.dependencies);

        // SAFETY: `self` keeps the service handle open until it drops; the strings are locals
        // NUL-terminated by `wide` and `string_list` (the list doubly) that outlive the call; null
        // leaves the account and the other settings unchanged.
        check(unsafe {
            ChangeServiceConfigW(
                self.handle.0,
                SERVICE_WIN32_OWN_PROCESS,
                settings.start.code(),
                SERVICE_ERROR_NORMAL,
                command.as_ptr(),
                null(),
                null_mut(),
                dependencies.as_ptr(),
                settings.run_as.name(),
                null(),
                display_name.as_ptr(),
            )
        })
    }

    pub fn set_description(&self, description: &str) -> io::Result<()> {
        let mut text = wide(description);
        let info = SERVICE_DESCRIPTIONW {
            lpDescription: text.as_mut_ptr(),
        };

        // SAFETY: `self` keeps the service handle open until it drops; `info` and `text` are
        // locals that outlive the call.
        check(unsafe {
            ChangeServiceConfig2W(
                self.handle.0,
                SERVICE_CONFIG_DESCRIPTION,
                (&raw const info).cast(),
            )
        })
    }

    pub fn restart_on_failure(&self, delay: Duration, reset_period: Duration) -> io::Result<()> {
        let reset_period = u32::try_from(reset_period.as_secs())
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;
        let mut restart = SC_ACTION {
            Type: SC_ACTION_RESTART,
            Delay: milliseconds(delay),
        };
        let info = SERVICE_FAILURE_ACTIONSW {
            dwResetPeriod: reset_period,
            lpRebootMsg: null_mut(),
            lpCommand: null_mut(),
            cActions: 1,
            lpsaActions: &raw mut restart,
        };

        // SAFETY: `self` keeps the service handle open until it drops; `info` and the one action
        // it points at are locals that outlive the call; null leaves the reboot message and
        // command unset.
        check(unsafe {
            ChangeServiceConfig2W(
                self.handle.0,
                SERVICE_CONFIG_FAILURE_ACTIONS,
                (&raw const info).cast(),
            )
        })
    }

    /// Windows takes every other privilege out of the service's token when it next starts.
    pub fn require_privileges(&self, privileges: &[&str]) -> io::Result<()> {
        let mut names = string_list(privileges);
        let info = SERVICE_REQUIRED_PRIVILEGES_INFOW {
            pmszRequiredPrivileges: names.as_mut_ptr(),
        };

        // SAFETY: `self` keeps the service handle open until it drops; `info` and the doubly
        // NUL-terminated list it points at (`string_list`) are locals that outlive the call.
        check(unsafe {
            ChangeServiceConfig2W(
                self.handle.0,
                SERVICE_CONFIG_REQUIRED_PRIVILEGES_INFO,
                (&raw const info).cast(),
            )
        })
    }

    pub fn start(&self) -> io::Result<()> {
        // SAFETY: `self` keeps the service handle open until it drops; no arguments.
        check(unsafe { StartServiceW(self.handle.0, 0, null()) })
    }

    pub fn request_stop(&self) -> io::Result<()> {
        let mut status = empty_status();
        // SAFETY: `self` keeps the service handle open until it drops; `status` is a local.
        check(unsafe { ControlService(self.handle.0, SERVICE_CONTROL_STOP, &raw mut status) })
    }

    pub fn is_stopped(&self) -> io::Result<bool> {
        let mut status = empty_status();
        // SAFETY: `self` keeps the service handle open until it drops; `status` is a local.
        check(unsafe { QueryServiceStatus(self.handle.0, &raw mut status) })?;
        Ok(status.dwCurrentState == SERVICE_STOPPED)
    }
}

extern "system" fn service_main(_count: u32, _arguments: *mut PWSTR) {
    let Some(running) = RUNNING.get() else { return };

    // SAFETY: `serve` stored the name, NUL-terminated by `wide`, in a static; `control` takes no
    // context.
    let status =
        unsafe { RegisterServiceCtrlHandlerExW(running.name.as_ptr(), Some(control), null_mut()) };

    if status.is_null() {
        // Without a status handle nothing can be reported; the service manager's start times out.
        return;
    }

    STATUS.store(status, Ordering::Release);
    report(SERVICE_RUNNING);
    (running.work)();
    report(SERVICE_STOPPED);
}

/// The work never returns, so a stop is answered by reporting STOPPED while it runs; the main
/// thread's dispatcher then returns, and the process ends with the work.
extern "system" fn control(
    code: u32,
    _kind: u32,
    _data: *mut c_void,
    _context: *mut c_void,
) -> u32 {
    match code {
        SERVICE_CONTROL_STOP | SERVICE_CONTROL_SHUTDOWN => {
            report(SERVICE_STOPPED);
            NO_ERROR
        }
        SERVICE_CONTROL_INTERROGATE => NO_ERROR,
        _ => ERROR_CALL_NOT_IMPLEMENTED,
    }
}

fn report(state: SERVICE_STATUS_CURRENT_STATE) {
    let accepted = if state == SERVICE_RUNNING {
        SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN
    } else {
        0
    };

    let status = SERVICE_STATUS {
        dwServiceType: SERVICE_WIN32_OWN_PROCESS,
        dwCurrentState: state,
        dwControlsAccepted: accepted,
        dwWin32ExitCode: NO_ERROR,
        dwServiceSpecificExitCode: 0,
        dwCheckPoint: 0,
        dwWaitHint: 0,
    };

    // A failed report leaves the service manager with the last state; there is nobody else to tell.
    // SAFETY: `STATUS` holds the handle `service_main` registered, which needs no closing and stays
    // valid while the process runs; `status` is a complete local.
    unsafe { SetServiceStatus(STATUS.load(Ordering::Acquire), &raw const status) };
}

#[derive(Debug)]
struct ServiceHandle(SC_HANDLE);

impl Drop for ServiceHandle {
    fn drop(&mut self) {
        // SAFETY: the handle was opened by the service manager and is closed exactly once, here.
        unsafe { CloseServiceHandle(self.0) };
    }
}

fn open_manager(access: u32) -> io::Result<ServiceHandle> {
    // SAFETY: null names mean this machine and its active services database.
    let manager = unsafe { OpenSCManagerW(null(), null(), access) };

    if manager.is_null() {
        return Err(io::Error::last_os_error());
    }

    Ok(ServiceHandle(manager))
}

fn open(name: &str, access: u32) -> io::Result<Option<Service>> {
    let manager = open_manager(SC_MANAGER_CONNECT)?;
    let name = wide(name);
    // SAFETY: `manager` stays open until it drops, and `name` is NUL-terminated (`wide`).
    let service = unsafe { OpenServiceW(manager.0, name.as_ptr(), access) };

    if !service.is_null() {
        return Ok(Some(Service {
            handle: ServiceHandle(service),
        }));
    }

    let error = io::Error::last_os_error();
    if error.raw_os_error() == Some(ERROR_SERVICE_DOES_NOT_EXIST.cast_signed()) {
        return Ok(None);
    }

    Err(error)
}

fn empty_status() -> SERVICE_STATUS {
    // SAFETY: `SERVICE_STATUS` is plain data for which all-zero bytes are a valid value.
    unsafe { std::mem::zeroed() }
}

/// NUL-terminated strings closed by an empty one, as dependency lists are; empty, it's two NULs.
fn string_list(names: &[&str]) -> Vec<u16> {
    let mut units = Vec::new();
    for name in names {
        units.extend(name.encode_utf16());
        units.push(0);
    }

    units.extend([0, 0]);
    units
}
