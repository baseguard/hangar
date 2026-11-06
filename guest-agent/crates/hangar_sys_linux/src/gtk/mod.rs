//! GTK 4, opened with `dlopen` so the same binary installs and reports on guests without a desktop.
//!
//! GTK isn't thread-safe, so its tokens and handles aren't `Send`; other threads use [`MainQueue`].
//! `functions` finds GTK's functions, `dispatch` runs the handler and timers on GTK's thread.

mod dispatch;
mod functions;

use std::{
    cell::{Cell, RefCell},
    collections::VecDeque,
    ffi::{CStr, CString, c_char, c_int, c_uint, c_void},
    fmt,
    marker::PhantomData,
    ptr,
    time::Duration,
};

pub use dispatch::MainQueue;
pub use functions::{is_installed, load, missing_function};

use dispatch::{
    Dispatcher, Route, Timer, free_route, on_activate, on_clipboard_changed, on_startup,
    on_text_read, run_timer,
};
use functions::Functions;

pub(super) type Pointer = *mut c_void;
pub(super) type Callback = unsafe extern "C" fn();
pub(super) type SourceFunction = unsafe extern "C" fn(Pointer) -> c_int;
pub(super) type AsyncReadyCallback = unsafe extern "C" fn(Pointer, Pointer, Pointer);
pub(super) type ClosureNotify = unsafe extern "C" fn(Pointer, Pointer);

/// Each helper runs on its own instead of claiming a D-Bus name.
const G_APPLICATION_NON_UNIQUE: c_uint = 1 << 5;
const G_CONNECT_DEFAULT: c_uint = 0;

const FALSE: c_int = 0;

const UTF8_TEXT: &CStr = c"text/plain;charset=utf-8";
const X11_BACKEND: &CStr = c"x11";

#[derive(Debug)]
pub enum Event {
    Startup(App),
    /// A [`MainQueue::wake`] from another thread.
    Woken,
    ClipboardChanged,
    Text(Option<String>),
}

/// C's `G_CALLBACK`, used inside the caller's `unsafe` block. The handler is called with its
/// signal's arguments, so the caller vouches that `$signature` is that signal's signature; the
/// `let` makes the compiler check that `$handler` has exactly that type.
macro_rules! g_callback {
    ($handler:expr, $signature:ty) => {{
        let handler: $signature = $handler;
        std::mem::transmute::<$signature, Callback>(handler)
    }};
}

/// GTK before the application runs: only [`load`] makes one, on GTK's thread.
#[derive(Clone, Copy)]
pub struct Library {
    pub(super) functions: &'static Functions,
    /// Not `Send`: GTK may only be called on the thread that loaded it.
    pub(super) loading_thread_only: PhantomData<*const ()>,
}

impl fmt::Debug for Library {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_struct("Library").finish_non_exhaustive()
    }
}

impl Library {
    /// Must come before [`Library::run_application`], which opens the display.
    pub fn prefer_x11(self) {
        // SAFETY: `X11_BACKEND` is a `CStr` literal, so a NUL-terminated string that lives forever.
        unsafe { (self.functions.gdk_set_allowed_backends)(X11_BACKEND.as_ptr()) };
    }

