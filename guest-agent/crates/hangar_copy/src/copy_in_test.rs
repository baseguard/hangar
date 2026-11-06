//! `cp-in` and `take` against real folders: what the reader places and what it refuses.

use std::os::unix::fs::symlink;

use tar::EntryType;

use super::*;
use crate::tests::{
    BLOCK_SIZE, Raw, TestResult, archive, extended, failure, file, file_with_mode, folder, header,
    mode, pax, special, temporary_folder, text, time, write_file,
};

#[test]
fn numbers_go_before_the_last_extension() {
    assert_eq!(split_extension("report.pdf"), ("report", ".pdf"));
    assert_eq!(split_extension("archive.tar.gz"), ("archive.tar", ".gz"));
    assert_eq!(split_extension(".bashrc"), (".bashrc", ""));
    assert_eq!(split_extension("notes"), ("notes", ""));
}

#[test]
fn every_unsafe_name_refuses_the_copy_and_keeps_what_was_written() -> TestResult {
    let cases: [(Raw, &str); 10] = [
        (file(b"", "x"), "an empty part"),
        (file(b"top/./x", "x"), "a '.' part"),
        (file(b"top/../x", "x"), "a '..' part"),
        (file(b"top/a\\b", "x"), "a backslash"),
        (file(b"top/a\x07b", "x"), "a control character"),
        (file(b"/etc/x", "x"), "absolute"),
        (file(b"top/\xff", "x"), "isn't UTF-8"),
        (file(b"other/x", "x"), "isn't inside top"),
        (file(b"other", "x"), "isn't inside top"),
        (folder("top/a/../../b/"), "a '..' part"),
    ];

    for (bad, reason) in cases {
        let destination = temporary_folder()?;
        let entries = [folder("top/"), file(b"top/kept.txt", "kept"), bad];

        let copied = extract_archive(text(&destination), archive(&entries).as_slice());

        let message = failure(copied);
        assert!(message.contains(reason), "{message}");
        assert!(
            message.ends_with("what was already written stays"),
            "{message}"
        );
        assert_eq!(
            fs::read_to_string(destination.join("top/kept.txt"))?,
            "kept"
        );
        fs::remove_dir_all(destination)?;
    }
    Ok(())
}

#[test]
fn a_nul_in_a_pax_name_is_refused() -> TestResult {
    let destination = temporary_folder()?;
    let entries = [pax(&[("path", "top/a\0b")]), file(b"top/a", "x")];

    let copied = extract_archive(text(&destination), archive(&entries).as_slice());

    assert!(failure(copied).contains("a NUL"));

    fs::remove_dir_all(destination)?;
    Ok(())
}

#[test]
fn into_an_existing_folder_the_top_entry_keeps_its_name() -> TestResult {
    let destination = temporary_folder()?;
    let entries = [folder("top/"), file(b"top/a.txt", "a")];

    extract_archive(
        &format!("{}/", text(&destination)),
        archive(&entries).as_slice(),
    )?;

    assert_eq!(fs::read_to_string(destination.join("top/a.txt"))?, "a");

    fs::remove_dir_all(destination)?;
    Ok(())
}

#[test]
fn a_missing_destination_takes_the_top_entrys_name() -> TestResult {
    let parent = temporary_folder()?;
    let folder_entries = [folder("top/"), file(b"top/a.txt", "a")];
    let file_entries = [file(b"single.txt", "single")];

    extract_archive(
        text(&parent.join("renamed")),
        archive(&folder_entries).as_slice(),
    )?;
    extract_archive(
        text(&parent.join("other.txt")),
        archive(&file_entries).as_slice(),
    )?;

    assert_eq!(fs::read_to_string(parent.join("renamed/a.txt"))?, "a");
    assert_eq!(fs::read_to_string(parent.join("other.txt"))?, "single");
    assert!(!parent.join("top").exists());

    fs::remove_dir_all(parent)?;
    Ok(())
}

#[test]
fn a_missing_destination_ending_in_a_separator_is_refused() -> TestResult {
    let parent = temporary_folder()?;
    let entries = [file(b"a.txt", "a")];

    let missing_folder = format!("{}/", text(&parent.join("missing")));
    let copied = extract_archive(&missing_folder, archive(&entries).as_slice());

    assert!(failure(copied).ends_with("no such directory"));
    assert!(!parent.join("missing").exists());

    fs::remove_dir_all(parent)?;
    Ok(())
}

