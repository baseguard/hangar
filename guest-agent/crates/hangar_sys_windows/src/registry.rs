//! `HKEY_LOCAL_MACHINE` values the agent sets and reads, and the broadcast that follows a change to
//! the machine's environment variables.

use std::{io, ptr::null_mut, time::Duration};

use windows_sys::Win32::{
    Foundation::ERROR_FILE_NOT_FOUND,
    System::Registry::{
        HKEY_LOCAL_MACHINE, REG_SZ, RRF_RT_REG_DWORD, RRF_RT_REG_SZ, RegDeleteKeyValueW,
        RegGetValueW, RegSetKeyValueW,
    },
    UI::WindowsAndMessaging::{
        HWND_BROADCAST, SMTO_ABORTIFHUNG, SendMessageTimeoutW, WM_SETTINGCHANGE,
    },
};

use super::{milliseconds, size_u32, status, wide};

/// How long each program gets to take in a settings change before the broadcast moves on.
const SETTINGS_CHANGE_TIMEOUT: Duration = Duration::from_secs(5);

/// Sets the text value `value` of the `HKEY_LOCAL_MACHINE` key `key`, creating the key if needed.
pub fn set_registry_text(key: &str, value: &str, text: &str) -> io::Result<()> {
    let (key, value, data) = (wide(key), wide(value), wide(text));
    let size = u32::try_from(size_of_val(data.as_slice()))
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;

    // SAFETY: the names and `data` are NUL-terminated (`wide`) locals that outlive the call, and
    // `size` is `data`'s size in bytes, as `REG_SZ` needs.
    status(unsafe {
        RegSetKeyValueW(
            HKEY_LOCAL_MACHINE,
            key.as_ptr(),
            value.as_ptr(),
            REG_SZ,
            data.as_ptr().cast(),
            size,
        )
    })
}

/// The number value `value` of the `HKEY_LOCAL_MACHINE` key `key`, if it exists.
pub fn registry_number(key: &str, value: &str) -> Option<u32> {
    let (key, value) = (wide(key), wide(value));
    let mut number = 0u32;
    let mut size = size_u32::<u32>();

    // SAFETY: the names are NUL-terminated (`wide`); `number` is a local `u32` and `size` its
    // size; `RRF_RT_REG_DWORD` makes the call fail rather than write anything bigger.
    let code = unsafe {
        RegGetValueW(
            HKEY_LOCAL_MACHINE,
            key.as_ptr(),
            value.as_ptr(),
            RRF_RT_REG_DWORD,
            null_mut(),
            (&raw mut number).cast(),
            &raw mut size,
        )
    };

    if code != 0 {
        return None;
    }

    Some(number)
}

/// The text value `value` of the `HKEY_LOCAL_MACHINE` key `key`, if it exists.
pub fn registry_text(key: &str, value: &str) -> Option<String> {
    let (key, value) = (wide(key), wide(value));
    let mut size = 0u32;
    if !read_text(&key, &value, None, &mut size) {
        return None;
    }

    let mut text = vec![0u16; usize::try_from(size).ok()?.div_ceil(2)];
    if !read_text(&key, &value, Some(&mut text), &mut size) {
        return None;
    }

    let units = usize::try_from(size / 2).ok()?.min(text.len());
    let without_nul = text[..units].split(|&unit| unit == 0).next()?;
    Some(String::from_utf16_lossy(without_nul))
}

/// Reads the text value into `text`, or with no buffer only asks how big it is; `size` comes
/// back as the bytes the text takes.
fn read_text(key: &[u16], value: &[u16], text: Option<&mut [u16]>, size: &mut u32) -> bool {
    let (buffer, room) = match text {
        Some(text) => (
            text.as_mut_ptr().cast(),
            u32::try_from(size_of_val(text)).unwrap_or(u32::MAX),
        ),
        None => (null_mut(), 0),
    };
    *size = room;

    // SAFETY: the names are NUL-terminated (`wide`); `buffer` is null, so the call writes only the
    // size the text needs, or has room for `size` bytes, and `RRF_RT_REG_SZ` makes the call fail
    // rather than write anything else or anything bigger.
    let code = unsafe {
        RegGetValueW(
            HKEY_LOCAL_MACHINE,
            key.as_ptr(),
            value.as_ptr(),
            RRF_RT_REG_SZ,
            null_mut(),
            buffer,
            size,
        )
    };
    code == 0
}

/// Deletes the value `value` of the `HKEY_LOCAL_MACHINE` key `key`; one that is gone already is
/// fine.
pub fn delete_registry_value(key: &str, value: &str) -> io::Result<()> {
    let (key, value) = (wide(key), wide(value));
    // SAFETY: both names are NUL-terminated (`wide`) locals that outlive the call.
    let code = unsafe { RegDeleteKeyValueW(HKEY_LOCAL_MACHINE, key.as_ptr(), value.as_ptr()) };

    if code == ERROR_FILE_NOT_FOUND {
        return Ok(());
    }
    status(code)
}

/// Tells running programs that the machine's environment variables changed, as the System
/// control panel does; a program that hangs is skipped.
pub fn announce_environment_change() {
    let area = wide("Environment");
    let mut result = 0;

    // A broadcast reaches only the windows on the caller's desktop, so from the service in session
    // 0 it misses the signed-in user's Explorer; their programs see the change after a sign-in.
    // SAFETY: `area` is a NUL-terminated (`wide`) local that outlives the call, which waits for
    // each window; `result` is a local.
    unsafe {
        SendMessageTimeoutW(
            HWND_BROADCAST,
            WM_SETTINGCHANGE,
            0,
            area.as_ptr().addr().cast_signed(),
            SMTO_ABORTIFHUNG,
            milliseconds(SETTINGS_CHANGE_TIMEOUT),
            &raw mut result,
        )
    };
}
