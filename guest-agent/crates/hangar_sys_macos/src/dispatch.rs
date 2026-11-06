//! The main thread: `AppKit`'s event loop and the work other threads hand it.

use std::{ffi::c_void, marker::PhantomData, time::Duration};

use super::objc::{Id, autoreleasing, class, msg_send};

/// `NSApplicationActivationPolicyAccessory`: no Dock icon and no menu bar.
const ACCESSORY_APP: isize = 1;
const DISPATCH_TIME_NOW: u64 = 0;

// Grand Central Dispatch, in libSystem.
unsafe extern "C" {
    /// The main queue; `dispatch_get_main_queue()` is an inline function returning its address.
    static _dispatch_main_q: c_void;
    fn dispatch_async_f(
        queue: *const c_void,
        context: *mut c_void,
        work: extern "C" fn(*mut c_void),
    );
    fn dispatch_after_f(
        when: u64,
        queue: *const c_void,
        context: *mut c_void,
        work: extern "C" fn(*mut c_void),
    );
    fn dispatch_time(base: u64, delta: i64) -> u64;
}

/// Proof that the code holding it runs on the main thread, the only one `AppKit` may be called
/// on: only this file makes one, where the main thread is certain.
#[derive(Clone, Copy, Debug)]
pub struct MainThread {
    /// Not `Send`: the proof holds only on the thread it was made on.
    stays_on_its_thread: PhantomData<*const ()>,
}

impl MainThread {
    /// Callers have made sure this runs on the main thread.
    fn here() -> MainThread {
        MainThread {
            stays_on_its_thread: PhantomData,
        }
    }
}

/// Runs `AppKit`'s event loop, with `start` as its first work; returns only when the loop is
/// stopped, which the agent never does. `false` when called off the main thread.
pub fn run_app(start: impl FnOnce(MainThread) + Send + 'static) -> bool {
    if !is_main_thread() {
        return false;
    }

    on_main(start);

    autoreleasing(|| {
        // SAFETY: `+ (NSApplication *)sharedApplication` on the NSApplication class, on the main
        // thread (checked above).
        let app = unsafe { msg_send!(class(c"NSApplication"), c"sharedApplication"; Id) };

        // SAFETY: `app` is the shared NSApplication: `- (BOOL)setActivationPolicy:
        // (NSApplicationActivationPolicy)activationPolicy` (an NSInteger) and `- (void)run`. A
        // refused policy would only add a Dock icon, so the result isn't needed.
        unsafe {
            msg_send!(app, c"setActivationPolicy:", ACCESSORY_APP => isize; bool);
            msg_send!(app, c"run"; ());
        }
    });

    true
}

type Work = Box<dyn FnOnce(MainThread) + Send>;

pub fn on_main(work: impl FnOnce(MainThread) + Send + 'static) {
    // SAFETY: the main queue lives as long as the process, and `run_work` takes back the context
    // exactly once.
    unsafe { dispatch_async_f(main_queue(), into_context(work), run_work) };
}

pub fn after(delay: Duration, work: impl FnOnce(MainThread) + Send + 'static) {
    let delay = i64::try_from(delay.as_nanos()).unwrap_or(i64::MAX);

    // SAFETY: `dispatch_time` only computes a time; the main queue lives as long as the process,
    // and `run_work` takes back the context exactly once.
    unsafe {
        dispatch_after_f(
            dispatch_time(DISPATCH_TIME_NOW, delay),
            main_queue(),
            into_context(work),
            run_work,
        );
    }
}

fn is_main_thread() -> bool {
    // SAFETY: `pthread_main_np` has no preconditions and can't fail.
    unsafe { libc::pthread_main_np() == 1 }
}

fn main_queue() -> *const c_void {
    &raw const _dispatch_main_q
}

/// Leaks `work` into a pointer GCD can carry; [`run_work`] takes it back.
fn into_context(work: impl FnOnce(MainThread) + Send + 'static) -> *mut c_void {
    let work: Box<Work> = Box::new(Box::new(work));
    Box::into_raw(work).cast()
}

/// Runs work queued by [`on_main`] or [`after`]; GCD calls it once for each, on the main queue,
/// which runs on the main thread.
extern "C" fn run_work(context: *mut c_void) {
    // SAFETY: `context` came from `into_context`, and GCD passes each context to exactly one
    // call, so this takes back a live `Box<Work>` once.
    let work = unsafe { Box::from_raw(context.cast::<Work>()) };

    autoreleasing(|| work(MainThread::here()));
}
