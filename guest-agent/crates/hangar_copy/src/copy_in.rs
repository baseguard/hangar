//! `cp-in`: places an archive. Into an existing folder, the top entry keeps its name; anywhere
//! else it takes the destination's name. `take` places several top entries in one folder
//! instead, each under a name nothing there had. Every item is made relative to one
//! opened folder, part by part, never through a link; only regular files and folders are made,
//! with their contents, executable bit and time, and nothing else from the archive.

use std::{
    collections::HashSet,
    fmt::Display,
    fs,
    io::{self, Read},
    path::{self, Path},
    time::SystemTime,
};

use hangar_error::{Error, Result};
use hangar_fs::{Dir, Kind};

use crate::{
    EXECUTABLE_MODE, FILE_MODE, FOLDER_MODE, entry_name, open_real_folder,
    tar_reader::{self, Entry, EntryKind, TarInput},
};

const PARTIAL_COPY: &str = "what was already written stays";

/// Places the archive in `input` at `destination`; how many links and special files it left out.
pub(crate) fn extract_archive(destination: &str, input: impl Read) -> Result<usize> {
    let target = Target::find(destination)?;
    extract(target, destination, input)
}

/// Places every top entry of the archive in `input` in `folder`, each under a name nothing in the
/// folder had; a top name that comes back after other entries is refused rather than merged.
pub(crate) fn extract_items(folder: Dir, label: &str, input: impl Read) -> Result<usize> {
    let target = Target {
        folder,
        tops: Tops::Many(HashSet::new()),
    };
    extract(target, label, input)
}

fn extract(target: Target, destination: &str, input: impl Read) -> Result<usize> {
    let mut copy = CopyIn {
        target,
        top: None,
        folder_times: Vec::new(),
        skipped: 0,
    };
    let stopped = |error: io::Error| copy_failure("copy into", destination, error);

    let mut input = TarInput::new(input);
    let mut archive = tar::Archive::new(&mut input);
    for entry in archive.entries().map_err(stopped)? {
        let mut entry = entry.map_err(stopped)?;
        if let Some(described) = tar_reader::describe(&mut entry).map_err(stopped)? {
            copy.place(&described, &mut entry)?;
        }
    }
    input.check_whole().map_err(stopped)?;

    copy.set_folder_times().map_err(stopped)?;
    Ok(copy.skipped)
}

/// Once writing started, the user learns that part of the copy may be there.
fn copy_failure(action: &'static str, subject: impl Display, reason: impl Display) -> Error {
    Error::file(action, subject, format!("{reason}; {PARTIAL_COPY}"))
}

/// Where the archive's top entries go.
struct Target {
    folder: Dir,
    tops: Tops,
}

enum Tops {
    /// `cp-in`: one top entry, with the name it takes instead of its own; `None` keeps the
    /// archive's.
    One { rename_to: Option<String> },
    /// `take`: any number of top entries, each under a free name; the ones already seen.
    Many(HashSet<String>),
}

impl Target {
    fn find(destination: &str) -> Result<Target> {
        let fail = |reason: &dyn Display| Error::file("copy into", destination, reason);

        let full = path::absolute(destination).map_err(|error| fail(&error))?;
        if is_folder(&full) {
            let folder = open_real_folder(&full).map_err(|error| fail(&error))?;
            return Ok(Target {
                folder,
                tops: Tops::One { rename_to: None },
            });
        }
        if destination.ends_with(path::is_separator) {
            return Err(fail(&"no such directory"));
        }

        let (Some(parent), Some(name)) = (full.parent(), full.file_name()) else {
            return Err(fail(&"it has no name to copy to"));
        };
        let Some(name) = name.to_str() else {
            return Err(fail(&"its name isn't UTF-8"));
        };
        Ok(Target {
            folder: open_real_folder(parent).map_err(|error| fail(&error))?,
            tops: Tops::One {
                rename_to: Some(name.to_string()),
            },
        })
    }
}

/// A link to a folder counts: the destination is the user's own choice.
fn is_folder(path: &Path) -> bool {
    fs::metadata(path).is_ok_and(|metadata| metadata.is_dir())
}

