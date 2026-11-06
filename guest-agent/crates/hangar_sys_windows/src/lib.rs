//! Windows system calls for Hangar's guest agent; elsewhere only the pure `command_line` module
//! builds, so its tests run on any host.

#![cfg(any(windows, test))]

#[cfg(windows)]
pub mod certificates;
#[cfg(windows)]
pub mod channel;
#[cfg(windows)]
pub mod clipboard;
mod command_line;
#[cfg(windows)]
pub mod devices;
#[cfg(windows)]
mod elevation;
#[cfg(windows)]
mod environment;
#[cfg(any(windows, test))]
mod environment_block;
#[cfg(windows)]
pub mod exec;
#[cfg(windows)]
pub mod instance;
#[cfg(windows)]
mod message_loop;
#[cfg(windows)]
mod ownership;
#[cfg(windows)]
mod registry;
#[cfg(windows)]
pub mod service;
#[cfg(windows)]
mod system;
#[cfg(windows)]
mod user_session;
#[cfg(windows)]
mod vsock;
#[cfg(windows)]
mod window_data;

pub use command_line::{command_line_of, program_command_line};
#[cfg(windows)]
pub use elevation::{is_elevated, run_elevated, start_elevated};
#[cfg(windows)]
pub use environment::UserEnvironment;
#[cfg(windows)]
pub use ownership::{Account, ItemKind, OpenedItem, open_without_following};
#[cfg(windows)]
pub use registry::{
    announce_environment_change, delete_registry_value, registry_number, registry_text,
    set_registry_text,
};
#[cfg(windows)]
pub use system::{
    PhysicalMemory, attach_to_parent_console, delete_at_restart, is_shutdown_in_progress,
    load_dlls_from_system32_only, physical_memory, profile, program_files, send_stderr_to,
    show_error, show_info, shut_down, system32, wide,
};
#[cfg(windows)]
pub use user_session::SignedInUser;
#[cfg(windows)]
pub use vsock::{VsockListener, VsockStream};

#[cfg(windows)]
pub(crate) use ownership::owner_is;
#[cfg(windows)]
pub(crate) use system::{
    Handle, LocalMemory, check, hresult, milliseconds, register_class, size_u32, status,
    this_module,
};
