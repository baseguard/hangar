//! Data a window procedure reaches through `GWLP_USERDATA`, shared with the window's owner.

use std::{ptr, rc::Rc};

use windows_sys::Win32::{
    Foundation::HWND,
    UI::WindowsAndMessaging::{GWLP_USERDATA, GetWindowLongPtrW, SetWindowLongPtrW},
};

/// Gives `window` a share of `data` for its procedure to find with [`data_of`].
///
/// # Safety
///
/// `window` is a window of this thread without data, and its owner calls [`release`] with the
/// same `data` once the window is destroyed.
pub(crate) unsafe fn attach<T>(window: HWND, data: &Rc<T>) {
    let share = Rc::into_raw(Rc::clone(data));

    // SAFETY: the caller passes a window of this thread; the value is the window's share, which
    // `release` takes back.
    unsafe {
        SetWindowLongPtrW(
            window,
            GWLP_USERDATA,
            share.expose_provenance().cast_signed(),
        )
    };
}

/// The window's data for one call of its procedure; `None` before [`attach`] and after
/// [`release`]. The share it returns keeps the data alive for the whole call, even when the
/// owner lets go of the window during it.
///
/// # Safety
///
/// `window` is a window of this thread whose data, if any, was attached as a `T`.
pub(crate) unsafe fn data_of<T>(window: HWND) -> Option<Rc<T>> {
    // SAFETY: the caller passes a window of this thread.
    let address = unsafe { GetWindowLongPtrW(window, GWLP_USERDATA) };
    let share = ptr::with_exposed_provenance::<T>(address.cast_unsigned());

    if share.is_null() {
        return None;
    }

    // SAFETY: a non-zero value is the window's share from `attach`, which keeps a count until
    // `release` clears the value; this call takes a count of its own.
    unsafe {
        Rc::increment_strong_count(share);
        Some(Rc::from_raw(share))
    }
}

/// Takes back the window's share. Called after the window is destroyed, when no message can
/// arrive; the value is cleared first anyway, so a stray message would find no data.
///
/// # Safety
///
/// `data` was attached to `window` with [`attach`] and hasn't been released.
pub(crate) unsafe fn release<T>(window: HWND, data: &Rc<T>) {
    // SAFETY: `window` is the owner's window of this thread; on a destroyed window the call fails
    // harmlessly.
    unsafe { SetWindowLongPtrW(window, GWLP_USERDATA, 0) };

    // SAFETY: `attach` gave the window this one count, and nothing else takes it back.
    unsafe { Rc::decrement_strong_count(Rc::as_ptr(data)) };
}
