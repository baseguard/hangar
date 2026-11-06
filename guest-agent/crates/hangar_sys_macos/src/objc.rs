//! Every [`Id`] in this crate is nil or a live object of the class its name says, and every
//! `objc_msgSend` call is cast to the method's real C signature (see [`msg_send!`]).

use std::ffi::{CStr, c_char, c_void};

/// `id`.
pub(crate) type Id = *mut c_void;
/// `SEL`.
pub(crate) type Sel = *const c_void;

/// `NSUTF8StringEncoding`.
const UTF8_ENCODING: usize = 4;

#[link(name = "objc")]
unsafe extern "C" {
    fn objc_getClass(name: *const c_char) -> Id;
    fn sel_registerName(name: *const c_char) -> Sel;
    /// Declared without a signature on purpose; see [`msg_send!`].
    pub(crate) fn objc_msgSend();
    fn objc_autoreleasePoolPush() -> *mut c_void;
    fn objc_autoreleasePoolPop(pool: *mut c_void);
}

/// Has no `unsafe` block of its own: the caller's `unsafe` block states the method's real
/// signature and why the receiver is valid.
macro_rules! msg_send {
    ($receiver:expr, $selector:literal $(, $argument:expr => $kind:ty)* ; $result:ty) => {{
        let function = std::mem::transmute::<
            unsafe extern "C" fn(),
            unsafe extern "C" fn(
                $crate::objc::Id,
                $crate::objc::Sel
                $(, $kind)*
            ) -> $result,
        >($crate::objc::objc_msgSend);
        function($receiver, $crate::objc::selector($selector) $(, $argument)*)
    }};
}

pub(crate) use msg_send;

/// Nil when no such class is loaded.
pub(crate) fn class(name: &CStr) -> Id {
    // SAFETY: `name` is a NUL-terminated string that outlives the call.
    unsafe { objc_getClass(name.as_ptr()) }
}

pub(crate) fn selector(name: &CStr) -> Sel {
    // SAFETY: `name` is a NUL-terminated string that outlives the call; the runtime copies it.
    unsafe { sel_registerName(name.as_ptr()) }
}

/// Frees what `AppKit` hands back autoreleased as soon as `body` ends, instead of whenever the
/// event loop drains its own pool.
pub(crate) fn autoreleasing<T>(body: impl FnOnce() -> T) -> T {
    // SAFETY: pushing a pool has no preconditions; it is popped below on the same thread.
    let pool = unsafe { objc_autoreleasePoolPush() };

    let result = body();

    // SAFETY: `pool` was pushed above on this thread, and `body` popped every pool it pushed.
    unsafe { objc_autoreleasePoolPop(pool) };
    result
}

/// `+[NSObject alloc]`: the caller owns the new, uninitialized instance.
pub(crate) fn alloc(class: Id) -> Id {
    // SAFETY: `class` is a class object or nil; `+ (instancetype)alloc` takes no arguments.
    unsafe { msg_send!(class, c"alloc"; Id) }
}

/// Autoreleased.
pub(crate) fn ns_string(text: &str) -> Id {
    let string = alloc(class(c"NSString"));

    // SAFETY: `string` is a fresh NSString that the initializer takes over:
    // `- (instancetype)initWithBytes:(const void *)bytes length:(NSUInteger)len
    // encoding:(NSStringEncoding)encoding`; it copies the bytes, which `text` keeps alive for the
    // call. `- (instancetype)autorelease` hands the owned result to the current pool.
    unsafe {
        let string = msg_send!(string, c"initWithBytes:length:encoding:",
            text.as_ptr().cast::<c_void>() => *const c_void, text.len() => usize,
            UTF8_ENCODING => usize; Id);
        msg_send!(string, c"autorelease"; Id)
    }
}

pub(crate) fn rust_string(string: Id) -> Option<String> {
    // SAFETY: `string` is an NSString or nil; `- (const char *)UTF8String` takes no arguments.
    let bytes = unsafe { msg_send!(string, c"UTF8String"; *const c_char) };

    if bytes.is_null() {
        return None;
    }

    // SAFETY: `UTF8String` returned a NUL-terminated string that lives as long as the current
    // autorelease pool; it is copied before this returns.
    let text = unsafe { CStr::from_ptr(bytes) };
    Some(text.to_string_lossy().into_owned())
}
