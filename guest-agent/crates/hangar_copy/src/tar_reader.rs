//! What `cp-in` and `take` need from each entry the tar crate reads: its name, kind, executable
//! bit and time, and its data, checked to be whole. GNU long names and PAX `path`, `size` and
//! `mtime` apply; every other extension is ignored.

use std::{
    io::{self, Read, Write},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use tar::EntryType;

const NAME_LIMIT: usize = 4 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum EntryKind {
    File,
    Folder,
    /// Links, devices, FIFOs and anything else; never created.
    Other,
}

#[derive(Debug)]
pub(crate) struct Entry {
    /// As the archive gives it, not yet checked.
    pub(crate) name: Vec<u8>,
    pub(crate) kind: EntryKind,
    pub(crate) is_executable: bool,
    pub(crate) modified: SystemTime,
}

/// The archive's input, noting whether it ran out. The tar crate takes input that stops between
/// entries as the end, but an archive ends with a zero block: input that stops before it was cut
/// off.
#[derive(Debug)]
pub(crate) struct TarInput<R: Read> {
    input: R,
    has_run_out: bool,
}

impl<R: Read> TarInput<R> {
    pub(crate) fn new(input: R) -> TarInput<R> {
        TarInput {
            input,
            has_run_out: false,
        }
    }

    /// Once the tar crate has seen the last entry.
    pub(crate) fn check_whole(&self) -> io::Result<()> {
        if self.has_run_out {
            return Err(cut_short());
        }
        Ok(())
    }
}

impl<R: Read> Read for TarInput<R> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let read = self.input.read(buffer)?;
        if read == 0 && !buffer.is_empty() {
            self.has_run_out = true;
        }
        Ok(read)
    }
}

/// `None` for a PAX global header, which describes no item.
pub(crate) fn describe(entry: &mut tar::Entry<impl Read>) -> io::Result<Option<Entry>> {
    let header = entry.header();
    let kind = match header.entry_type() {
        EntryType::XGlobalHeader => return Ok(None),
        EntryType::Regular | EntryType::Continuous => EntryKind::File,
        EntryType::Directory => EntryKind::Folder,
        _ => EntryKind::Other,
    };
    let is_executable = header.mode()? & 0o111 != 0;
    let header_seconds = header.mtime()?;

    let name = entry.path_bytes().into_owned();
    if name.len() > NAME_LIMIT {
        return Err(invalid("a name is longer than 4 KiB"));
    }

    let seconds = pax_seconds(entry)?.unwrap_or(header_seconds);
    let modified = UNIX_EPOCH
        .checked_add(Duration::from_secs(seconds))
        .ok_or_else(|| invalid("a header's time is out of range"))?;

    Ok(Some(Entry {
        name,
        kind,
        is_executable,
        modified,
    }))
}

/// Copies the entry's data to `to`; data that ends before the entry's size was cut off.
pub(crate) fn copy_data(entry: &mut tar::Entry<impl Read>, to: &mut impl Write) -> io::Result<()> {
    let size = entry.size();
    let copied = io::copy(entry, to)?;
    if copied < size {
        return Err(cut_short());
    }
    Ok(())
}

/// The entry's PAX `mtime`: decimal seconds, maybe with a fraction, which is dropped; times before
/// 1970 become 1970.
fn pax_seconds(entry: &mut tar::Entry<impl Read>) -> io::Result<Option<u64>> {
    let Some(records) = entry.pax_extensions()? else {
        return Ok(None);
    };

    for record in records {
        let record = record?;
        if record.key_bytes() != b"mtime" {
            continue;
        }
        let seconds = whole_seconds(record.value_bytes())
            .ok_or_else(|| invalid("a header's PAX time isn't a number"))?;
        return Ok(Some(seconds));
    }
    Ok(None)
}

fn whole_seconds(text: &[u8]) -> Option<u64> {
    let text = std::str::from_utf8(text).ok()?;
    let whole = text
        .split_once('.')
        .map_or(text, |(whole, _fraction)| whole);
    let seconds: i64 = whole.parse().ok()?;
    Some(u64::try_from(seconds).unwrap_or(0))
}

fn cut_short() -> io::Error {
    invalid("the archive ends in the middle of an entry")
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}
