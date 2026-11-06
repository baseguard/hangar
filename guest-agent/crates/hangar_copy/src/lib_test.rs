//! `cp-out` against real folders and the round trip through `cp-in`, with the archive helpers the
//! other tests share.

#![cfg(unix)]

use std::{
    error::Error,
    fs::{self, File},
    os::unix::{fs::PermissionsExt, fs::symlink, net::UnixListener},
    path::{Path, PathBuf},
    sync::atomic::{AtomicUsize, Ordering},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use tar::{EntryType, Header};

use crate::{copy_in::extract_archive, copy_out::write_archive, tar_writer::pax_record};

pub(crate) type TestResult = Result<(), Box<dyn Error>>;

static NEXT: AtomicUsize = AtomicUsize::new(0);

pub(crate) const BLOCK_SIZE: usize = 512;
const FILE_TIME: u64 = 1_700_000_000;
const FOLDER_TIME: u64 = 1_600_000_000;

pub(crate) fn temporary_folder() -> Result<PathBuf, Box<dyn Error>> {
    let unique = NEXT.fetch_add(1, Ordering::Relaxed);
    let path = std::env::temp_dir().join(format!("hangar-copy-{}-{unique}", std::process::id()));

    fs::create_dir_all(&path)?;
    Ok(path)
}

pub(crate) fn text(path: &Path) -> &str {
    path.to_str().unwrap()
}

pub(crate) fn time(seconds: u64) -> SystemTime {
    UNIX_EPOCH + Duration::from_secs(seconds)
}

pub(crate) fn mode(path: &Path) -> Result<u32, Box<dyn Error>> {
    Ok(fs::symlink_metadata(path)?.permissions().mode() & 0o7777)
}

pub(crate) fn write_file(path: &Path, contents: &str, mode: u32) -> TestResult {
    fs::write(path, contents)?;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))?;
    File::options()
        .write(true)
        .open(path)?
        .set_modified(time(FILE_TIME))?;
    Ok(())
}

/// A header the writer would never make, for archives from elsewhere: its name goes in as it is,
/// unchecked.
pub(crate) fn header(name: &[u8], entry_type: EntryType, mode: u32, size: u64) -> Header {
    let mut header = Header::new_ustar();
    header.as_old_mut().name[..name.len()].copy_from_slice(name);
    header.set_mode(mode);
    header.set_size(size);
    header.set_mtime(FILE_TIME);
    header.set_entry_type(entry_type);
    header.set_cksum();
    header
}

/// One entry: its header and its data.
pub(crate) struct Raw(pub(crate) Header, pub(crate) Vec<u8>);

pub(crate) fn folder(name: &str) -> Raw {
    Raw(
        header(name.as_bytes(), EntryType::Directory, 0o755, 0),
        Vec::new(),
    )
}

pub(crate) fn file(name: &[u8], contents: &str) -> Raw {
    file_with_mode(name, contents, 0o644)
}

pub(crate) fn file_with_mode(name: &[u8], contents: &str, mode: u32) -> Raw {
    let size = contents.len() as u64;
    Raw(
        header(name, EntryType::Regular, mode, size),
        contents.as_bytes().to_vec(),
    )
}

pub(crate) fn special(name: &[u8], entry_type: EntryType) -> Raw {
    Raw(header(name, entry_type, 0o777, 0), Vec::new())
}

pub(crate) fn extended(entry_type: EntryType, data: &[u8]) -> Raw {
    Raw(
        header(b"PaxHeader", entry_type, 0o644, data.len() as u64),
        data.to_vec(),
    )
}

pub(crate) fn pax(records: &[(&str, &str)]) -> Raw {
    let mut data = String::new();
    for (key, value) in records {
        data.push_str(&pax_record(key, value));
    }
    extended(EntryType::XHeader, data.as_bytes())
}

/// The entries, each padded, and the two zero blocks that end an archive.
pub(crate) fn archive(entries: &[Raw]) -> Vec<u8> {
    let mut archive = Vec::new();
    for Raw(header, data) in entries {
        archive.extend_from_slice(header.as_bytes());
        archive.extend_from_slice(data);
        archive.resize(archive.len().next_multiple_of(BLOCK_SIZE), 0);
    }
    archive.resize(archive.len() + 2 * BLOCK_SIZE, 0);
    archive
}

