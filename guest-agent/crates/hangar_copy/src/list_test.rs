use std::{
    error::Error,
    os::unix::{ffi::OsStrExt, fs::PermissionsExt, fs::symlink, net::UnixListener},
    time::Duration,
};

use super::*;

/// The line `write_listing` writes, without its line break.
fn json_of(listing: &Listing) -> String {
    let mut output = Vec::new();
    let written = write_listing(listing, &mut output);
    assert!(written.is_ok(), "{written:?}");
    String::from_utf8_lossy(&output).trim_end().to_string()
}
use crate::tests::{TestResult, failure, temporary_folder, text, time, write_file};

const FILE_TIME: u64 = 1_700_000_000;

fn sorted_entries(folder: &Path) -> std::result::Result<Vec<Entry>, Box<dyn Error>> {
    let mut entries = read_listing(folder, MOST_ENTRIES)?.entries;
    entries.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(entries)
}

fn listing_failure(path: &Path) -> String {
    failure(read_listing(path, MOST_ENTRIES).map(|_| 0))
}

#[test]
fn a_listing_is_one_json_object_in_the_hosts_shape() {
    let listing = Listing {
        path: "/home/admin".into(),
        parent: Some("/home".into()),
        truncated: false,
        entries: vec![
            Entry {
                name: "notes \"v2\".txt".into(),
                kind: Kind::File,
                is_link: false,
                is_lossy: false,
                size: 5,
                modified: FILE_TIME,
            },
            Entry {
                name: "Projects".into(),
                kind: Kind::Folder,
                is_link: true,
                is_lossy: false,
                size: 0,
                modified: 0,
            },
        ],
    };

    let json = json_of(&listing);

    assert_eq!(
        json,
        concat!(
            r#"{"path":"/home/admin","parent":"/home","truncated":false,"entries":["#,
            r#"{"name":"notes \"v2\".txt","kind":"file","link":false,"size":5,"modified":1700000000},"#,
            r#"{"name":"Projects","kind":"folder","link":true,"size":0,"modified":0}]}"#,
        )
    );
}

#[test]
fn a_name_that_lost_characters_is_marked_lossy() {
    let listing = Listing {
        path: "/home/admin".into(),
        parent: Some("/home".into()),
        truncated: false,
        entries: vec![Entry {
            name: "caf\u{fffd}.txt".into(),
            kind: Kind::File,
            is_link: false,
            is_lossy: true,
            size: 1,
            modified: 0,
        }],
    };

    let json = json_of(&listing);

    assert_eq!(
        json,
        concat!(
            r#"{"path":"/home/admin","parent":"/home","truncated":false,"entries":["#,
            "{\"name\":\"caf\u{fffd}.txt\",\"kind\":\"file\",\"link\":false,\"lossy\":true,",
            r#""size":1,"modified":0}]}"#,
        )
    );
}

#[test]
fn only_a_name_that_isnt_utf8_is_lossy() {
    let invalid = OsStr::from_bytes(b"caf\xe9.txt");

    assert_eq!(shown_name(invalid), ("caf\u{fffd}.txt".to_string(), true));
    assert_eq!(
        shown_name(OsStr::new("café.txt")),
        ("café.txt".to_string(), false)
    );
}

#[test]
fn a_root_has_a_null_parent_and_an_empty_folder_no_entries() {
    let listing = Listing {
        path: "/".into(),
        parent: None,
        truncated: true,
        entries: Vec::new(),
    };

    let json = json_of(&listing);

    assert_eq!(
        json,
        r#"{"path":"/","parent":null,"truncated":true,"entries":[]}"#
    );
}

#[test]
fn the_path_asked_for_starts_at_home_and_loses_a_trailing_separator() -> TestResult {
    let home = Path::new("/home/admin");

    assert_eq!(folder_path(home, None)?, home);
    assert_eq!(folder_path(home, Some(""))?, home);
    assert_eq!(
        folder_path(home, Some("Documents"))?,
        home.join("Documents")
    );
    assert_eq!(
        folder_path(home, Some("Documents/./a/"))?,
        home.join("Documents/a")
    );
    assert_eq!(folder_path(home, Some("/tmp/"))?, Path::new("/tmp"));
    assert_eq!(folder_path(home, Some("/"))?, Path::new("/"));
    Ok(())
}

#[test]
fn a_parent_part_after_a_link_goes_to_the_targets_parent() -> TestResult {
    let parent = temporary_folder()?;
    fs::create_dir_all(parent.join("real/inner"))?;
    symlink(parent.join("real/inner"), parent.join("link"))?;

    let listed = folder_path(&parent, Some("link/.."))?;

    assert_eq!(listed, fs::canonicalize(parent.join("real"))?);

    fs::remove_dir_all(parent)?;
    Ok(())
}