/// The top entry the archive is at, with everything inside it.
struct Top {
    /// As the archive names it.
    name: String,
    /// The name it has in the target's folder; `None` until something of it is placed.
    placed_as: Option<String>,
}

struct CopyIn {
    target: Target,
    /// The current entry's top: with one top, the first entry's, which every entry shares.
    top: Option<Top>,
    /// Set once every item is written, since writing into a folder changes its time.
    folder_times: Vec<(Vec<String>, SystemTime)>,
    skipped: usize,
}

impl CopyIn {
    fn place(&mut self, entry: &Entry, data: &mut tar::Entry<impl Read>) -> Result<()> {
        let fail = |reason: &dyn Display| copy_failure("copy", printable(&entry.name), reason);

        let parts = entry_name::parts(&entry.name, entry.kind == EntryKind::Folder)
            .map_err(|reason| fail(&reason))?;
        let Some(top) = parts.first() else {
            return Err(fail(&"its name is empty"));
        };
        self.follow_top(top).map_err(|reason| fail(&reason))?;

        let placed = match entry.kind {
            EntryKind::Folder => self
                .placed_parts(parts, entry.kind)
                .and_then(|parts| self.make_folder(parts, entry.modified)),
            EntryKind::File => self
                .placed_parts(parts, entry.kind)
                .and_then(|parts| self.write_file(&parts, entry, data)),
            EntryKind::Other => {
                self.skipped += 1;
                Ok(())
            }
        };
        placed.map_err(|error| fail(&error))
    }

    /// With one top, every entry is inside the first entry; with many, each top's entries come
    /// together, since a top seen before other tops would land on what it already placed.
    fn follow_top(&mut self, top: &str) -> std::result::Result<(), String> {
        if let Some(current) = &self.top
            && current.name == top
        {
            return Ok(());
        }

        match &mut self.target.tops {
            Tops::One { .. } => {
                if let Some(first) = &self.top {
                    return Err(format!(
                        "it isn't inside {}, the archive's first entry",
                        first.name
                    ));
                }
            }
            Tops::Many(seen) => {
                if !seen.insert(top.to_string()) {
                    return Err(format!("{top} comes twice in the drop"));
                }
            }
        }

        self.top = Some(Top {
            name: top.to_string(),
            placed_as: None,
        });
        Ok(())
    }

    /// `parts` with the top part renamed to the top's name in the target's folder. With many
    /// tops, a top gets a free name when the first of its entries is placed.
    fn placed_parts(&mut self, mut parts: Vec<String>, kind: EntryKind) -> io::Result<Vec<String>> {
        let Some(top) = &mut self.top else {
            return Err(io::Error::other("it has no top folder"));
        };

        let placed_as = match (&top.placed_as, &self.target.tops) {
            (Some(name), _) => name.clone(),
            (None, Tops::One { rename_to }) => {
                rename_to.clone().unwrap_or_else(|| top.name.clone())
            }
            (None, Tops::Many(_)) => {
                let is_folder = kind == EntryKind::Folder || parts.len() > 1;
                claim_free_name(&self.target.folder, &top.name, is_folder)?
            }
        };

        if let Some(first) = parts.first_mut() {
            first.clone_from(&placed_as);
        }
        top.placed_as = Some(placed_as);
        Ok(parts)
    }

    /// An existing folder is only added to.
    fn make_folder(&mut self, parts: Vec<String>, modified: SystemTime) -> io::Result<()> {
        self.open_or_make_folders(&parts)?;
        self.folder_times.push((parts, modified));
        Ok(())
    }

    /// Replaces an existing regular file, keeping nothing of it.
    fn write_file(
        &self,
        parts: &[String],
        entry: &Entry,
        data: &mut tar::Entry<impl Read>,
    ) -> io::Result<()> {
        let Some((name, folders)) = parts.split_last() else {
            return Err(io::Error::other("its name is empty"));
        };
        let folder = self.open_or_make_folders(folders)?;
        refuse_anything_but_a_file(&folder, name)?;

        let mode = if entry.is_executable {
            EXECUTABLE_MODE
        } else {
            FILE_MODE
        };
        let mut file = folder.write_file(name, mode)?;
        tar_reader::copy_data(data, &mut file)?;
        file.set_modified(entry.modified)
    }

