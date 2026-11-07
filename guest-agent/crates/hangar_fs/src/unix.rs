//! Anything in a folder the agent works in may be a link planted by the host or another user, so
//! every call works relative to an open folder (`*at`) with `O_NOFOLLOW` or `AT_SYMLINK_NOFOLLOW`.

use std::{
    ffi::CString,
    fs::{File, Metadata, Permissions},
    io::{self, Read, Write},
    os::{fd::OwnedFd, unix::fs::PermissionsExt},
    path::Path,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use nix::{
    dir::Dir as DirStream,
    fcntl::{AtFlags, OFlag, open, openat, renameat},
    sys::stat::{Mode, SFlag, fstatat, mkdirat},
    unistd::{UnlinkatFlags, unlinkat},
};

/// Seen without following links.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    File,
    Directory,
    Link,
    Other,
}

/// Who owns a file [`Dir::replace_file`] writes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Owner {
    ThisUser,
    /// root:root, for files that run as root or configure what does.
    Root,
}

#[derive(Debug)]
pub struct Entry {
    pub kind: Kind,
    /// To the second.
    pub modified: SystemTime,
}

/// A folder's children: their names, sorted, and how many have a name that isn't UTF-8.
#[derive(Debug)]
pub struct Listing {
    pub names: Vec<String>,
    pub non_utf8_names: usize,
}

#[derive(Debug)]
pub struct Dir {
    fd: OwnedFd,
}

const FOLDER_FLAGS: OFlag = OFlag::O_RDONLY
    .union(OFlag::O_DIRECTORY)
    .union(OFlag::O_NOFOLLOW)
    .union(OFlag::O_CLOEXEC);
const NEW_FILE_FLAGS: OFlag = OFlag::O_WRONLY
    .union(OFlag::O_CREAT)
    .union(OFlag::O_EXCL)
    .union(OFlag::O_NOFOLLOW)
    .union(OFlag::O_CLOEXEC);
/// `O_NONBLOCK` keeps opening a FIFO someone put there from hanging; the kind is checked after.
const READ_FILE_FLAGS: OFlag = OFlag::O_RDONLY
    .union(OFlag::O_NOFOLLOW)
    .union(OFlag::O_NONBLOCK)
    .union(OFlag::O_CLOEXEC);
/// No `O_TRUNC`: nothing is emptied before the kind check; `O_NOCTTY` keeps a terminal someone put
/// there from becoming this process's.
const WRITE_FILE_FLAGS: OFlag = OFlag::O_WRONLY
    .union(OFlag::O_CREAT)
    .union(OFlag::O_NOFOLLOW)
    .union(OFlag::O_NONBLOCK)
    .union(OFlag::O_NOCTTY)
    .union(OFlag::O_CLOEXEC);
const LOG_FILE_FLAGS: OFlag = OFlag::O_WRONLY
    .union(OFlag::O_APPEND)
    .union(OFlag::O_CREAT)
    .union(OFlag::O_NOFOLLOW)
    .union(OFlag::O_NONBLOCK)
    .union(OFlag::O_CLOEXEC);

impl Dir {
    /// Opens the folder at `path`; the last component must not be a link.
    pub fn open(path: impl AsRef<Path>) -> io::Result<Dir> {
        let fd = open(path.as_ref(), FOLDER_FLAGS, Mode::empty())?;
        Ok(Dir { fd })
    }

    /// Another handle on the same folder.
    pub fn try_clone(&self) -> io::Result<Dir> {
        Ok(Dir {
            fd: self.fd.try_clone()?,
        })
    }

    pub fn subdir(&self, child: &str) -> io::Result<Dir> {
        Ok(Dir {
            fd: self.open_at(child, FOLDER_FLAGS, 0)?,
        })
    }

    /// The names of the folder's children, sorted, without `.`, `..` and names that aren't UTF-8,
    /// which are counted.
    pub fn list(&self) -> io::Result<Listing> {
        // The stream takes ownership of the fd it reads, so it gets its own opening of the same
        // folder: a `dup` would share the read offset and lack close-on-exec.
        let flags = OFlag::O_RDONLY | OFlag::O_DIRECTORY | OFlag::O_CLOEXEC;
        let mut stream = DirStream::openat(&self.fd, c".", flags, Mode::empty())?;

        let mut listing = Listing {
            names: Vec::new(),
            non_utf8_names: 0,
        };
        for entry in stream.iter() {
            match entry?.file_name().to_str() {
                Ok("." | "..") => {}
                Ok(text) => listing.names.push(text.to_string()),
                Err(_not_utf8) => listing.non_utf8_names += 1,
            }
        }
        listing.names.sort();
        Ok(listing)
    }