#[test]
fn a_link_on_an_entrys_path_fails_the_copy() -> TestResult {
    let destination = temporary_folder()?;
    let elsewhere = temporary_folder()?;
    fs::create_dir(destination.join("top"))?;
    symlink(&elsewhere, destination.join("top/sub"))?;
    fs::write(elsewhere.join("victim.txt"), "kept")?;
    symlink(
        elsewhere.join("victim.txt"),
        destination.join("top/victim.txt"),
    )?;

    let through_folder = [folder("top/"), file(b"top/sub/planted.txt", "x")];
    let onto_file = [folder("top/"), file(b"top/victim.txt", "replaced")];
    let as_folder = [folder("top/"), folder("top/sub/")];

    let through_folder = extract_archive(text(&destination), archive(&through_folder).as_slice());
    let onto_file = extract_archive(text(&destination), archive(&onto_file).as_slice());
    let as_folder = extract_archive(text(&destination), archive(&as_folder).as_slice());

    assert!(failure(through_folder).contains("sub on its path is a link"));
    assert!(failure(onto_file).contains("a link has its name"));
    assert!(failure(as_folder).contains("sub on its path is a link"));
    assert!(!elsewhere.join("planted.txt").exists());
    assert_eq!(fs::read_to_string(elsewhere.join("victim.txt"))?, "kept");

    fs::remove_dir_all(destination)?;
    fs::remove_dir_all(elsewhere)?;
    Ok(())
}

#[test]
fn a_replaced_file_keeps_nothing_of_the_old_one() -> TestResult {
    let destination = temporary_folder()?;
    fs::create_dir(destination.join("top"))?;
    write_file(
        &destination.join("top/a.txt"),
        "a much longer old text",
        0o777,
    )?;
    let entries = [folder("top/"), file(b"top/a.txt", "new")];

    extract_archive(text(&destination), archive(&entries).as_slice())?;

    assert_eq!(fs::read_to_string(destination.join("top/a.txt"))?, "new");
    assert_eq!(mode(&destination.join("top/a.txt"))?, 0o644);

    fs::remove_dir_all(destination)?;
    Ok(())
}

#[test]
fn an_existing_item_of_the_wrong_kind_fails_the_copy() -> TestResult {
    let destination = temporary_folder()?;
    fs::create_dir_all(destination.join("top/folder"))?;
    fs::write(destination.join("top/file"), "kept")?;

    let file_over_folder = [folder("top/"), file(b"top/folder", "x")];
    let folder_over_file = [folder("top/"), folder("top/file/")];

    let file_over_folder =
        extract_archive(text(&destination), archive(&file_over_folder).as_slice());
    let folder_over_file =
        extract_archive(text(&destination), archive(&folder_over_file).as_slice());

    assert!(failure(file_over_folder).contains("a folder has its name"));
    assert!(failure(folder_over_file).contains("file on its path isn't a folder"));
    assert_eq!(fs::read_to_string(destination.join("top/file"))?, "kept");

    fs::remove_dir_all(destination)?;
    Ok(())
}

#[test]
fn only_the_executable_bit_of_a_mode_is_applied() -> TestResult {
    let destination = temporary_folder()?;
    let entries = [
        folder("top/"),
        file_with_mode(b"top/setuid", "x", 0o4755),
        file_with_mode(b"top/setgid", "x", 0o2644),
        file_with_mode(b"top/private", "x", 0o600),
    ];

    extract_archive(text(&destination), archive(&entries).as_slice())?;

    assert_eq!(mode(&destination.join("top/setuid"))?, 0o755);
    assert_eq!(mode(&destination.join("top/setgid"))?, 0o644);
    assert_eq!(mode(&destination.join("top/private"))?, 0o644);

    fs::remove_dir_all(destination)?;
    Ok(())
}

#[test]
fn pax_path_size_and_time_apply_and_other_records_are_ignored() -> TestResult {
    let destination = temporary_folder()?;
    let records = [
        ("SCHILY.xattr.user.planted", "1"),
        ("LIBARCHIVE.xattr.user.other", "eA=="),
        ("path", "top/from-pax.txt"),
        ("mtime", "1234567890.75"),
        ("size", "5"),
    ];
    let mut short_header = file(b"top/ignored-name", "hello");
    short_header.0 = header(b"top/ignored-name", EntryType::Regular, 0o644, 0);
    let entries = [folder("top/"), pax(&records), short_header];

    extract_archive(text(&destination), archive(&entries).as_slice())?;

    let copied = destination.join("top/from-pax.txt");
    assert_eq!(fs::read_to_string(&copied)?, "hello");
    assert_eq!(fs::metadata(&copied)?.modified()?, time(1_234_567_890));
    assert!(!destination.join("top/ignored-name").exists());

    fs::remove_dir_all(destination)?;
    Ok(())
}

