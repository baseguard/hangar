//! This thread's window messages, handed to the windows they are for.

use std::ptr::null_mut;

use windows_sys::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, MSG, PM_REMOVE, PeekMessageW, TranslateMessage,
};

pub(crate) fn dispatch_waiting_messages() {
    // SAFETY: `MSG` is plain data for which all-zero bytes are a valid value.
    let mut message: MSG = unsafe { std::mem::zeroed() };

    // SAFETY: `message` is a local; a null window means every window of this thread.
    while unsafe { PeekMessageW(&raw mut message, null_mut(), 0, 0, PM_REMOVE) } != 0 {
        dispatch(&message);
    }
}

fn dispatch(message: &MSG) {
    // SAFETY: `message` came from this thread's queue and is passed back unchanged.
    unsafe {
        TranslateMessage(message);
        DispatchMessageW(message);
    }
}
