//! The service manager: creating, configuring, starting and stopping a service, and running as one.

use std::{
    ffi::{OsStr, OsString},
    fmt, io,
    path::Path,
    sync::OnceLock,
    time::Duration,
};

use windows_service::{
    Error as ServiceError, define_windows_service,
    service::{
        ServiceAccess, ServiceAction, ServiceActionType, ServiceControl, ServiceControlAccept,
        ServiceDependency, ServiceErrorControl, ServiceExitCode, ServiceFailureActions,
        ServiceFailureResetPeriod, ServiceInfo, ServiceStartType, ServiceState, ServiceStatus,
        ServiceType,
    },
    service_control_handler::{self, ServiceControlHandlerResult, ServiceStatusHandle},
    service_dispatcher,
    service_manager::{ServiceManager, ServiceManagerAccess},
};
use windows_sys::Win32::{
    Foundation::ERROR_SERVICE_DOES_NOT_EXIST,
    System::Services::{
        ChangeServiceConfig2W, SERVICE_CONFIG_REQUIRED_PRIVILEGES_INFO,
        SERVICE_REQUIRED_PRIVILEGES_INFOW,
    },
};

use super::{check, program_command_line};

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
    fn start_type(self) -> ServiceStartType {
        match self {
            Start::Automatic => ServiceStartType::AutoStart,
        }
    }
}

impl RunAs {
    /// None: creating the service then uses `LocalSystem`, and changing it keeps the account the
    /// service was created with.
    fn account(self) -> Option<OsString> {
        match self {
            RunAs::LocalSystem => None,
        }
    }
}

pub struct Service(windows_service::service::Service);

impl fmt::Debug for Service {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_struct("Service").finish_non_exhaustive()
    }
}

/// The service manager calls the service's main function with no context, so it finds the
/// service's name and work here.
static RUNNING: OnceLock<(OsString, fn())> = OnceLock::new();
/// `control` reports through this handle, which exists only after `control` is registered.
static STATUS: OnceLock<ServiceStatusHandle> = OnceLock::new();

define_windows_service!(ffi_service_main, service_main);

/// Hands this thread to the service manager, which runs `work` on a thread of its own.
pub fn serve(name: &str, work: fn()) -> io::Result<()> {
    if RUNNING.set((OsString::from(name), work)).is_err() {
        return Err(io::ErrorKind::AlreadyExists.into());
    }
    service_dispatcher::start(name, ffi_service_main).map_err(io_error)
}

impl Service {
    pub fn open_to_configure(name: &str) -> io::Result<Option<Service>> {
        open(name, ServiceAccess::ALL_ACCESS)
    }

    pub fn open_to_start(name: &str) -> io::Result<Option<Service>> {
        open(name, ServiceAccess::START)
    }

    pub fn open_to_stop(name: &str) -> io::Result<Option<Service>> {
        open(name, ServiceAccess::STOP | ServiceAccess::QUERY_STATUS)
    }

    pub fn create(settings: &Settings) -> io::Result<Service> {
        let access = ServiceManagerAccess::CONNECT | ServiceManagerAccess::CREATE_SERVICE;
        let manager = ServiceManager::local_computer(None::<&str>, access).map_err(io_error)?;
        let service = manager
            .create_service(&service_info(settings)?, ServiceAccess::ALL_ACCESS)
            .map_err(io_error)?;
        Ok(Service(service))
    }

    pub fn update(&self, settings: &Settings) -> io::Result<()> {
        self.0
            .change_config(&service_info(settings)?)
            .map_err(io_error)
    }

    pub fn set_description(&self, description: &str) -> io::Result<()> {
        self.0.set_description(description).map_err(io_error)
    }

    pub fn restart_on_failure(&self, delay: Duration, reset_period: Duration) -> io::Result<()> {
        let restart = ServiceAction {
            action_type: ServiceActionType::Restart,
            delay,
        };
        self.0
            .update_failure_actions(ServiceFailureActions {
                reset_period: ServiceFailureResetPeriod::After(reset_period),
                reboot_msg: None,
                command: None,
                actions: Some(vec![restart]),
            })
            .map_err(io_error)
    }

