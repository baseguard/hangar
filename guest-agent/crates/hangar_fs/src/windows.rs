//! Windows has no `*at` calls, so this works by path: each call checks that the item isn't a link
//! and then uses its path, which leaves a short window for a link to take its place.

use std::{
    ffi::OsString,
    fs::{self, File, Metadata, OpenOptions},
    io,
    os::windows::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    time::SystemTime,
};

use windows_sys::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
    FILE_WRITE_ATTRIBUTES,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    File,
    Directory,
    /// A symbolic link, junction or other reparse point; never followed.
    Link,
    Other,
}

#[derive(Debug)]
pub struct Entry {
    pub kind: Kind,
    pub modified: SystemTime,
}

/// A folder's children: their names, sorted, and how many have a name that isn't valid Unicode.
#[derive(Debug)]
pub struct Listing {
    pub names: Vec<String>,
    pub non_utf8_names: usize,
}

#[derive(Debug)]
pub struct Dir {
    path: PathBuf,
}

impl Dir {
    pub fn open(path: impl AsRef<Path>) -> io::Result<Dir> {
        Self::at(path.as_ref().to_path_buf())
    }

    /// Another handle on the same folder; checked again, like any opened folder.
    pub fn try_clone(&self) -> io::Result<Dir> {
        Self::at(self.path.clone())
    }

    pub fn subdir(&self, child: &str) -> io::Result<Dir> {
        Self::at(self.path.join(name(child)?))
    }

    /// The names of the folder's children, sorted; a child that can't be read fails the listing,
    /// and the names left out for not being valid Unicode are counted.
    pub fn list(&self) -> io::Result<Listing> {
        let mut listing = Listing {
            names: Vec::new(),
            non_utf8_names: 0,
        };

        for entry in fs::read_dir(verbatim(&self.path))? {
            match entry?.file_name().into_string() {
                Ok(name) => listing.names.push(name),
                Err(_not_unicode) => listing.non_utf8_names += 1,
            }
        }

        listing.names.sort();
        Ok(listing)
    }

    pub fn entry(&self, child: &str) -> Option<Entry> {
        let metadata = fs::symlink_metadata(self.full(child).ok()?).ok()?;

        Some(Entry {
            kind: kind(&metadata),
            modified: metadata.modified().ok()?,
        })
    }

    /// With `FILE_FLAG_OPEN_REPARSE_POINT` a link that has the name fails the create, unfollowed.
    pub fn create(&self, child: &str) -> io::Result<()> {
        OpenOptions::new()
            .write(true)
            .create_new(true)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
            .open(self.full(child)?)?;
        Ok(())
    }

    /// `FILE_FLAG_OPEN_REPARSE_POINT` opens a link itself, unfollowed, and the kind check refuses
    /// it.
    pub fn open_file(&self, child: &str) -> io::Result<File> {
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
            .open(self.full(child)?)?;

        if kind(&file.metadata()?) != Kind::File {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        Ok(file)
    }

    /// Opens `child` to write it from the start, creating it if missing; a link or folder is
    /// refused before anything in it changes. Windows files have no mode bits, so `_mode`, which
    /// Unix applies, is left out.
    pub fn write_file(&self, child: &str, _mode: u32) -> io::Result<File> {
        let file = OpenOptions::new()
            .write(true)
            .create(true)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
            .open(self.full(child)?)?;

        if kind(&file.metadata()?) != Kind::File {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        file.set_len(0)?;
        Ok(file)
    }

    pub fn mkdir(&self, child: &str) -> io::Result<()> {
        fs::create_dir(self.full(child)?)
    }

    /// Windows folders have no mode bits; this matches Unix's `set_mode` so callers read the same.
    pub fn set_mode(&self, _mode: u32) -> io::Result<()> {
        Ok(())
    }

    /// The folder is opened as itself, unfollowed, and must still be a folder.
    pub fn set_modified(&self, time: SystemTime) -> io::Result<()> {
        let folder = OpenOptions::new()
            .access_mode(FILE_WRITE_ATTRIBUTES)
            .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
            .open(verbatim(&self.path))?;

        if kind(&folder.metadata()?) != Kind::Directory {
            return Err(io::ErrorKind::NotADirectory.into());
        }
        folder.set_modified(time)
    }

    /// A log past `limit` is first moved to `<child>.old`, replacing the one before.
    pub fn open_log(&self, child: &str, limit: u64) -> io::Result<File> {
        let log = self.open_for_appending(child)?;
        if log.metadata()?.len() <= limit {
            return Ok(log);
        }

        drop(log);
        fs::rename(self.full(child)?, self.full(&format!("{child}.old"))?)?;
        self.open_for_appending(child)
    }

    /// `FILE_FLAG_OPEN_REPARSE_POINT` opens a link itself, unfollowed, and the kind check refuses
    /// it.
    fn open_for_appending(&self, child: &str) -> io::Result<File> {
        let file = OpenOptions::new()
            .append(true)
            .create(true)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
            .open(self.full(child)?)?;

        if kind(&file.metadata()?) != Kind::File {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        Ok(file)
    }

    fn at(path: PathBuf) -> io::Result<Dir> {
        if kind(&fs::symlink_metadata(verbatim(&path))?) != Kind::Directory {
            return Err(io::ErrorKind::NotADirectory.into());
        }

        Ok(Dir { path })
    }

    fn full(&self, child: &str) -> io::Result<PathBuf> {
        Ok(verbatim(&self.path.join(name(child)?)))
    }
}

/// `\\?\` paths reach the file system as written: no trimming, no `CON` devices, no length limit.
pub fn verbatim(path: &Path) -> PathBuf {
    if path.as_os_str().to_string_lossy().starts_with(r"\\?\") {
        return path.to_path_buf();
    }

    let mut full = OsString::from(r"\\?\");
    full.push(path);
    PathBuf::from(full)
}

/// `:` is refused too, since it would name an alternate data stream.
fn name(text: &str) -> io::Result<&str> {
    if text.is_empty() || text == "." || text == ".." || text.contains(['/', '\\', ':', '\0']) {
        return Err(io::ErrorKind::InvalidInput.into());
    }

    Ok(text)
}

fn kind(metadata: &Metadata) -> Kind {
    if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        Kind::Link
    } else if metadata.is_dir() {
        Kind::Directory
    } else if metadata.is_file() {
        Kind::File
    } else {
        Kind::Other
    }
}
