//! The environment a command starts with, built anew for each one: the session helper's own
//! environment is from when the user signed in, so a variable the service set since, such as a
//! secret's placeholder, would be missing until the next sign-in.

use std::{
    ffi::{OsString, c_void},
    io,
    os::windows::ffi::OsStringExt,
    ptr::null_mut,
};

use windows_sys::Win32::{
    Security::{TOKEN_DUPLICATE, TOKEN_QUERY},
    System::Environment::{CreateEnvironmentBlock, DestroyEnvironmentBlock},
};

use super::{Handle, check, elevation::open_own_token, environment_block};

/// The machine's and this user's variables as the registry holds them now, as Explorer gives them
/// to a program it starts.
#[derive(Debug)]
pub struct UserEnvironment(Vec<u16>);

impl UserEnvironment {
    pub fn now() -> io::Result<UserEnvironment> {
        let token = open_own_token(TOKEN_QUERY | TOKEN_DUPLICATE)?;
        UserEnvironment::of(&token)
    }

    /// For the user whose primary token `token` is, opened for querying and duplicating.
    pub(crate) fn of(token: &Handle) -> io::Result<UserEnvironment> {
        let mut block = null_mut();
        // SAFETY: `token` is a primary token with the access the call needs, open while borrowed;
        // `block` is a local the call writes. Not inheriting builds the block from the registry
        // alone.
        check(unsafe { CreateEnvironmentBlock(&raw mut block, token.0, 0) })?;

        // SAFETY: the block from `CreateEnvironmentBlock` ends with an empty entry.
        let units = unsafe { copy_block(block.cast()) };
        // SAFETY: the block came from `CreateEnvironmentBlock` and is freed once, here, after it
        // was copied.
        unsafe { DestroyEnvironmentBlock(block) };
        Ok(UserEnvironment(units))
    }

    pub fn variables(&self) -> Vec<(OsString, OsString)> {
        environment_block::variables(&self.0)
            .into_iter()
            .map(|(name, value)| (OsString::from_wide(name), OsString::from_wide(value)))
            .collect()
    }

    /// For `CreateProcessW` with `CREATE_UNICODE_ENVIRONMENT`; valid while `self` lives.
    pub(crate) fn block(&self) -> *const c_void {
        self.0.as_ptr().cast()
    }
}

/// Copies an environment block up to its final empty entry: two NULs in a row, which no entry has.
///
/// # Safety
///
/// `block` must point to readable UTF-16 that ends with two NULs in a row.
unsafe fn copy_block(block: *const u16) -> Vec<u16> {
    let mut units: Vec<u16> = Vec::new();
    loop {
        // SAFETY: the caller promises the block goes on until two NULs in a row, and the loop
        // stops at them.
        let unit = unsafe { *block.add(units.len()) };
        let ends_entry_after_nul = unit == 0 && units.last() == Some(&0);
        units.push(unit);
        if ends_entry_after_nul {
            return units;
        }
    }
}