    /// `handler` gets every [`Event`], one at a time: an event that comes while the handler or a
    /// timer runs waits until it returns. Returns GTK's exit status.
    pub fn run_application(
        self,
        id: &str,
        handler: impl FnMut(Gtk, Event) + 'static,
    ) -> Option<c_int> {
        let id = CString::new(id).ok()?;

        // SAFETY: `id` is a `CString` and the flag is a valid `GApplicationFlags` value.
        let app =
            unsafe { (self.functions.gtk_application_new)(id.as_ptr(), G_APPLICATION_NON_UNIQUE) };
        if app.is_null() {
            return None;
        }

        // Signal and source data point at it for the rest of the process, so it is never freed.
        let dispatcher: &'static Dispatcher = Box::leak(Box::new(Dispatcher {
            functions: self.functions,
            handler: RefCell::new(Box::new(handler)),
            pending: RefCell::new(VecDeque::new()),
            busy: Cell::new(false),
        }));
        let gtk = dispatcher.gtk();

        // SAFETY: `app` is non-null (checked above); GApplication's `startup` and `activate` pass
        // the application and the handler's data. GApplication warns when nothing handles
        // `activate`; the helpers have nothing to show.
        unsafe {
            let startup = g_callback!(on_startup, extern "C" fn(Pointer, Pointer));
            gtk.connect(app, c"startup", startup);
            let activate = g_callback!(on_activate, extern "C" fn(Pointer, Pointer));
            gtk.connect(app, c"activate", activate);
        }

        // SAFETY: `app` is non-null (checked above); GLib accepts a null `argv` when `argc` is 0.
        let status = unsafe { (self.functions.g_application_run)(app, 0, ptr::null_mut()) };
        Some(status)
    }
}

/// The running application's GTK: only the handler and timers get one, on GTK's thread.
#[derive(Clone, Copy)]
pub struct Gtk {
    pub(super) functions: &'static Functions,
    pub(super) dispatcher: &'static Dispatcher,
    /// Not `Send`: GTK may only be called on the thread that loaded it.
    pub(super) loading_thread_only: PhantomData<*const ()>,
}

impl fmt::Debug for Gtk {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_struct("Gtk").finish_non_exhaustive()
    }
}

impl Gtk {
    pub fn main_queue(self) -> MainQueue {
        MainQueue {
            functions: self.functions,
            dispatcher: self.dispatcher,
        }
    }

    pub fn after(self, delay: Duration, work: impl FnOnce(Gtk) + 'static) {
        let milliseconds = c_uint::try_from(delay.as_millis()).unwrap_or(c_uint::MAX);
        let timer = Box::new(Timer {
            dispatcher: self.dispatcher,
            work: Box::new(work),
        });

        // SAFETY: the data is the box leaked here, and `run_timer` frees it exactly once because
        // it returns `G_SOURCE_REMOVE`. A source added on GTK's thread runs on its main loop.
        unsafe {
            (self.functions.g_timeout_add)(milliseconds, run_timer, Box::into_raw(timer).cast())
        };
    }

    pub fn hold(self, app: &App) {
        // SAFETY: `app` owns a reference to the application, so it is alive.
        unsafe { (self.functions.g_application_hold)(app.0.pointer) };
    }

    pub fn clipboard(self) -> Option<Clipboard> {
        let display = self.default_display()?;

        // SAFETY: `display` is non-null from `default_display`; the clipboard it returns is
        // borrowed from the display, so `retain` takes a reference of our own.
        let clipboard = unsafe {
            let borrowed = (self.functions.gdk_display_get_clipboard)(display);
            Object::retain(self.functions, borrowed)
        };

        // SAFETY: `clipboard` holds a reference, so it is alive; GdkClipboard's `changed` passes
        // the clipboard and the handler's data.
        unsafe {
            let handler = g_callback!(on_clipboard_changed, extern "C" fn(Pointer, Pointer));
            self.connect(clipboard.pointer, c"changed", handler);
        }
        Some(Clipboard(clipboard))
    }

    /// Starts reading the clipboard's text; [`Event::Text`] brings it.
    pub fn read_text(self, clipboard: &Clipboard) {
        // SAFETY: `clipboard` owns a reference, so it is alive; the compiler checks `on_text_read`
        // against `GAsyncReadyCallback`, GTK allows a null cancellable, and the data is the
        // dispatcher, which is never freed.
        unsafe {
            (self.functions.gdk_clipboard_read_text_async)(
                clipboard.0.pointer,
                ptr::null_mut(),
                on_text_read,
                ptr::from_ref(self.dispatcher).cast_mut().cast(),
            );
        }
    }

