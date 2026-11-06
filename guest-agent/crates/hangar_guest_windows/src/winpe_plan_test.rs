use super::*;

#[test]
fn media_drive_takes_a_scanned_letter_with_a_colon() {
    assert_eq!(media_drive("D:"), Some('D'));
    assert_eq!(media_drive("e:"), Some('E'));

    assert_eq!(media_drive("X:"), None);
    assert_eq!(media_drive("D"), None);
    assert_eq!(media_drive(r"D:\"), None);
    assert_eq!(media_drive(""), None);
}

#[test]
fn install_image_is_looked_for_on_every_drive_but_windows_pes_own() {
    let candidates = install_image_candidates();

    assert_eq!(candidates[0], r"C:\sources\install.wim");
    assert_eq!(candidates[1], r"C:\sources\install.esd");
    assert_eq!(candidates.len(), 2 * SCAN_LETTERS.len());
    assert!(!candidates.iter().any(|path| path.starts_with("X:")));
}

#[test]
fn only_an_nvme_disk_is_the_vm_disk() {
    assert_eq!(disk_detail_script(3), "select disk 3\r\ndetail disk\r\n");

    let vm_disk =
        "Disk 0 is now the selected disk.\r\nNVMe Apple Virtual Disk\r\nType   : NVMe\r\n";
    let media = "Disk 1 is now the selected disk.\r\nApple USB Storage\r\nType   : USB\r\n";

    assert!(is_nvme_disk(vm_disk));
    assert!(!is_nvme_disk(media));
}

#[test]
fn partitioning_cleans_only_the_chosen_disk_and_assigns_s_and_w() {
    let script = partition_script(2);

    let lines: Vec<&str> = script.lines().collect();
    assert_eq!(lines[0], "select disk 2");
    assert_eq!(lines[1], "clean");
    assert!(lines.contains(&"assign letter=S"));
    assert!(lines.contains(&"assign letter=W"));
    assert!(script.ends_with("assign letter=W\r\n"));
}

#[test]
fn the_first_edition_with_remote_desktop_is_chosen() {
    let edition =
        choose_edition(|name| name == "Windows 11 Education" || name == "Windows 11 Pro N");

    assert_eq!(edition, Edition::Named("Windows 11 Education"));
    assert_eq!(edition.selector(), r#"/Name:"Windows 11 Education""#);
}

#[test]
fn an_image_without_those_editions_gets_its_first() {
    let edition = choose_edition(|_| false);

    assert_eq!(edition, Edition::First);
    assert_eq!(edition.selector(), "/Index:1");
}

#[test]
fn setup_files_come_from_the_media_and_go_to_the_new_windows() {
    let files = setup_files('E');

    let unattend = &files[0];
    assert_eq!(unattend.source, r"E:\hangar\unattend.xml");
    assert_eq!(unattend.destination, r"W:\Windows\Panther\unattend.xml");
    let virtiofs = &files[3];
    assert_eq!(virtiofs.source, r"E:\hangar\drivers\viofs\virtiofs.exe");
    assert_eq!(
        virtiofs.destination,
        r"W:\Program Files\Hangar\virtiofs.exe"
    );
    assert!(
        files
            .iter()
            .all(|file| file.destination.starts_with(r"W:\"))
    );
}

#[test]
fn log_times_are_the_time_of_day() {
    assert_eq!(time_of_day(0), "00:00:00");
    assert_eq!(time_of_day(86_400 + 3_600 * 13 + 60 * 5 + 9), "13:05:09");
}