/// The names and kinds of the archive's headers as they are, long names and PAX headers too.
fn raw_headers(archive: &[u8]) -> Result<Vec<(EntryType, String)>, Box<dyn Error>> {
    let mut headers = Vec::new();
    let mut reader = tar::Archive::new(archive);
    for entry in reader.entries()?.raw(true) {
        let entry = entry?;
        let name = String::from_utf8_lossy(&entry.header().path_bytes()).into_owned();
        headers.push((entry.header().entry_type(), name));
    }
    Ok(headers)
}

fn copy_out(path: &Path) -> Result<(Vec<u8>, usize), Box<dyn Error>> {
    let mut archive = Vec::new();
    let skipped = write_archive(text(path), &mut archive)?;
    Ok((archive, skipped))
}

pub(crate) fn failure(result: hangar_error::Result<usize>) -> String {
    result.map_err(|error| error.to_string()).unwrap_err()
}

#[test]
fn a_tree_survives_the_round_trip() -> TestResult {
    let source = temporary_folder()?;
    let top = source.join("project");
    let long_name = format!("{}.txt", "long".repeat(30));
    fs::create_dir_all(top.join("sub/deeper"))?;
    write_file(&top.join("notes.txt"), "hello", 0o600)?;
    write_file(&top.join("run.sh"), "#!/bin/sh\n", 0o700)?;
    write_file(&top.join("sub/deeper/data.bin"), &"x".repeat(1500), 0o644)?;
    write_file(&top.join("sub").join(&long_name), "long", 0o644)?;
    File::open(top.join("sub/deeper"))?.set_modified(time(FOLDER_TIME))?;
    let destination = temporary_folder()?;

    let (archive, skipped) = copy_out(&top)?;
    let placed = extract_archive(text(&destination), archive.as_slice())?;

    let copy = destination.join("project");
    assert_eq!((skipped, placed), (0, 0));
    assert_eq!(fs::read_to_string(copy.join("notes.txt"))?, "hello");
    assert_eq!(
        fs::read_to_string(copy.join("sub/deeper/data.bin"))?,
        "x".repeat(1500)
    );
    assert_eq!(
        fs::read_to_string(copy.join("sub").join(&long_name))?,
        "long"
    );
    assert_eq!(mode(&copy.join("notes.txt"))?, 0o644);
    assert_eq!(mode(&copy.join("run.sh"))?, 0o755);
    assert_eq!(mode(&copy.join("sub"))?, 0o755);
    assert_eq!(
        fs::metadata(copy.join("run.sh"))?.modified()?,
        time(FILE_TIME)
    );
    assert_eq!(
        fs::metadata(copy.join("sub/deeper"))?.modified()?,
        time(FOLDER_TIME)
    );

    fs::remove_dir_all(source)?;
    fs::remove_dir_all(destination)?;
    Ok(())
}

#[test]
fn the_archive_lists_parents_before_children_in_name_order() -> TestResult {
    let source = temporary_folder()?;
    let top = source.join("top");
    fs::create_dir_all(top.join("b"))?;
    fs::write(top.join("c.txt"), "")?;
    fs::write(top.join("a.txt"), "")?;
    fs::write(top.join("b/inner.txt"), "")?;

    let (archive, _) = copy_out(&top)?;

    let names: Vec<String> = raw_headers(&archive)?
        .into_iter()
        .map(|(_, name)| name)
        .collect();
    assert_eq!(
        names,
        [
            "top/",
            "top/a.txt",
            "top/b/",
            "top/b/inner.txt",
            "top/c.txt"
        ]
    );

    fs::remove_dir_all(source)?;
    Ok(())
}

