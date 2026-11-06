//! Writes the archive `cp-out` sends, with the tar crate: GNU headers, a GNU long name before an
//! entry whose name doesn't fit, and a PAX `size` before a file of 8 GiB or more. The host reads
//! numbers as octal, so none is written in the binary form the tar crate uses past the octal field.

use std::{
    io::{self, Read, Write},
    time::{SystemTime, UNIX_EPOCH},
};

use tar::{Builder, EntryType, Header};

use crate::{EXECUTABLE_MODE, FILE_MODE, FOLDER_MODE};

/// The first value an 11-digit octal field can't hold, 8 GiB for a size.
const OCTAL_LIMIT: u64 = 8_u64.pow(11);
/// Readers ignore the name of a PAX header itself; this one is fixed so archives stay the same.
const PAX_HEADER_NAME: &str = "PaxHeader";

pub(crate) struct TarWriter<W: Write> {
    archive: Builder<W>,
}

impl<W: Write> TarWriter<W> {
    pub(crate) fn new(output: W) -> TarWriter<W> {
        TarWriter {
            archive: Builder::new(output),
        }
    }

    /// `name` has no trailing `/`; the archive's folder names get one.
    pub(crate) fn add_folder(&mut self, name: &str, modified: SystemTime) -> io::Result<()> {
        let mut header = new_header(EntryType::Directory, FOLDER_MODE, modified);
        header.set_size(0);
        self.archive
            .append_data(&mut header, format!("{name}/"), io::empty())
    }

    /// Writes exactly `size` bytes of `contents`; contents that end sooner fail the copy, since the
    /// header already promised `size`.
    pub(crate) fn add_file(
        &mut self,
        name: &str,
        is_executable: bool,
        size: u64,
        modified: SystemTime,
        contents: impl Read,
    ) -> io::Result<()> {
        let mode = if is_executable {
            EXECUTABLE_MODE
        } else {
            FILE_MODE
        };
        let mut header = new_header(EntryType::Regular, mode, modified);

        if size < OCTAL_LIMIT {
            header.set_size(size);
        } else {
            self.add_pax_size(size)?;
            header.set_size(0);
        }

        let promised = Promised {
            contents: contents.take(size),
        };
        self.archive.append_data(&mut header, name, promised)
    }

    /// Ends the archive with two zero blocks and hands back the output, flushed.
    pub(crate) fn finish(self) -> io::Result<W> {
        let mut output = self.archive.into_inner()?;
        output.flush()?;
        Ok(output)
    }

    fn add_pax_size(&mut self, size: u64) -> io::Result<()> {
        let record = pax_record("size", &size.to_string());
        let mut header = Header::new_ustar();
        header.set_entry_type(EntryType::XHeader);
        header.set_mode(FILE_MODE);
        header.set_size(record.len() as u64);
        self.archive
            .append_data(&mut header, PAX_HEADER_NAME, record.as_bytes())
    }
}

/// Owner and group stay 0, as the guest's own ids mean nothing on the host.
fn new_header(entry_type: EntryType, mode: u32, modified: SystemTime) -> Header {
    let mut header = Header::new_gnu();
    header.set_entry_type(entry_type);
    header.set_mode(mode);
    header.set_uid(0);
    header.set_gid(0);
    header.set_mtime(seconds_since_epoch(modified));
    header
}

/// `"<length> <key>=<value>\n"`, where the length counts the whole record, its own digits too.
pub(crate) fn pax_record(key: &str, value: &str) -> String {
    let rest = format!(" {key}={value}\n");
    let mut length = rest.len() + 1;
    while length != rest.len() + length.to_string().len() {
        length = rest.len() + length.to_string().len();
    }
    format!("{length}{rest}")
}

/// Times before 1970 are written as 1970, and times past the octal field's end as its last second.
fn seconds_since_epoch(time: SystemTime) -> u64 {
    let seconds = time
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| since.as_secs());
    seconds.min(OCTAL_LIMIT - 1)
}

/// A file's contents, at most the size its header promised; a file that got shorter fails.
struct Promised<R: Read> {
    contents: io::Take<R>,
}

impl<R: Read> Read for Promised<R> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let read = self.contents.read(buffer)?;
        if read == 0 && !buffer.is_empty() && self.contents.limit() > 0 {
            return Err(io::Error::other("it got shorter while it was copied"));
        }
        Ok(read)
    }
}

#[cfg(test)]
#[path = "tar_writer_test.rs"]
mod tests;