    /// # Safety
    ///
    /// `object` is alive and has `signal`, and `handler` comes from `g_callback!` with that
    /// signal's signature.
    unsafe fn connect(self, object: Pointer, signal: &CStr, handler: Callback) {
        let route = Box::new(Route {
            dispatcher: self.dispatcher,
        });

        // SAFETY: the caller passes a live `object` that has `signal` and a matching `handler`.
        // The route box is leaked here and freed once, by `free_route`, when GLib drops the
        // handler.
        unsafe {
            (self.functions.g_signal_connect_data)(
                object,
                signal.as_ptr(),
                handler,
                Box::into_raw(route).cast(),
                Some(free_route),
                G_CONNECT_DEFAULT,
            )
        };
    }

    fn default_display(self) -> Option<Pointer> {
        // SAFETY: `gdk_display_get_default` has no preconditions; null means no display.
        let display = unsafe { (self.functions.gdk_display_get_default)() };
        if display.is_null() {
            return None;
        }
        Some(display)
    }

    /// # Safety
    ///
    /// `text` is null, or a NUL-terminated string from `g_malloc` that the caller owns and nothing
    /// else frees.
    pub(super) unsafe fn take_glib_string(self, text: *mut c_char) -> Option<String> {
        if text.is_null() {
            return None;
        }

        // SAFETY: the caller hands over an owned NUL-terminated string (checked non-null above);
        // it is copied before `g_free` releases it, once.
        unsafe {
            let copy = CStr::from_ptr(text).to_string_lossy().into_owned();
            (self.functions.g_free)(text.cast());
            Some(copy)
        }
    }
}

/// A `GObject` reference of its own, so the object outlives every call made through the handle.
pub(super) struct Object {
    pub(super) functions: &'static Functions,
    pub(super) pointer: Pointer,
}

impl Object {
    /// # Safety
    ///
    /// `pointer` is a live `GObject`, and this runs on GTK's thread.
    pub(super) unsafe fn retain(functions: &'static Functions, pointer: Pointer) -> Object {
        // SAFETY: the caller passes a live GObject; the reference taken here is released once,
        // by `drop`.
        unsafe { (functions.g_object_ref)(pointer) };
        Object { functions, pointer }
    }
}

impl Drop for Object {
    fn drop(&mut self) {
        // SAFETY: `retain` took this reference; `Object` isn't `Send`, so this runs on GTK's
        // thread, and it is released once, here.
        unsafe { (self.functions.g_object_unref)(self.pointer) };
    }
}

impl fmt::Debug for Object {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_struct("Object").finish_non_exhaustive()
    }
}

#[derive(Debug)]
pub struct App(pub(super) Object);

#[derive(Debug)]
pub struct Clipboard(Object);

impl Clipboard {
    /// Whether this process set the clipboard's contents.
    pub fn is_local(&self) -> bool {
        // SAFETY: `self` owns a reference, so the clipboard is alive.
        unsafe { (self.0.functions.gdk_clipboard_is_local)(self.0.pointer) != FALSE }
    }

    pub fn offers_text(&self) -> bool {
        // SAFETY: `self` owns a reference, so the clipboard is alive; the formats are borrowed
        // from it, so not released here.
        unsafe {
            let formats = (self.0.functions.gdk_clipboard_get_formats)(self.0.pointer);
            (self.0.functions.gdk_content_formats_contain_mime_type)(formats, UTF8_TEXT.as_ptr())
                != FALSE
        }
    }

    /// Drops NUL characters from `text`, which C strings can't hold.
    pub fn set_text(&self, text: &str) {
        let Ok(text) = CString::new(text.replace('\0', "")) else {
            return;
        };

        // SAFETY: `self` owns a reference, so the clipboard is alive; `text` is a `CString` that
        // GTK copies.
        unsafe { (self.0.functions.gdk_clipboard_set_text)(self.0.pointer, text.as_ptr()) };
    }
}