    /// Windows takes every other privilege out of the service's token when it next starts.
    pub fn require_privileges(&self, privileges: &[&str]) -> io::Result<()> {
        let mut names = string_list(privileges);
        let info = SERVICE_REQUIRED_PRIVILEGES_INFOW {
            pmszRequiredPrivileges: names.as_mut_ptr(),
        };

        // The service crate has no call for this setting.
        // SAFETY: `self` keeps the service handle open until it drops; `info` and the doubly
        // NUL-terminated list it points at (`string_list`) are locals that outlive the call.
        check(unsafe {
            ChangeServiceConfig2W(
                self.0.raw_handle(),
                SERVICE_CONFIG_REQUIRED_PRIVILEGES_INFO,
                (&raw const info).cast(),
            )
        })
    }

    pub fn start(&self) -> io::Result<()> {
        self.0.start::<&OsStr>(&[]).map_err(io_error)
    }

    pub fn request_stop(&self) -> io::Result<()> {
        self.0.stop().map(drop).map_err(io_error)
    }

    pub fn is_stopped(&self) -> io::Result<bool> {
        let status = self.0.query_status().map_err(io_error)?;
        Ok(status.current_state == ServiceState::Stopped)
    }
}

/// The settings as the service manager takes them. The arguments must be plain words, which
/// `program_command_line` checks, so no quoting rule can split or join them.
fn service_info(settings: &Settings) -> io::Result<ServiceInfo> {
    program_command_line(settings.program, settings.arguments)?;

    Ok(ServiceInfo {
        name: settings.name.into(),
        display_name: settings.display_name.into(),
        service_type: ServiceType::OWN_PROCESS,
        start_type: settings.start.start_type(),
        error_control: ServiceErrorControl::Normal,
        executable_path: settings.program.to_path_buf(),
        launch_arguments: settings.arguments.iter().map(OsString::from).collect(),
        dependencies: settings
            .dependencies
            .iter()
            .map(|name| ServiceDependency::Service(name.into()))
            .collect(),
        account_name: settings.run_as.account(),
        account_password: None,
    })
}

fn service_main(_arguments: Vec<OsString>) {
    let Some((name, work)) = RUNNING.get() else {
        return;
    };
    // Without a status handle nothing can be reported; the service manager's start times out.
    let Ok(status) = service_control_handler::register(name, control) else {
        return;
    };

    STATUS.get_or_init(|| status);
    report(ServiceState::Running);
    work();
    report(ServiceState::Stopped);
}

/// The work never returns, so a stop is answered by reporting STOPPED while it runs; the main
/// thread's dispatcher then returns, and the process ends with the work.
fn control(event: ServiceControl) -> ServiceControlHandlerResult {
    match event {
        ServiceControl::Stop | ServiceControl::Shutdown => {
            report(ServiceState::Stopped);
            ServiceControlHandlerResult::NoError
        }
        ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
        _ => ServiceControlHandlerResult::NotImplemented,
    }
}

fn report(state: ServiceState) {
    let Some(status) = STATUS.get() else {
        return;
    };
    let controls_accepted = if state == ServiceState::Running {
        ServiceControlAccept::STOP | ServiceControlAccept::SHUTDOWN
    } else {
        ServiceControlAccept::empty()
    };

    // A failed report leaves the service manager with the last state; there is nobody else to tell.
    status
        .set_service_status(ServiceStatus {
            service_type: ServiceType::OWN_PROCESS,
            current_state: state,
            controls_accepted,
            exit_code: ServiceExitCode::Win32(0),
            checkpoint: 0,
            wait_hint: Duration::ZERO,
            process_id: None,
        })
        .unwrap_or(());
}

fn open(name: &str, access: ServiceAccess) -> io::Result<Option<Service>> {
    let manager = ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)
        .map_err(io_error)?;

    match manager.open_service(name, access) {
        Ok(service) => Ok(Some(Service(service))),
        Err(ServiceError::Winapi(error))
            if error.raw_os_error() == Some(ERROR_SERVICE_DOES_NOT_EXIST.cast_signed()) =>
        {
            Ok(None)
        }
        Err(error) => Err(io_error(error)),
    }
}

/// The system's own error where there is one, so callers can still tell which it was.
fn io_error(error: ServiceError) -> io::Error {
    match error {
        ServiceError::Winapi(error) => error,
        other => io::Error::other(other),
    }
}

/// NUL-terminated strings closed by an empty one, as privilege lists are; empty, it's two NULs.
fn string_list(names: &[&str]) -> Vec<u16> {
    let mut units = Vec::new();
    for name in names {
        units.extend(name.encode_utf16());
        units.push(0);
    }

    units.extend([0, 0]);
    units
}