    pub fn entry(&self, child: &str) -> Option<Entry> {
        let child = name(child).ok()?;
        let info = fstatat(&self.fd, child.as_c_str(), AtFlags::AT_SYMLINK_NOFOLLOW).ok()?;

        let seconds = u64::try_from(info.st_mtime).unwrap_or(0);
        Some(Entry {
            kind: kind(info.st_mode),
            modified: UNIX_EPOCH + Duration::from_secs(seconds),
        })
    }

    /// Fails if anything, a link included, already has the name.
    pub fn create(&self, child: &str) -> io::Result<()> {
        self.open_at(child, NEW_FILE_FLAGS, 0o644)?;
        Ok(())
    }

    /// Links, FIFOs and devices are refused.
    pub fn open_file(&self, child: &str) -> io::Result<File> {
        let file = File::from(self.open_at(child, READ_FILE_FLAGS, 0)?);

        if !file.metadata()?.is_file() {
            return Err(invalid_name());
        }
        Ok(file)
    }

    /// A log past `limit` is first moved to `<child>.old`, replacing the one before.
    pub fn open_log(&self, child: &str, limit: u64) -> io::Result<File> {
        let log = self.open_for_appending(child)?;
        if log.metadata()?.len() <= limit {
            return Ok(log);
        }

        self.rename_over(child, &format!("{child}.old"))?;
        self.open_for_appending(child)
    }

    /// Links, FIFOs and devices are refused.
    fn open_for_appending(&self, child: &str) -> io::Result<File> {
        let file = File::from(self.open_at(child, LOG_FILE_FLAGS, 0o600)?);

        if !file.metadata()?.is_file() {
            return Err(invalid_name());
        }
        Ok(file)
    }

    pub fn create_file(&self, child: &str, mode: u32) -> io::Result<File> {
        Ok(File::from(self.open_at(
            child,
            NEW_FILE_FLAGS,
            mode & 0o777,
        )?))
    }

    /// Opens `child` to write it from the start, creating it if missing, and gives it exactly
    /// `mode`; a link, folder, FIFO or device is refused before anything in it changes.
    pub fn write_file(&self, child: &str, mode: u32) -> io::Result<File> {
        let file = File::from(self.open_at(child, WRITE_FILE_FLAGS, 0o600)?);

        if !file.metadata()?.is_file() {
            return Err(invalid_name());
        }
        file.set_len(0)?;
        file.set_permissions(Permissions::from_mode(mode & 0o777))?;
        Ok(file)
    }

    /// Exactly `mode`, whatever the umask.
    pub fn set_mode(&self, mode: u32) -> io::Result<()> {
        self.as_file()?
            .set_permissions(Permissions::from_mode(mode & 0o777))
    }

    pub fn set_modified(&self, time: SystemTime) -> io::Result<()> {
        self.as_file()?.set_modified(time)
    }

    /// The open folder's own owner and mode, so a check can't be about another folder put there.
    pub fn metadata(&self) -> io::Result<Metadata> {
        self.as_file()?.metadata()
    }

    /// The folder's own fd, duplicated, so std's file calls work on it.
    fn as_file(&self) -> io::Result<File> {
        Ok(File::from(self.fd.try_clone()?))
    }

    pub fn mkdir(&self, child: &str) -> io::Result<()> {
        let child = name(child)?;
        mkdirat(&self.fd, child.as_c_str(), Mode::from_bits_truncate(0o755))?;
        Ok(())
    }

    /// A link is removed itself, never its target.
    pub fn unlink(&self, child: &str) -> io::Result<()> {
        let child = name(child)?;
        unlinkat(&self.fd, child.as_c_str(), UnlinkatFlags::NoRemoveDir)?;
        Ok(())
    }

