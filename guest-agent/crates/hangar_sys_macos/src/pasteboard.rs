//! The general pasteboard as plain text.

use super::{
    MainThread,
    objc::{Id, autoreleasing, class, msg_send, ns_string, rust_string},
};

#[link(name = "AppKit", kind = "framework")]
unsafe extern "C" {
    static NSPasteboardTypeString: Id;
}

/// `+[NSPasteboard generalPasteboard]`.
fn general_pasteboard() -> Id {
    // SAFETY: `+ (NSPasteboard *)generalPasteboard` on the NSPasteboard class.
    unsafe { msg_send!(class(c"NSPasteboard"), c"generalPasteboard"; Id) }
}

/// `NSPasteboardTypeString`.
fn text_type() -> Id {
    // SAFETY: AppKit sets this NSString constant when it loads and never changes it.
    unsafe { NSPasteboardTypeString }
}

/// Goes up with every copy in any app.
pub fn pasteboard_changes(_main: MainThread) -> isize {
    autoreleasing(|| {
        // SAFETY: `- (NSInteger)changeCount` on the general NSPasteboard.
        unsafe { msg_send!(general_pasteboard(), c"changeCount"; isize) }
    })
}

pub fn pasteboard_text(_main: MainThread) -> Option<String> {
    autoreleasing(|| {
        // SAFETY: `- (NSString *)stringForType:(NSPasteboardType)dataType` on the general
        // NSPasteboard; the type is an NSString.
        let text =
            unsafe { msg_send!(general_pasteboard(), c"stringForType:", text_type() => Id; Id) };
        rust_string(text)
    })
}

/// Returns the change count this paste makes, so the caller can tell its own paste from the
/// user's copies.
pub fn set_pasteboard_text(_main: MainThread, text: &str) -> isize {
    autoreleasing(|| {
        let board = general_pasteboard();
        let string = ns_string(text);

        // SAFETY: on the general NSPasteboard: `- (NSInteger)clearContents`,
        // `- (BOOL)setString:(NSString *)string forType:(NSPasteboardType)dataType` with two
        // NSStrings, and `- (NSInteger)changeCount`. A refused string leaves the pasteboard
        // empty, which the change count also covers.
        unsafe {
            msg_send!(board, c"clearContents"; isize);
            msg_send!(board, c"setString:forType:", string => Id, text_type() => Id; bool);
            msg_send!(board, c"changeCount"; isize)
        }
    })
}