#[test]
fn a_listing_reports_its_path_and_parent() -> TestResult {
    let parent = temporary_folder()?;
    fs::create_dir(parent.join("real"))?;
    symlink(parent.join("real"), parent.join("link"))?;

    let through_link = read_listing(&parent.join("link"), MOST_ENTRIES)?;
    let root = read_listing(Path::new("/"), MOST_ENTRIES)?;

    assert_eq!(through_link.path, text(&parent.join("link")));
    assert_eq!(through_link.parent.as_deref(), Some(text(&parent)));
    assert_eq!((root.path.as_str(), root.parent), ("/", None));

    fs::remove_dir_all(parent)?;
    Ok(())
}

#[test]
fn links_show_what_they_point_to_and_special_files_are_other() -> TestResult {
    let folder = temporary_folder()?;
    write_file(&folder.join("notes.txt"), "hello", 0o644)?;
    fs::create_dir(folder.join("album"))?;
    symlink(folder.join("notes.txt"), folder.join("file-link"))?;
    symlink(folder.join("album"), folder.join("folder-link"))?;
    symlink(folder.join("missing"), folder.join("dangling-link"))?;
    let _socket = UnixListener::bind(folder.join("socket"))?;

    let entries = sorted_entries(&folder)?;

    let shown: Vec<(&str, Kind, bool, u64)> = entries
        .iter()
        .map(|entry| (entry.name.as_str(), entry.kind, entry.is_link, entry.size))
        .collect();
    assert_eq!(
        shown,
        [
            ("album", Kind::Folder, false, 0),
            ("dangling-link", Kind::Other, true, 0),
            ("file-link", Kind::File, true, 5),
            ("folder-link", Kind::Folder, true, 0),
            ("notes.txt", Kind::File, false, 5),
            ("socket", Kind::Other, false, 0),
        ]
    );
    assert_eq!(entries[4].modified, FILE_TIME);
    assert_eq!(entries[2].modified, FILE_TIME);

    fs::remove_dir_all(folder)?;
    Ok(())
}

#[test]
fn a_folder_past_the_limit_is_cut_and_marked_truncated() -> TestResult {
    let folder = temporary_folder()?;
    for name in ["a", "b", "c"] {
        fs::write(folder.join(name), "")?;
    }

    let whole = read_listing(&folder, 3)?;
    let cut = read_listing(&folder, 2)?;

    assert_eq!((whole.entries.len(), whole.truncated), (3, false));
    assert_eq!((cut.entries.len(), cut.truncated), (2, true));

    fs::remove_dir_all(folder)?;
    Ok(())
}

#[test]
fn a_missing_path_a_file_or_a_closed_folder_is_refused_in_plain_words() -> TestResult {
    let parent = temporary_folder()?;
    fs::write(parent.join("notes.txt"), "")?;
    fs::create_dir(parent.join("closed"))?;
    fs::set_permissions(parent.join("closed"), fs::Permissions::from_mode(0o000))?;

    let missing = listing_failure(&parent.join("missing"));
    let file = listing_failure(&parent.join("notes.txt"));
    let inside_file = listing_failure(&parent.join("notes.txt/inner"));
    let closed = listing_failure(&parent.join("closed"));

    let missing_path = parent.join("missing");
    assert_eq!(
        missing,
        format!("Could not list {}: it doesn't exist", text(&missing_path))
    );
    assert!(file.ends_with("notes.txt: it isn't a folder"), "{file}");
    assert!(
        inside_file.ends_with("part of its path isn't a folder"),
        "{inside_file}"
    );
    assert!(closed.ends_with("closed: permission denied"), "{closed}");

    fs::set_permissions(parent.join("closed"), fs::Permissions::from_mode(0o755))?;
    fs::remove_dir_all(parent)?;
    Ok(())
}

#[test]
fn the_listing_is_written_as_one_line() -> TestResult {
    let listing = Listing {
        path: "/".into(),
        parent: None,
        truncated: false,
        entries: Vec::new(),
    };
    let mut output = Vec::new();

    write_listing(&listing, &mut output)?;

    assert_eq!(
        String::from_utf8(output)?,
        "{\"path\":\"/\",\"parent\":null,\"truncated\":false,\"entries\":[]}\n"
    );
    Ok(())
}

#[test]
fn times_are_seconds_since_1970_and_an_unknown_or_older_time_is_zero() {
    assert_eq!(seconds_since_1970(Some(time(FILE_TIME))), FILE_TIME);
    assert_eq!(seconds_since_1970(None), 0);
    assert_eq!(
        seconds_since_1970(UNIX_EPOCH.checked_sub(Duration::from_secs(1))),
        0
    );
}