#[test]
fn a_long_name_goes_in_a_gnu_long_name_entry_which_the_host_reads() -> TestResult {
    let source = temporary_folder()?;
    let long_name = format!("{}.txt", "long".repeat(30));
    fs::write(source.join(&long_name), "long")?;

    let (archive, _) = copy_out(&source.join(&long_name))?;

    let kinds: Vec<EntryType> = raw_headers(&archive)?
        .into_iter()
        .map(|(kind, _)| kind)
        .collect();
    assert_eq!(kinds, [EntryType::GNULongName, EntryType::Regular]);
    let mut reader = tar::Archive::new(archive.as_slice());
    let mut names = Vec::new();
    for entry in reader.entries()? {
        names.push(String::from_utf8(entry?.path_bytes().into_owned())?);
    }
    assert_eq!(names, [long_name]);

    fs::remove_dir_all(source)?;
    Ok(())
}

#[test]
fn links_and_special_files_are_left_out_and_counted() -> TestResult {
    let source = temporary_folder()?;
    let top = source.join("top");
    fs::create_dir(&top)?;
    fs::write(source.join("outside.txt"), "secret")?;
    fs::write(top.join("kept.txt"), "kept")?;
    symlink(source.join("outside.txt"), top.join("link.txt"))?;
    symlink(&source, top.join("link-to-folder"))?;
    let _socket = UnixListener::bind(top.join("socket"))?;
    let destination = temporary_folder()?;

    let (archive, skipped) = copy_out(&top)?;
    extract_archive(text(&destination), archive.as_slice())?;

    assert_eq!(skipped, 3);
    let mut copied: Vec<_> = fs::read_dir(destination.join("top"))?
        .map(|entry| entry.map(|entry| entry.file_name()))
        .collect::<Result<_, _>>()?;
    copied.sort();
    assert_eq!(copied, ["kept.txt"]);

    fs::remove_dir_all(source)?;
    fs::remove_dir_all(destination)?;
    Ok(())
}

#[test]
fn a_link_or_special_file_asked_for_is_refused() -> TestResult {
    let source = temporary_folder()?;
    fs::create_dir(source.join("real"))?;
    symlink(source.join("real"), source.join("link"))?;
    let _socket = UnixListener::bind(source.join("socket"))?;

    let link = write_archive(text(&source.join("link")), Vec::new());
    let socket = write_archive(text(&source.join("socket")), Vec::new());
    let missing = write_archive(text(&source.join("missing")), Vec::new());

    assert!(failure(link).ends_with("link: it is a link"));
    assert!(failure(socket).ends_with("it isn't a regular file or a folder"));
    assert!(failure(missing).ends_with("it doesn't exist or can't be read"));

    fs::remove_dir_all(source)?;
    Ok(())
}

#[test]
fn a_trailing_separator_on_the_source_is_ignored() -> TestResult {
    let source = temporary_folder()?;
    fs::create_dir(source.join("top"))?;

    let (archive, _) = copy_out(&source.join("top/"))?;

    assert_eq!(&archive[..5], b"top/\0");

    fs::remove_dir_all(source)?;
    Ok(())
}

#[test]
fn the_users_own_paths_may_go_through_links() -> TestResult {
    let parent = temporary_folder()?;
    fs::create_dir(parent.join("real"))?;
    fs::write(parent.join("real/source.txt"), "source")?;
    symlink(parent.join("real"), parent.join("link"))?;
    symlink(parent.join("real/source.txt"), parent.join("file-link"))?;
    let entries = [file(b"a.txt", "a")];

    let (copied_out, _) = copy_out(&parent.join("link/source.txt"))?;
    extract_archive(text(&parent.join("link")), archive(&entries).as_slice())?;
    extract_archive(
        &format!("{}/", text(&parent.join("link"))),
        archive(&entries).as_slice(),
    )?;
    let onto_file_link = extract_archive(
        text(&parent.join("file-link")),
        archive(&entries).as_slice(),
    );

    assert_eq!(&copied_out[..11], b"source.txt\0");
    assert_eq!(fs::read_to_string(parent.join("real/a.txt"))?, "a");
    assert!(failure(onto_file_link).contains("a link has its name"));
    assert_eq!(
        fs::read_to_string(parent.join("real/source.txt"))?,
        "source"
    );

    fs::remove_dir_all(parent)?;
    Ok(())
}
