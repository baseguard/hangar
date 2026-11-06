//! What `winpe-install` decides before it touches the disk: where the install image and the VM disk
//! are, how the disk is laid out, which edition is applied and which files go where. Kept apart
//! from the steps that run the tools, so the tests run on any host.

/// Windows PE's own RAM drive is X:; A: and B: are never a disk.
const SCAN_LETTERS: &str = "CDEFGHIJKLMNOPQRSTUVWYZ";
/// The VM disk is on the first ten disks; the install media is one of them too.
#[cfg_attr(
    not(windows),
    expect(dead_code, reason = "only Windows PE looks at the disks")
)]
pub(crate) const DISK_NUMBERS: std::ops::Range<u32> = 0..10;
/// Remote Desktop needs one of these; Home lacks it.
const EDITIONS: [&str; 5] = [
    "Windows 11 Pro",
    "Windows 11 Enterprise",
    "Windows 11 Education",
    "Windows 11 Pro N",
    "Windows 11 Pro for Workstations",
];

/// Where the partitioning puts the EFI system partition and Windows.
pub(crate) const SYSTEM_DRIVE: &str = "S:";
pub(crate) const WINDOWS_DRIVE: &str = "W:";

/// `D:` or `d:`, the drive the media was found on; the letter comes back in upper case.
pub(crate) fn media_drive(argument: &str) -> Option<char> {
    let mut characters = argument.chars();
    let letter = characters.next()?.to_ascii_uppercase();
    let is_drive = SCAN_LETTERS.contains(letter) && characters.as_str() == ":";
    is_drive.then_some(letter)
}

/// Every place the install image may be, in the order they are tried: Windows PE gives the media's
/// image partition whichever letter is free.
pub(crate) fn install_image_candidates() -> Vec<String> {
    let mut candidates = Vec::new();
    for letter in SCAN_LETTERS.chars() {
        candidates.push(format!(r"{letter}:\sources\install.wim"));
        candidates.push(format!(r"{letter}:\sources\install.esd"));
    }
    candidates
}

pub(crate) fn disk_detail_script(disk: u32) -> String {
    format!("select disk {disk}\r\ndetail disk\r\n")
}

/// The VM disk is the only `NVMe` disk; the install media is on USB.
pub(crate) fn is_nvme_disk(diskpart_detail: &str) -> bool {
    diskpart_detail.contains("NVMe")
}

/// GPT with the EFI system partition as S: and Windows as W:, which the later steps write to.
pub(crate) fn partition_script(disk: u32) -> String {
    let lines = [
        format!("select disk {disk}"),
        "clean".into(),
        "convert gpt".into(),
        "create partition efi size=260".into(),
        "format quick fs=fat32 label=System".into(),
        format!("assign letter={}", &SYSTEM_DRIVE[..1]),
        "create partition msr size=16".into(),
        "create partition primary".into(),
        "format quick fs=ntfs label=Windows".into(),
        format!("assign letter={}", &WINDOWS_DRIVE[..1]),
    ];
    lines.map(|line| line + "\r\n").concat()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Edition {
    Named(&'static str),
    /// The image's first edition, which may lack Remote Desktop.
    First,
}

impl Edition {
    /// dism's selector, in the form `/Name:"Windows 11 Pro"` or `/Index:1`.
    pub(crate) fn selector(self) -> String {
        match self {
            Edition::Named(name) => format!("/Name:\"{name}\""),
            Edition::First => "/Index:1".into(),
        }
    }
}

/// The first edition with Remote Desktop that the image holds; `image_has` asks dism.
pub(crate) fn choose_edition(image_has: impl Fn(&'static str) -> bool) -> Edition {
    for name in EDITIONS {
        if image_has(name) {
            return Edition::Named(name);
        }
    }
    Edition::First
}

/// A file from the media's `hangar` folder and where it goes on the new Windows.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct SetupFile {
    pub(crate) source: String,
    pub(crate) destination: String,
}

/// The answer file, the agent, and the shared folders' installer and driver service. Windows' own
/// Setup reads the answer file; the agent's `setup` runs from it and uses the other two.
pub(crate) fn setup_files(media: char) -> Vec<SetupFile> {
    let hangar = format!(r"{media}:\hangar");
    let program_folder = format!(r"{WINDOWS_DRIVE}\Program Files\Hangar");
    let file = |source: &str, destination: String| SetupFile {
        source: format!(r"{hangar}\{source}"),
        destination,
    };

    vec![
        file(
            "unattend.xml",
            format!(r"{WINDOWS_DRIVE}\Windows\Panther\unattend.xml"),
        ),
        file(
            "hangar-agent.exe",
            format!(r"{program_folder}\hangar-agent.exe"),
        ),
        file("winfsp.msi", format!(r"{program_folder}\winfsp.msi")),
        file(
            r"drivers\viofs\virtiofs.exe",
            format!(r"{program_folder}\virtiofs.exe"),
        ),
    ]
}

/// Seconds since midnight, as `hh:mm:ss` in UTC, for the install log's lines.
pub(crate) fn time_of_day(seconds_since_epoch: u64) -> String {
    let seconds = seconds_since_epoch % 86_400;
    format!(
        "{:02}:{:02}:{:02}",
        seconds / 3600,
        seconds / 60 % 60,
        seconds % 60
    )
}

#[cfg(test)]
#[path = "winpe_plan_test.rs"]
mod tests;
