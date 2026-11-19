use super::*;

#[test]
fn only_a_gigabyte_or_more_of_new_space_is_worth_a_resize() {
    assert!(!has_room(80 << 30, 80 << 30));
    assert!(!has_room(80 << 30, (80 << 30) + (512 << 20)));
    assert!(has_room(80 << 30, 96 << 30));
    assert!(!has_room(96 << 30, 80 << 30));
}

/// The name goes to diskutil as an argument, so nothing else passes.
#[test]
fn only_a_whole_disk_name_is_taken_from_diskutil() {
    assert!(is_disk_name("disk3"));
    assert!(is_disk_name("disk12"));
    assert!(!is_disk_name("disk"));
    assert!(!is_disk_name("disk3s1"));
    assert!(!is_disk_name("-disk3"));
    assert!(!is_disk_name("disk3 0"));
}

#[test]
fn a_plist_field_is_read_with_plutil() -> Result<()> {
    let plist = br#"<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CurrentSize</key><integer>85899345920</integer>
<key>Type</key><string>APFSContainerReference</string>
</dict></plist>"#;

    assert_eq!(plist_number(plist, "CurrentSize")?, 85_899_345_920);
    assert!(plist_number(plist, "Type").is_err());
    assert!(plist_text(plist, "Missing").is_err());
    Ok(())
}