    /// Written beside its place and renamed over it, so a reader sees the old file or the whole
    /// new one. Only a regular file is replaced; a link or folder with the name is refused.
    pub fn replace_file(
        &self,
        child: &str,
        contents: &[u8],
        mode: u32,
        owner: Owner,
    ) -> io::Result<()> {
        if self
            .entry(child)
            .is_some_and(|entry| entry.kind != Kind::File)
        {
            return Err(io::Error::other("it exists and isn't a regular file"));
        }

        let temporary = format!(".{child}.{}", std::process::id());
        self.remove_leftover(&temporary)?;

        let written = self.write_private_file(&temporary, contents, mode, owner);
        let replaced = written.and_then(|()| self.rename_over(&temporary, child));

        if replaced.is_err() {
            hangar_error::note_failure("a temporary file stays behind", self.unlink(&temporary));
        }
        replaced
    }

    /// Makes `child` hold `wanted`, or removes it for `None`, through [`Dir::replace_file`];
    /// `false` when it already did, so nothing is written.
    pub fn update_file(
        &self,
        child: &str,
        wanted: Option<&[u8]>,
        mode: u32,
        owner: Owner,
    ) -> io::Result<bool> {
        let current = self.read_file(child)?;
        if current.as_deref() == wanted {
            return Ok(false);
        }

        match wanted {
            Some(contents) => self.replace_file(child, contents, mode, owner)?,
            None => self.unlink(child)?,
        }
        Ok(true)
    }

    /// `None` when there is no such file; a link, FIFO or device is refused.
    pub fn read_file(&self, child: &str) -> io::Result<Option<Vec<u8>>> {
        let mut file = match self.open_file(child) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };

        let mut contents = Vec::new();
        file.read_to_end(&mut contents)?;
        Ok(Some(contents))
    }

    /// A temporary file an interrupted run left with this process's number.
    fn remove_leftover(&self, child: &str) -> io::Result<()> {
        match self.unlink(child) {
            Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
            Ok(()) | Err(_) => Ok(()),
        }
    }

    /// Nobody else can read the file before its contents, mode and owner are final.
    fn write_private_file(
        &self,
        child: &str,
        contents: &[u8],
        mode: u32,
        owner: Owner,
    ) -> io::Result<()> {
        let mut file = self.create_file(child, 0o600)?;
        file.write_all(contents)?;

        if owner == Owner::Root {
            std::os::unix::fs::fchown(&file, Some(0), Some(0))?;
        }

        file.set_permissions(Permissions::from_mode(mode))?;
        file.sync_all()
    }

    fn rename_over(&self, child: &str, target: &str) -> io::Result<()> {
        let (child, target) = (name(child)?, name(target)?);
        renameat(&self.fd, child.as_c_str(), &self.fd, target.as_c_str())?;
        Ok(())
    }

    /// `mode` only counts when `flags` creates the file.
    fn open_at(&self, child: &str, flags: OFlag, mode: u32) -> io::Result<OwnedFd> {
        let child = name(child)?;
        Ok(openat(
            &self.fd,
            child.as_c_str(),
            flags,
            permissions(mode),
        )?)
    }
}

/// A child name that stays inside the folder: no `/`, not empty, `.` or `..`, no NUL.
fn name(text: &str) -> io::Result<CString> {
    if text.is_empty() || text == "." || text == ".." || text.contains('/') {
        return Err(invalid_name());
    }

    CString::new(text).map_err(|_nul_byte| invalid_name())
}

fn invalid_name() -> io::Error {
    io::ErrorKind::InvalidInput.into()
}

/// The permission bits of `mode`, in the type a mode has here: 32 bits on Linux, 16 on macOS.
fn permissions(mode: u32) -> Mode {
    Mode::from_bits_truncate(libc::mode_t::try_from(mode & 0o7777).unwrap_or_default())
}

fn kind(mode: libc::mode_t) -> Kind {
    match SFlag::from_bits_truncate(mode) & SFlag::S_IFMT {
        SFlag::S_IFREG => Kind::File,
        SFlag::S_IFDIR => Kind::Directory,
        SFlag::S_IFLNK => Kind::Link,
        _ => Kind::Other,
    }
}

#[cfg(test)]
#[path = "unix_test.rs"]
mod tests;
