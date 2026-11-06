//! `cp-out`: one file or folder, as an archive whose single top entry is named after it. A folder
//! is walked depth first, parents before children, names sorted, links never followed; links and
//! special files are left out and counted.

use std::{
    fs::Metadata,
    io::{BufWriter, Write},
    path::Path,
    time::SystemTime,
};

use hangar_error::{Error, Result};
use hangar_fs::{Dir, Kind};

use crate::{entry_name, open_real_folder, tar_writer::TarWriter};

const OUTPUT_BUFFER_SIZE: usize = 64 * 1024;

/// Writes the archive of `path` to `output`; how many links and special files it left out.
pub(crate) fn write_archive(path: &str, output: impl Write) -> Result<usize> {
    let source = Source::find(path)?;
    let mut copy = CopyOut {
        archive: TarWriter::new(BufWriter::with_capacity(OUTPUT_BUFFER_SIZE, output)),
        skipped: 0,
    };

    copy.add_top(&source)?;

    copy.archive
        .finish()
        .map_err(|error| Error::file("copy", path, error))?;
    Ok(copy.skipped)
}

/// The item `cp-out` was given, by the folder it is in.
struct Source {
    path: String,
    folder: Dir,
    name: String,
}

impl Source {
    fn find(path: &str) -> Result<Source> {
        let fail = |reason: &dyn std::fmt::Display| Error::file("copy", path, reason);

        let full = std::path::absolute(path).map_err(|error| fail(&error))?;
        let (Some(parent), Some(name)) = (full.parent(), full.file_name()) else {
            return Err(fail(&"it has no name to copy it under"));
        };
        let Some(name) = name.to_str() else {
            return Err(fail(&"its name isn't UTF-8"));
        };
        entry_name::check_part(name).map_err(|reason| fail(&reason))?;

        Ok(Source {
            path: path.to_string(),
            folder: open_real_folder(parent).map_err(|error| fail(&error))?,
            name: name.to_string(),
        })
    }
}

struct CopyOut<W: Write> {
    archive: TarWriter<BufWriter<W>>,
    skipped: usize,
}

impl<W: Write> CopyOut<W> {
    /// Unlike the items inside a folder, the item asked for can't be left out.
    fn add_top(&mut self, source: &Source) -> Result<()> {
        let fail = |reason| Error::file("copy", &source.path, reason);

        match source.folder.entry(&source.name).map(|entry| entry.kind) {
            None => Err(fail("it doesn't exist or can't be read")),
            Some(Kind::Link) => Err(fail("it is a link")),
            Some(Kind::Other) => Err(fail("it isn't a regular file or a folder")),
            Some(Kind::File | Kind::Directory) => {
                let path = Path::new(&source.path);
                self.add(&source.folder, &source.name, &source.name, path)
            }
        }
    }

    /// Adds `child` of `folder` under `archive_name`; `path` names it in failures.
    fn add(&mut self, folder: &Dir, child: &str, archive_name: &str, path: &Path) -> Result<()> {
        // Gone since the folder was listed.
        let Some(entry) = folder.entry(child) else {
            return Ok(());
        };

        match entry.kind {
            Kind::File => self.add_file(folder, child, archive_name, path),
            Kind::Directory => {
                let subfolder = folder
                    .subdir(child)
                    .map_err(|error| Error::file("copy", path.display(), error))?;
                self.add_folder(&subfolder, archive_name, entry.modified, path)
            }
            Kind::Link | Kind::Other => {
                self.skipped += 1;
                Ok(())
            }
        }
    }

    /// Size, mode and time come from the opened file, so they match the contents read.
    fn add_file(
        &mut self,
        folder: &Dir,
        child: &str,
        archive_name: &str,
        path: &Path,
    ) -> Result<()> {
        let fail = |error: std::io::Error| Error::file("copy", path.display(), error);

        let mut file = folder.open_file(child).map_err(fail)?;
        let metadata = file.metadata().map_err(fail)?;
        let modified = metadata.modified().map_err(fail)?;

        self.archive
            .add_file(
                archive_name,
                is_executable(&metadata),
                metadata.len(),
                modified,
                &mut file,
            )
            .map_err(fail)
    }

    fn add_folder(
        &mut self,
        folder: &Dir,
        archive_name: &str,
        modified: SystemTime,
        path: &Path,
    ) -> Result<()> {
        let fail = |reason: &dyn std::fmt::Display| Error::file("copy", path.display(), reason);

        self.archive
            .add_folder(archive_name, modified)
            .map_err(|error| fail(&error))?;

        let listing = folder.list().map_err(|error| fail(&error))?;
        if listing.non_utf8_names > 0 {
            let count = listing.non_utf8_names;
            return Err(fail(&format!("it holds {count} names that aren't UTF-8")));
        }

        for name in &listing.names {
            let child_path = path.join(name);
            entry_name::check_part(name)
                .map_err(|reason| Error::file("copy", child_path.display(), reason))?;
            self.add(folder, name, &format!("{archive_name}/{name}"), &child_path)?;
        }
        Ok(())
    }
}

#[cfg(unix)]
fn is_executable(metadata: &Metadata) -> bool {
    use std::os::unix::fs::PermissionsExt;

    metadata.permissions().mode() & 0o111 != 0
}

/// Windows files have no executable bit.
#[cfg(windows)]
fn is_executable(_metadata: &Metadata) -> bool {
    false
}
