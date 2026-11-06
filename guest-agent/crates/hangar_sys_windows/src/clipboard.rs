//! The clipboard, watched through a message-only window whose events reach a handler.

use std::{
    cell::RefCell,
    fmt, io,
    ptr::{null, null_mut},
    rc::Rc,
    thread::sleep,
    time::Duration,
};

use windows_sys::Win32::{
    Foundation::{GlobalFree, HANDLE, HGLOBAL, HWND, LPARAM, LRESULT, WPARAM},
    System::{
        DataExchange::{
            AddClipboardFormatListener, CloseClipboard, EmptyClipboard, GetClipboardData,
            GetClipboardSequenceNumber, IsClipboardFormatAvailable, OpenClipboard,
            SetClipboardData,
        },
        Memory::{GMEM_MOVEABLE, GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock},
        Ole::CF_UNICODETEXT,
    },
    UI::WindowsAndMessaging::{
        CreateWindowExW, DefWindowProcW, DestroyWindow, HWND_MESSAGE, PostMessageW, WM_APP,
        WM_CLIPBOARDUPDATE,
    },
};

use super::{check, register_class, this_module, wide, window_data};

const CLASS: &str = "HangarClipboard";
/// `WM_APP` and above are free for a program's own messages.
const WAKE: u32 = WM_APP + 1;
/// How many times to try opening the clipboard while another program holds it open, and how long
/// to wait between tries.
const OPEN_ATTEMPTS: usize = 10;
const OPEN_RETRY: Duration = Duration::from_millis(20);

#[derive(Clone, Copy, Debug)]
pub enum Event {
    /// The clipboard's contents changed, by any program, the agent included.
    Changed,
    Woken,
}

type HandlerFn = dyn FnMut(&Window, Event);
type Handler = RefCell<Box<HandlerFn>>;

/// The clipboard's message-only window; its events reach the handler while this thread runs a
/// message loop.
pub struct Listener {
    window: HWND,
    handler: Rc<Handler>,
}

impl fmt::Debug for Listener {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("Listener")
            .field("window", &self.window)
            .finish_non_exhaustive()
    }
}

/// Lets another thread wake the listener's thread: its handler then gets [`Event::Woken`].
#[derive(Clone, Copy, Debug)]
pub struct Waker {
    window: HWND,
}

// SAFETY: a `Waker` only posts to its window, which Windows allows from any thread; once the
// window is gone the post fails harmlessly.
unsafe impl Send for Waker {}

// SAFETY: as for `Send`: `&Waker` only reads the handle.
unsafe impl Sync for Waker {}

/// The listener's window, which owns the clipboard while the handler has it open; only the window
/// procedure hands one out.
#[derive(Debug)]
pub struct Window {
    window: HWND,
}

pub fn listen(handler: impl FnMut(&Window, Event) + 'static) -> io::Result<Listener> {
    let boxed: Box<HandlerFn> = Box::new(handler);
    let handler = Rc::new(RefCell::new(boxed));
    let window = create_message_window()?;

    // SAFETY: `window` was just made on this thread, without data; `Listener::drop` releases it
    // after destroying the window.
    unsafe { window_data::attach(window, &handler) };
    let listener = Listener { window, handler };

    // SAFETY: `window` is a window this thread just created.
    check(unsafe { AddClipboardFormatListener(window) })?;
    Ok(listener)
}

impl Listener {
    pub fn waker(&self) -> Waker {
        Waker {
            window: self.window,
        }
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        // SAFETY: `listen` made the window on this thread (`Listener` isn't `Send`); destroying
        // it also ends the clipboard listening.
        unsafe { DestroyWindow(self.window) };

        // SAFETY: `listen` attached the handler to this window, which is now destroyed; it is
        // released once, here.
        unsafe { window_data::release(self.window, &self.handler) };
    }
}

impl Waker {
    pub fn wake(&self) {
        // SAFETY: posting takes any window handle and fails harmlessly on a closed one. A post
        // fails only when the queue is full, and then earlier wake-ups are still waiting in it.
        unsafe { PostMessageW(self.window, WAKE, 0, 0) };
    }
}

pub fn sequence() -> u32 {
    // SAFETY: has no preconditions.
    unsafe { GetClipboardSequenceNumber() }
}

pub fn has_text() -> bool {
    // SAFETY: takes a format number and has no other preconditions.
    unsafe { IsClipboardFormatAvailable(u32::from(CF_UNICODETEXT)) != 0 }
}

impl Window {
    pub fn text(&self) -> Option<String> {
        let _clipboard = OpenedClipboard::open(self.window)?;
        // SAFETY: `_clipboard` keeps the clipboard open on this thread until it drops.
        let memory = unsafe { GetClipboardData(u32::from(CF_UNICODETEXT)) };

        if memory.is_null() {
            return None;
        }

        text_in(memory)
    }

    /// Returns the clipboard's sequence number after the change.
    pub fn set_text(&self, text: &str) -> Option<u32> {
        let mut units: Vec<u16> = text.encode_utf16().collect();
        units.push(0);

        let clipboard = OpenedClipboard::open(self.window)?;
        let placed = clipboard.replace_with(&units);
        // The change counts once the clipboard is closed, so read the number after that.
        drop(clipboard);

        if !placed {
            return None;
        }

        Some(sequence())
    }
}

