//! `ls`: one folder of the guest, for browsing its files from the host. The host reads one JSON
//! object from stdout: the folder's absolute path, its parent and its entries in the order the file
//! system gives them. The host decodes the same shape; a change to it goes in both.
//!
//! A name that isn't valid UTF-8 (UTF-16 on Windows) is shown with U+FFFD in place of what can't be
//! decoded and marked `"lossy":true`: the shown name can't be used to copy the entry, so the host
//! lists it as not copyable. Other entries leave `lossy` out.

use std::{
    ffi::OsStr,
    fs::{self, DirEntry, FileType, Metadata},
    io::{self, Write},
    path::{Component, Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use hangar_error::{Error, Result};
use serde::Serialize;

/// Keeps the JSON small enough for the host to read in one go, even for a huge folder.
pub(crate) const MOST_ENTRIES: usize = 10_000;

/// One listed folder; `parent` is `None` at a root.
#[derive(Debug, Serialize)]
pub(crate) struct Listing {
    path: String,
    parent: Option<String>,
    truncated: bool,
    entries: Vec<Entry>,
}

#[derive(Debug, PartialEq, Eq, Serialize)]
struct Entry {
    name: String,
    kind: Kind,
    #[serde(rename = "link")]
    is_link: bool,
    /// The name lost characters it couldn't decode; left out when it didn't.
    #[serde(rename = "lossy", skip_serializing_if = "std::ops::Not::not")]
    is_lossy: bool,
    /// In bytes; 0 for anything but a file.
    size: u64,
    /// In seconds since 1970; 0 when unknown.
    modified: u64,
}

/// For a link, the kind of what it points to; `Other` when that doesn't resolve.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
enum Kind {
    Folder,
    File,
    Other,
}

/// The absolute folder `asked` names: relative to `home`, and `home` itself without one.
pub(crate) fn folder_path(home: &Path, asked: Option<&str>) -> Result<PathBuf> {
    let joined = home.join(asked.unwrap_or_default());

    absolute_path(&joined)
        .map_err(|error| Error::file("list", joined.display(), failure_reason(&error)))
}

fn absolute_path(joined: &Path) -> io::Result<PathBuf> {
    // Collecting the parts drops a trailing separator: `/tmp/` is listed as `/tmp`.
    let absolute: PathBuf = std::path::absolute(joined)?.components().collect();

    // After a link, `..` is the parent of the link's target, which only the file system knows.
    if absolute
        .components()
        .any(|part| part == Component::ParentDir)
    {
        return fs::canonicalize(absolute);
    }
    Ok(absolute)
}

/// Reads the folder at `path`, stopping after `limit` entries.
pub(crate) fn read_listing(path: &Path, limit: usize) -> Result<Listing> {
    let fail = |error: &io::Error| Error::file("list", path.display(), failure_reason(error));

    check_is_folder(path)?;
    let mut listing = Listing {
        path: path_text(path),
        parent: path.parent().map(path_text),
        truncated: false,
        entries: Vec::new(),
    };

    for item in fs::read_dir(path).map_err(|error| fail(&error))? {
        if listing.entries.len() == limit {
            listing.truncated = true;
            break;
        }
        let item = item.map_err(|error| fail(&error))?;
        listing.entries.push(describe(&item));
    }
    Ok(listing)
}

/// Writes the listing as one line of JSON.
pub(crate) fn write_listing(listing: &Listing, mut output: impl Write) -> Result<()> {
    serde_json::to_writer(&mut output, listing)
        .map_err(io::Error::from)
        .and_then(|()| output.write_all(b"\n"))
        .and_then(|()| output.flush())
        .map_err(|error| Error::step("write the listing", error))
}

/// Follows a link, so a link to a folder can be listed.
fn check_is_folder(path: &Path) -> Result<()> {
    let metadata = fs::metadata(path)
        .map_err(|error| Error::file("list", path.display(), failure_reason(&error)))?;

    if !metadata.is_dir() {
        return Err(Error::file("list", path.display(), "it isn't a folder"));
    }
    Ok(())
}

fn failure_reason(error: &io::Error) -> String {
    match error.kind() {
        io::ErrorKind::NotFound => "it doesn't exist".to_string(),
        io::ErrorKind::PermissionDenied => "permission denied".to_string(),
        io::ErrorKind::NotADirectory => "part of its path isn't a folder".to_string(),
        _ => error.to_string(),
    }
}

/// An entry whose metadata can't be read is still listed, as `Other` with no size or time.
fn describe(item: &DirEntry) -> Entry {
    let (name, is_lossy) = shown_name(&item.file_name());
    let Ok(own) = item.metadata() else {
        return Entry {
            name,
            kind: Kind::Other,
            is_link: false,
            is_lossy,
            size: 0,
            modified: 0,
        };
    };

    let is_link = own.file_type().is_symlink();
    // A link that doesn't resolve keeps its own metadata, whose kind is neither file nor folder.
    let shown = if is_link {
        fs::metadata(item.path()).unwrap_or(own)
    } else {
        own
    };
    entry(name, is_link, is_lossy, &shown)
}

/// The name as text, and whether characters that couldn't be decoded were replaced with U+FFFD.
fn shown_name(name: &OsStr) -> (String, bool) {
    match name.to_str() {
        Some(text) => (text.to_string(), false),
        None => (name.to_string_lossy().into_owned(), true),
    }
}

fn entry(name: String, is_link: bool, is_lossy: bool, metadata: &Metadata) -> Entry {
    let kind = kind_of(metadata.file_type());
    let size = if kind == Kind::File {
        metadata.len()
    } else {
        0
    };

    Entry {
        name,
        kind,
        is_link,
        is_lossy,
        size,
        modified: seconds_since_1970(metadata.modified().ok()),
    }
}

/// Sockets, devices and pipes are `Other`.
fn kind_of(file_type: FileType) -> Kind {
    if file_type.is_dir() {
        Kind::Folder
    } else if file_type.is_file() {
        Kind::File
    } else {
        Kind::Other
    }
}

/// 0 for a time the system can't give or one before 1970.
fn seconds_since_1970(time: Option<SystemTime>) -> u64 {
    let Some(time) = time else {
        return 0;
    };
    time.duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs())
}

/// A name that isn't valid Unicode is shown with U+FFFD in its place.
fn path_text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

#[cfg(all(test, unix))]
#[path = "list_test.rs"]
mod tests;
