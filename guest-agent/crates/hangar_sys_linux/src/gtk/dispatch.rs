//! Runs the handler and timers one at a time on GTK's thread, and brings signals and other threads'
//! wake-ups to it; the `extern "C"` callbacks here are what `GLib` calls.

use std::{
    cell::{Cell, RefCell},
    collections::VecDeque,
    ffi::c_int,
    fmt,
    marker::PhantomData,
    ptr,
};

use super::{App, Event, Functions, Gtk, Object, Pointer};

const G_SOURCE_REMOVE: c_int = 0;

/// Runs the application's handler and timers one at a time on GTK's thread.
pub(crate) struct Dispatcher {
    pub(super) functions: &'static Functions,
    pub(super) handler: RefCell<Box<dyn FnMut(Gtk, Event)>>,
    pub(super) pending: RefCell<VecDeque<Event>>,
    /// The handler or a timer is running; GTK can send signals from inside its calls.
    pub(super) busy: Cell<bool>,
}

impl Dispatcher {
    pub(super) fn gtk(&'static self) -> Gtk {
        Gtk {
            functions: self.functions,
            dispatcher: self,
            loading_thread_only: PhantomData,
        }
    }

    fn dispatch(&'static self, event: Event) {
        self.pending.borrow_mut().push_back(event);
        self.run_pending();
    }

    pub(super) fn run_timer(&'static self, work: impl FnOnce(Gtk)) {
        let was_busy = self.busy.replace(true);
        work(self.gtk());
        self.busy.set(was_busy);

        self.run_pending();
    }

    fn run_pending(&'static self) {
        if self.busy.replace(true) {
            return;
        }

        loop {
            let next = self.pending.borrow_mut().pop_front();
            let Some(event) = next else { break };
            (self.handler.borrow_mut())(self.gtk(), event);
        }

        self.busy.set(false);
    }
}

/// How other threads reach GTK's thread: a wake-up arrives there as [`Event::Woken`].
#[derive(Clone, Copy)]
pub struct MainQueue {
    pub(super) functions: &'static Functions,
    pub(super) dispatcher: *const Dispatcher,
}

// SAFETY: other threads only hand the dispatcher's address to `g_idle_add`, which GLib allows from
// any thread; `run_wake` dereferences it on GTK's thread, and the dispatcher is never freed.
unsafe impl Send for MainQueue {}

// SAFETY: as for `Send`: `&MainQueue` only reads the two addresses.
unsafe impl Sync for MainQueue {}

impl fmt::Debug for MainQueue {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_struct("MainQueue").finish_non_exhaustive()
    }
}

impl MainQueue {
    pub fn wake(&self) {
        // SAFETY: GLib allows adding an idle source from any thread; `run_wake` reads the
        // dispatcher, which is never freed, on GTK's thread.
        unsafe { (self.functions.g_idle_add)(run_wake, self.dispatcher.cast_mut().cast()) };
    }
}

/// What a signal handler's data points at.
pub(super) struct Route {
    pub(super) dispatcher: &'static Dispatcher,
}

pub(super) struct Timer {
    pub(super) dispatcher: &'static Dispatcher,
    pub(super) work: Box<dyn FnOnce(Gtk)>,
}

/// # Safety
///
/// `data` is the route `Gtk::connect` gave the signal; `GLib` calls this on GTK's thread.
unsafe fn route<'a>(data: Pointer) -> &'a Route {
    // SAFETY: the caller passes a route box that stays allocated until `free_route`, which GLib
    // never calls while the handler runs.
    unsafe { &*data.cast::<Route>() }
}

pub(super) extern "C" fn free_route(data: Pointer, _closure: Pointer) {
    // SAFETY: `Gtk::connect` leaked this box for the one handler GLib is now dropping, and GLib
    // calls this destroy notify once per handler.
    drop(unsafe { Box::from_raw(data.cast::<Route>()) });
}

pub(super) extern "C" fn run_timer(data: Pointer) -> c_int {
    // SAFETY: `Gtk::after` leaked this box, and returning `G_SOURCE_REMOVE` makes GLib call this
    // once per box, on GTK's main loop, so each box is taken back once.
    let timer = unsafe { Box::from_raw(data.cast::<Timer>()) };
    timer.dispatcher.run_timer(timer.work);
    G_SOURCE_REMOVE
}

pub(super) extern "C" fn run_wake(data: Pointer) -> c_int {
    // SAFETY: `MainQueue::wake` passes the dispatcher, which is never freed; GLib runs idle
    // sources of the default context on GTK's main loop.
    let dispatcher = unsafe { &*data.cast::<Dispatcher>() };
    dispatcher.dispatch(Event::Woken);
    G_SOURCE_REMOVE
}

pub(super) extern "C" fn on_startup(app: Pointer, data: Pointer) {
    // SAFETY: GLib passes the application this route was connected to, on GTK's thread.
    let route = unsafe { route(data) };
    // SAFETY: `app` is the live application emitting `startup`.
    let app = unsafe { Object::retain(route.dispatcher.functions, app) };
    route.dispatcher.dispatch(Event::Startup(App(app)));
}

pub(super) extern "C" fn on_activate(_app: Pointer, _data: Pointer) {}

pub(super) extern "C" fn on_clipboard_changed(_clipboard: Pointer, data: Pointer) {
    // SAFETY: GLib passes this handler's route, on GTK's thread.
    let route = unsafe { route(data) };
    route.dispatcher.dispatch(Event::ClipboardChanged);
}

pub(super) extern "C" fn on_text_read(clipboard: Pointer, result: Pointer, data: Pointer) {
    // SAFETY: `Gtk::read_text` passes the dispatcher, which is never freed; GTK finishes reads on
    // its own thread.
    let dispatcher = unsafe { &*data.cast::<Dispatcher>() };
    let gtk = dispatcher.gtk();

    // SAFETY: GTK passes the clipboard and result of this read; the error output may be null.
    let text = unsafe {
        (gtk.functions.gdk_clipboard_read_text_finish)(clipboard, result, ptr::null_mut())
    };

    // SAFETY: the finish call returns null or a new `g_malloc` string that only we free.
    let text = unsafe { gtk.take_glib_string(text) };
    dispatcher.dispatch(Event::Text(text));
}