    /// Walks `parts` from the target's folder, making each folder that is missing.
    fn open_or_make_folders(&self, parts: &[String]) -> io::Result<Dir> {
        let mut folder = self.target.folder.try_clone()?;
        for part in parts {
            folder = open_or_make_folder(&folder, part)?;
        }
        Ok(folder)
    }

    fn set_folder_times(&self) -> io::Result<()> {
        for (parts, modified) in &self.folder_times {
            self.open_folders(parts)?.set_modified(*modified)?;
        }
        Ok(())
    }

    fn open_folders(&self, parts: &[String]) -> io::Result<Dir> {
        let mut folder = self.target.folder.try_clone()?;
        for part in parts {
            folder = folder.subdir(part)?;
        }
        Ok(folder)
    }
}

/// Makes an empty folder or file under `name`, or under the first numbered name nothing in
/// `folder` has, numbered like Finder does ("report 2.pdf", "album 2"); made, so nothing else
/// takes the name meanwhile. Returns the name it made.
fn claim_free_name(folder: &Dir, name: &str, is_folder: bool) -> io::Result<String> {
    let (base, extension) = if is_folder {
        (name, "")
    } else {
        split_extension(name)
    };
    let mut candidate = name.to_string();
    let mut number = 2;

    loop {
        let made = if is_folder {
            folder.mkdir(&candidate)
        } else {
            folder.create(&candidate)
        };
        match made {
            Ok(()) => break,
            // Windows can refuse a file whose name a folder has as access denied.
            Err(error)
                if error.kind() == io::ErrorKind::AlreadyExists
                    || folder.entry(&candidate).is_some() => {}
            Err(error) => return Err(error),
        }
        candidate = format!("{base} {number}{extension}");
        number += 1;
    }

    if is_folder {
        folder.subdir(&candidate)?.set_mode(FOLDER_MODE)?;
    }
    Ok(candidate)
}

/// The number goes before the last extension; a leading dot starts a name, not an extension.
fn split_extension(name: &str) -> (&str, &str) {
    let leading_dots = name.len() - name.trim_start_matches('.').len();
    match name[leading_dots..].rfind('.') {
        Some(dot) => name.split_at(leading_dots + dot),
        None => (name, ""),
    }
}

fn open_or_make_folder(parent: &Dir, name: &str) -> io::Result<Dir> {
    match parent.mkdir(name) {
        Ok(()) => {
            let folder = parent.subdir(name)?;
            folder.set_mode(FOLDER_MODE)?;
            Ok(folder)
        }
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            refuse_anything_but_a_folder(parent, name)?;
            parent.subdir(name)
        }
        Err(error) => Err(error),
    }
}

/// Clear reasons for what the no-follow opens after would refuse anyway.
fn refuse_anything_but_a_folder(parent: &Dir, name: &str) -> io::Result<()> {
    match parent.entry(name).map(|entry| entry.kind) {
        Some(Kind::Directory) | None => Ok(()),
        Some(Kind::Link) => Err(io::Error::other(format!("{name} on its path is a link"))),
        Some(Kind::File | Kind::Other) => Err(io::Error::other(format!(
            "{name} on its path isn't a folder"
        ))),
    }
}

fn refuse_anything_but_a_file(parent: &Dir, name: &str) -> io::Result<()> {
    match parent.entry(name).map(|entry| entry.kind) {
        Some(Kind::File) | None => Ok(()),
        Some(Kind::Link) => Err(io::Error::other("a link has its name")),
        Some(Kind::Directory) => Err(io::Error::other("a folder has its name")),
        Some(Kind::Other) => Err(io::Error::other("a special file has its name")),
    }
}

/// The name as text a terminal shows as it is: control characters escaped.
fn printable(name: &[u8]) -> String {
    let mut text = String::new();
    for character in String::from_utf8_lossy(name).chars() {
        if character.is_control() {
            text.extend(character.escape_default());
        } else {
            text.push(character);
        }
    }
    text
}

#[cfg(all(test, unix))]
#[path = "copy_in_test.rs"]
mod tests;
