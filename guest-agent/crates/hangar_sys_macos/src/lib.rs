//! macOS system calls for the guest agent; everything `AppKit` takes a [`MainThread`] proof.

#![cfg(target_os = "macos")]

mod dispatch;
mod objc;
mod pasteboard;
mod system;

pub use dispatch::{MainThread, after, on_main, run_app};
pub use pasteboard::{pasteboard_changes, pasteboard_text, set_pasteboard_text};
pub use system::{
    console_user_id, make_exclusive, make_raw, page_size, physical_memory, read_password,
    send_stderr_to, temporary_folder, vm_statistics,
};
