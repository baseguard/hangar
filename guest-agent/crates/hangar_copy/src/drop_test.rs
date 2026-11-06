use std::error::Error;

use super::*;
use crate::tests::{archive, file, folder, temporary_folder};

type TestResult = std::result::Result<(), Box<dyn Error>>;

#[test]
fn take_makes_the_folder_and_numbers_names_that_are_taken() -> TestResult {
    let home = temporary_folder()?;
    let drop_folder = home.join(DROP_FOLDER);
    fs::create_dir_all(drop_folder.join("album"))?;
    fs::write(drop_folder.join("report.pdf"), "old")?;
    let entries = [
        file(b"report.pdf", "new"),
        folder("album/"),
        file(b"album/a.jpg", "a"),
        file(b"notes.txt", "notes"),
    ];

    let skipped = take_into(&drop_folder, archive(&entries).as_slice())?;

    assert_eq!(skipped, 0);
    assert_eq!(fs::read_to_string(drop_folder.join("report.pdf"))?, "old");
    assert_eq!(fs::read_to_string(drop_folder.join("report 2.pdf"))?, "new");
    assert_eq!(fs::read_to_string(drop_folder.join("album 2/a.jpg"))?, "a");
    assert!(!drop_folder.join("album/a.jpg").exists());
    assert_eq!(fs::read_to_string(drop_folder.join("notes.txt"))?, "notes");

    fs::remove_dir_all(home)?;
    Ok(())
}

#[test]
fn take_into_a_missing_folder_makes_it() -> TestResult {
    let home = temporary_folder()?;
    let drop_folder = home.join(DROP_FOLDER);

    take_into(&drop_folder, archive(&[file(b"a.txt", "a")]).as_slice())?;

    assert_eq!(fs::read_to_string(drop_folder.join("a.txt"))?, "a");

    fs::remove_dir_all(home)?;
    Ok(())
}

#[test]
fn an_entry_that_climbs_out_of_the_folder_is_refused() -> TestResult {
    let home = temporary_folder()?;
    let drop_folder = home.join(DROP_FOLDER);

    let taken = take_into(
        &drop_folder,
        archive(&[file(b"../escaped.txt", "x")]).as_slice(),
    );

    assert!(taken.is_err());
    assert!(!home.join("escaped.txt").exists());

    fs::remove_dir_all(home)?;
    Ok(())
}
