//! Named kernel objects that let one session helper take over from another.

use std::{
    io,
    ptr::null,
    time::{Duration, Instant},
};

use windows_sys::Win32::{
    Foundation::{WAIT_ABANDONED, WAIT_EVENT, WAIT_OBJECT_0},
    System::Threading::{
        CreateEventW, CreateMutexW, INFINITE, ResetEvent, SetEvent, WaitForSingleObject,
    },
    UI::WindowsAndMessaging::{MsgWaitForMultipleObjects, QS_ALLINPUT},
};

use super::{Handle, check, message_loop, milliseconds, wide};

/// What `MsgWaitForMultipleObjects` returns when a message, not the one handle, ended the wait.
const MESSAGE_WAITING: WAIT_EVENT = WAIT_OBJECT_0 + 1;

#[derive(Debug)]
pub struct NamedEvent {
    handle: Handle,
}

#[derive(Debug)]
pub struct NamedMutex {
    handle: Handle,
}

impl NamedEvent {
    /// Manual-reset, made or opened.
    pub fn open(name: &str) -> io::Result<NamedEvent> {
        let name = wide(name);
        // SAFETY: no security attributes; `name` is NUL-terminated (`wide`) and outlives the call.
        let event = unsafe { CreateEventW(null(), 1, 0, name.as_ptr()) };

        if event.is_null() {
            return Err(io::Error::last_os_error());
        }

        Ok(NamedEvent {
            handle: Handle(event),
        })
    }

    pub fn signal(&self) -> io::Result<()> {
        // SAFETY: `self` keeps the event open until it drops.
        check(unsafe { SetEvent(self.handle.0) })
    }

    pub fn reset(&self) -> io::Result<()> {
        // SAFETY: `self` keeps the event open until it drops.
        check(unsafe { ResetEvent(self.handle.0) })
    }

    /// Hands this thread's window messages to their windows while it waits.
    pub fn signaled_within(&self, timeout: Duration) -> bool {
        // A timeout too long to add to now waits without a deadline instead of panicking.
        let deadline = Instant::now().checked_add(timeout);

        loop {
            let left = deadline.map_or(INFINITE, |deadline| {
                milliseconds(deadline.saturating_duration_since(Instant::now()))
            });
            // SAFETY: `self.handle` is one event handle, as the count says, open while `self`
            // lives; no message filter beyond the mask.
            let woken = unsafe {
                MsgWaitForMultipleObjects(1, &raw const self.handle.0, 0, left, QS_ALLINPUT)
            };

            match woken {
                WAIT_OBJECT_0 => return true,
                MESSAGE_WAITING => message_loop::dispatch_waiting_messages(),
                _ => return false,
            }
        }
    }
}

impl NamedMutex {
    /// Made or opened, not yet owned.
    pub fn open(name: &str) -> io::Result<NamedMutex> {
        let name = wide(name);
        // SAFETY: no security attributes; `name` is NUL-terminated (`wide`) and outlives the call.
        let mutex = unsafe { CreateMutexW(null(), 0, name.as_ptr()) };

        if mutex.is_null() {
            return Err(io::Error::last_os_error());
        }

        Ok(NamedMutex {
            handle: Handle(mutex),
        })
    }

    pub fn acquire_within(&self, timeout: Duration) -> bool {
        // SAFETY: `self` keeps the mutex open until it drops.
        let result = unsafe { WaitForSingleObject(self.handle.0, milliseconds(timeout)) };

        // An abandoned mutex means its owner ended without letting go; it is ours all the same.
        result == WAIT_OBJECT_0 || result == WAIT_ABANDONED
    }
}