struct OpenedClipboard;

impl OpenedClipboard {
    fn open(owner: HWND) -> Option<OpenedClipboard> {
        for _ in 0..OPEN_ATTEMPTS {
            // SAFETY: `owner` is the listener's window, which the handler that called this runs in.
            if unsafe { OpenClipboard(owner) } != 0 {
                return Some(OpenedClipboard);
            }
            sleep(OPEN_RETRY);
        }

        None
    }

    #[expect(
        clippy::unused_self,
        reason = "`&self` proves this thread has the clipboard open"
    )]
    fn replace_with(&self, units: &[u16]) -> bool {
        // SAFETY: `self` exists only while this thread has the clipboard open.
        if unsafe { EmptyClipboard() } == 0 {
            return false;
        }

        let Some(memory) = global_copy(units) else {
            return false;
        };

        // SAFETY: `self` exists only while this thread has the clipboard open, and it was emptied
        // just above; on success the system owns `memory`.
        let placed = !unsafe { SetClipboardData(u32::from(CF_UNICODETEXT), memory) }.is_null();

        if !placed {
            // SAFETY: the clipboard didn't take `memory`, so it is still ours to free, once.
            unsafe { GlobalFree(memory) };
        }

        placed
    }
}

impl Drop for OpenedClipboard {
    fn drop(&mut self) {
        // SAFETY: only `open` makes an `OpenedClipboard`, once this thread has opened the
        // clipboard; it is closed once, here.
        unsafe { CloseClipboard() };
    }
}

fn create_message_window() -> io::Result<HWND> {
    let class = wide(CLASS);
    register_class(&class, Some(procedure), null_mut(), null_mut())?;

    // SAFETY: the class was just registered with this module, its name outlives the call, and
    // `HWND_MESSAGE` makes a window that only receives messages.
    let window = unsafe {
        CreateWindowExW(
            0,
            class.as_ptr(),
            null(),
            0,
            0,
            0,
            0,
            0,
            HWND_MESSAGE,
            null_mut(),
            this_module(),
            null(),
        )
    };

    if window.is_null() {
        return Err(io::Error::last_os_error());
    }

    Ok(window)
}

extern "system" fn procedure(
    window: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    let event = match message {
        WM_CLIPBOARDUPDATE => Event::Changed,
        WAKE => Event::Woken,
        // SAFETY: hands Windows its own message back unchanged, as a procedure must for messages
        // it doesn't handle.
        _ => return unsafe { DefWindowProcW(window, message, wparam, lparam) },
    };

    // SAFETY: Windows calls this procedure only for windows of the listener class, made on this
    // thread, whose data is a `Handler`.
    let Some(handler) = (unsafe { window_data::data_of::<Handler>(window) }) else {
        return 0;
    };

    // A handler still running gets the event once it returns, from the back of the queue.
    let Ok(mut handler) = handler.try_borrow_mut() else {
        // SAFETY: posts to this thread's own window.
        unsafe { PostMessageW(window, message, wparam, lparam) };
        return 0;
    };

    handler(&Window { window }, event);
    0
}

fn text_in(memory: HANDLE) -> Option<String> {
    // SAFETY: `memory` is the clipboard's text block, valid while `text`'s `_clipboard` keeps the
    // clipboard open.
    let units = unsafe { GlobalLock(memory) }.cast::<u16>().cast_const();

    if units.is_null() {
        return None;
    }

    // SAFETY: the block is locked, so it stays in place and holds `GlobalSize` bytes.
    let capacity = unsafe { GlobalSize(memory) } / size_of::<u16>();
    let mut length = 0;
    // SAFETY: the locked block holds `capacity` units; reading stops at the first NUL or its end.
    while length < capacity && unsafe { *units.add(length) } != 0 {
        length += 1;
    }

    // SAFETY: the first `length` units were just read, so they are valid and stay locked.
    let text = String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(units, length) });
    // SAFETY: unlocks the lock taken above, after the last read through `units`.
    unsafe { GlobalUnlock(memory) };

    Some(text)
}

/// A new movable memory block holding `units`, as `SetClipboardData` needs.
fn global_copy(units: &[u16]) -> Option<HGLOBAL> {
    // SAFETY: allocates a block of the given size; there are no other preconditions.
    let memory = unsafe { GlobalAlloc(GMEM_MOVEABLE, size_of_val(units)) };

    if memory.is_null() {
        return None;
    }

    // SAFETY: `memory` is a movable block this function owns.
    let target = unsafe { GlobalLock(memory) }.cast::<u16>();

    if target.is_null() {
        // SAFETY: the block is ours and unlocked; it is freed once, here.
        unsafe { GlobalFree(memory) };
        return None;
    }

    // SAFETY: the locked block has room for `units.len()` units and doesn't overlap `units`.
    unsafe { std::ptr::copy_nonoverlapping(units.as_ptr(), target, units.len()) };
    // SAFETY: unlocks the lock taken above; `target` isn't used after this.
    unsafe { GlobalUnlock(memory) };

    Some(memory)
}