#[test]
fn other_archives_are_read_too() -> TestResult {
    let destination = temporary_folder()?;
    let long_name = format!("top/{}", "n".repeat(150));
    let entries = [
        extended(EntryType::XGlobalHeader, b"30 comment=made elsewhere 123\n"),
        folder("top"),
        extended(EntryType::GNULongName, format!("{long_name}\0").as_bytes()),
        file(b"top/cut-name", "long"),
        special(b"top/link", EntryType::Symlink),
        special(b"top/hard", EntryType::Link),
        file(b"top/last.txt", "last"),
    ];

    let skipped = extract_archive(text(&destination), archive(&entries).as_slice())?;

    assert_eq!(skipped, 2);
    assert_eq!(fs::read_to_string(destination.join(&long_name))?, "long");
    assert_eq!(
        fs::read_to_string(destination.join("top/last.txt"))?,
        "last"
    );
    assert!(!destination.join("top/link").exists());

    fs::remove_dir_all(destination)?;
    Ok(())
}

#[test]
fn broken_archives_are_refused() -> TestResult {
    let mut bad_checksum = archive(&[file(b"a.txt", "a")]);
    bad_checksum[0] = b'b';
    let mut cut_short = archive(&[file(b"a.txt", "abc")]);
    cut_short.truncate(BLOCK_SIZE + 1);
    let mut cut_between_entries = archive(&[file(b"a.txt", "abc")]);
    cut_between_entries.truncate(2 * BLOCK_SIZE);

    for (broken, reason) in [
        (bad_checksum, "checksum mismatch"),
        (cut_short, "ends in the middle of an entry"),
        (cut_between_entries, "ends in the middle of an entry"),
    ] {
        let destination = temporary_folder()?;

        let copied = extract_archive(text(&destination), broken.as_slice());

        let message = failure(copied);
        assert!(message.contains(reason), "{message}");
        fs::remove_dir_all(destination)?;
    }
    Ok(())
}

#[test]
fn a_drop_places_every_top_item_under_its_own_name() -> TestResult {
    let destination = temporary_folder()?;
    let entries = [
        file(b"a.txt", "a"),
        folder("album/"),
        file(b"album/b.jpg", "b"),
        file(b"c.txt", "c"),
    ];

    let skipped = extract_items(
        Dir::open(&destination)?,
        "the drop",
        archive(&entries).as_slice(),
    )?;

    assert_eq!(skipped, 0);
    assert_eq!(fs::read_to_string(destination.join("a.txt"))?, "a");
    assert_eq!(fs::read_to_string(destination.join("album/b.jpg"))?, "b");
    assert_eq!(fs::read_to_string(destination.join("c.txt"))?, "c");

    fs::remove_dir_all(destination)?;
    Ok(())
}

#[test]
fn a_drop_refuses_a_top_item_that_comes_back() -> TestResult {
    let destination = temporary_folder()?;
    let entries = [
        file(b"album/a.jpg", "a"),
        file(b"b.txt", "b"),
        file(b"album/c.jpg", "c"),
    ];

    let refused = failure(extract_items(
        Dir::open(&destination)?,
        "the drop",
        archive(&entries).as_slice(),
    ));

    assert!(
        refused.contains("album comes twice in the drop"),
        "{refused}"
    );
    assert!(!destination.join("album/c.jpg").exists());

    fs::remove_dir_all(destination)?;
    Ok(())
}

#[test]
fn a_drop_leaves_out_links_and_special_files() -> TestResult {
    let destination = temporary_folder()?;
    let link = special(b"link.txt", EntryType::Symlink);
    let fifo = special(b"pipe", EntryType::Fifo);
    let entries = [file(b"a.txt", "a"), link, fifo];

    let skipped = extract_items(
        Dir::open(&destination)?,
        "the drop",
        archive(&entries).as_slice(),
    )?;

    assert_eq!(skipped, 2);
    assert!(fs::symlink_metadata(destination.join("link.txt")).is_err());
    assert!(fs::symlink_metadata(destination.join("pipe")).is_err());
    assert!(destination.join("a.txt").exists());

    fs::remove_dir_all(destination)?;
    Ok(())
}
