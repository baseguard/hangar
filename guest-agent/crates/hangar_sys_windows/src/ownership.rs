//! Who owns a file or a kernel object, and opening an item without following a link at its end:
//! what the agent checks before it trusts a folder or a pipe.

use std::{
    io,
    path::Path,
    ptr::{null, null_mut},
};

use windows_sys::Win32::{
    Foundation::{HANDLE, INVALID_HANDLE_VALUE},
    Security::{
        Authorization::{GetSecurityInfo, SE_FILE_OBJECT, SE_OBJECT_TYPE},
        IsWellKnownSid, OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID,
        WinBuiltinAdministratorsSid, WinLocalSystemSid,
    },
    Storage::FileSystem::{
        BY_HANDLE_FILE_INFORMATION, CreateFileW, FILE_ATTRIBUTE_DIRECTORY,
        FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
        FILE_READ_ATTRIBUTES, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
        GetFileInformationByHandle, OPEN_EXISTING, READ_CONTROL,
    },
};

use super::{Handle, LocalMemory, check, status, wide};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ItemKind {
    Folder,
    /// A symbolic link, junction or other reparse point.
    Link,
    Other,
}

/// Well-known accounts an owner is compared with.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Account {
    System,
    Administrators,
}

/// A file or folder opened by path without following a link at its end.
#[derive(Debug)]
pub struct OpenedItem(Handle);

impl OpenedItem {
    pub fn kind(&self) -> io::Result<ItemKind> {
        // SAFETY: `BY_HANDLE_FILE_INFORMATION` is plain data for which all-zero bytes are valid.
        let mut info: BY_HANDLE_FILE_INFORMATION = unsafe { std::mem::zeroed() };
        // SAFETY: `self` keeps its handle open until it drops, and `info` is a local.
        check(unsafe { GetFileInformationByHandle(self.0.0, &raw mut info) })?;

        if info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return Ok(ItemKind::Link);
        }
        if info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0 {
            return Ok(ItemKind::Folder);
        }
        Ok(ItemKind::Other)
    }

    pub fn is_owned_by(&self, account: Account) -> io::Result<bool> {
        owner_is(self.0.0, SE_FILE_OBJECT, account)
    }
}

pub fn open_without_following(path: &Path) -> io::Result<OpenedItem> {
    let path = wide(path);
    // SAFETY: `path` is NUL-terminated (`wide`) and outlives the call; no security attributes or
    // template.
    let handle = unsafe {
        CreateFileW(
            path.as_ptr(),
            READ_CONTROL | FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            null(),
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            null_mut(),
        )
    };

    if handle == INVALID_HANDLE_VALUE {
        return Err(io::Error::last_os_error());
    }

    Ok(OpenedItem(Handle(handle)))
}

pub(crate) fn owner_is(handle: HANDLE, kind: SE_OBJECT_TYPE, account: Account) -> io::Result<bool> {
    let mut owner: PSID = null_mut();
    let mut descriptor: PSECURITY_DESCRIPTOR = null_mut();
    // SAFETY: callers pass a handle that a live `Handle` keeps open; `owner` and `descriptor`
    // receive pointers into one block that `LocalMemory` below frees; the parts not asked for may
    // be null.
    status(unsafe {
        GetSecurityInfo(
            handle,
            kind,
            OWNER_SECURITY_INFORMATION,
            &raw mut owner,
            null_mut(),
            null_mut(),
            null_mut(),
            &raw mut descriptor,
        )
    })?;
    let _descriptor = LocalMemory(descriptor);

    let known = match account {
        Account::System => WinLocalSystemSid,
        Account::Administrators => WinBuiltinAdministratorsSid,
    };

    // SAFETY: `owner` points into the descriptor block, which `_descriptor` keeps allocated until
    // this function returns.
    Ok(unsafe { IsWellKnownSid(owner, known) } != 0)
}
