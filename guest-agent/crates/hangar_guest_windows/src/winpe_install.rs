//! `winpe-install <media drive>` installs Windows from the media Hangar built, in Windows PE.
//!
//! It finds the install image and the VM disk, partitions the disk, applies Windows with the virtio
//! drivers and the agent, and leaves OK or FAILED in the status file Hangar reads. Windows PE shuts
//! down after it, from the answer file that started it.

use std::{
    ffi::OsStr,
    fs::{self, File, OpenOptions},
    io::{self, Write},
    os::windows::process::CommandExt,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{SystemTime, UNIX_EPOCH},
};

use windows_sys::Win32::System::Threading::CREATE_NO_WINDOW;

use super::winpe_plan::{
    self as plan, DISK_NUMBERS, Edition, SYSTEM_DRIVE, SetupFile, WINDOWS_DRIVE,
};
use hangar_error::{Error, Result};
use hangar_sys_windows as sys;

const USAGE: &str = "usage: hangar-agent winpe-install <media drive>";

pub fn run(arguments: &[String]) -> Result<()> {
    let media = match arguments {
        [_command, drive] => plan::media_drive(drive).ok_or(Error::Usage(USAGE))?,
        _ => return Err(Error::Usage(USAGE)),
    };

    let hangar = PathBuf::from(format!(r"{media}:\hangar"));
    let mut log = Log::create(&hangar.join("install.log"))?;
    log.line(&format!("Windows PE started the install from {media}:"));

    let result = install_windows(media, &mut log);
    report(&hangar, &mut log, result.as_ref().err());
    result
}

fn install_windows(media: char, log: &mut Log) -> Result<()> {
    let image = find_install_image()?;
    log.line(&format!("Image: {image}"));
    let disk = find_vm_disk()?;
    log.line(&format!("System disk: {disk}"));

    partition_disk(disk, log)?;
    apply_windows(&image, log)?;
    add_drivers(media, log)?;
    copy_setup_files(media, log)?;
    install_boot_loader(media, log)?;
    Ok(())
}

/// The status file is what Hangar reads; the log is kept in the new Windows too when it got that far.
fn report(hangar: &Path, log: &mut Log, failure: Option<&Error>) {
    let status = match failure {
        None => {
            log.line("Done");
            "OK"
        }
        Some(error) => {
            log.line(&format!("Failed: {error}"));
            "FAILED"
        }
    };

    if failure.is_none() {
        let kept = fs::copy(
            hangar.join("install.log"),
            format!(r"{WINDOWS_DRIVE}\Windows\Panther\hangar-install.log"),
        );
        hangar_error::note_failure("the install log stays on the media only", kept);
    }
    let written = fs::write(hangar.join("status"), format!("{status}\r\n"));
    hangar_error::note_failure("Hangar finds no status", written);
}

fn find_install_image() -> Result<String> {
    plan::install_image_candidates()
        .into_iter()
        .find(|path| Path::new(path).is_file())
        .ok_or(Error::Plain(
            r"No sources\install.wim or install.esd was found.",
        ))
}

fn find_vm_disk() -> Result<u32> {
    for disk in DISK_NUMBERS {
        let detail = diskpart_output(&plan::disk_detail_script(disk))?;
        if plan::is_nvme_disk(&detail) {
            return Ok(disk);
        }
    }
    Err(Error::Plain("No NVMe disk was found."))
}

fn partition_disk(disk: u32, log: &mut Log) -> Result<()> {
    let script = write_diskpart_script("hangar-partition.txt", &plan::partition_script(disk))?;
    log.run(
        "Partitioning the disk",
        "diskpart.exe",
        &[OsStr::new("/s"), script.as_os_str()],
    )
}

fn apply_windows(image: &str, log: &mut Log) -> Result<()> {
    let edition = plan::choose_edition(|name| image_has_edition(image, name));
    if edition == Edition::First {
        log.line(
            "Warning: no Pro, Enterprise or Education edition; Remote Desktop may be missing.",
        );
    }

    log.line(&format!("Applying {}", edition.selector()));
    let mut dism = system_tool("dism.exe")?;
    dism.arg("/Apply-Image")
        .raw_arg(format!("/ImageFile:\"{image}\""))
        .raw_arg(edition.selector())
        .arg(format!(r"/ApplyDir:{WINDOWS_DRIVE}\"));
    log.run_command("Applying Windows", dism)
}

fn image_has_edition(image: &str, edition: &'static str) -> bool {
    let Ok(mut dism) = system_tool("dism.exe") else {
        return false;
    };
    dism.arg("/Get-ImageInfo")
        .raw_arg(format!("/ImageFile:\"{image}\""))
        .raw_arg(Edition::Named(edition).selector())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    dism.status().is_ok_and(|status| status.success())
}

fn add_drivers(media: char, log: &mut Log) -> Result<()> {
    log.line("Adding drivers");
    let mut dism = system_tool("dism.exe")?;
    dism.arg(format!(r"/Image:{WINDOWS_DRIVE}\"))
        .arg("/Add-Driver")
        .arg(format!(r"/Driver:{media}:\hangar\drivers"))
        .arg("/Recurse");
    log.run_command("Adding the drivers", dism)
}

/// The media keeps no copy of the answer file, which holds the account's password.
fn copy_setup_files(media: char, log: &mut Log) -> Result<()> {
    for folder in [r"Windows\Panther", r"Program Files\Hangar"] {
        let path = format!(r"{WINDOWS_DRIVE}\{folder}");
        fs::create_dir_all(&path).map_err(|error| Error::file("make", &path, error))?;
    }

    for SetupFile {
        source,
        destination,
    } in plan::setup_files(media)
    {
        fs::copy(&source, &destination).map_err(|error| Error::file("copy", &source, error))?;
        log.line(&format!("Copied {source}"));
    }

    let answer_file = format!(r"{media}:\hangar\unattend.xml");
    fs::remove_file(&answer_file).map_err(|error| Error::file("remove", &answer_file, error))
}

/// Windows' own boot files, plus Hangar's framebuffer driver, which the firmware loads on every boot.
fn install_boot_loader(media: char, log: &mut Log) -> Result<()> {
    let windows = format!(r"{WINDOWS_DRIVE}\Windows");
    log.run(
        "Installing the boot files",
        "bcdboot.exe",
        &[
            OsStr::new(&windows),
            OsStr::new("/s"),
            OsStr::new(SYSTEM_DRIVE),
            OsStr::new("/f"),
            OsStr::new("UEFI"),
        ],
    )?;

    let folder = format!(r"{SYSTEM_DRIVE}\EFI\Hangar");
    fs::create_dir_all(&folder).map_err(|error| Error::file("make", &folder, error))?;
    let driver = format!(r"{media}:\EFI\Hangar\hangarfb.efi");
    fs::copy(&driver, format!(r"{folder}\hangarfb.efi"))
        .map(drop)
        .map_err(|error| Error::file("copy", &driver, error))
}

fn diskpart_output(script: &str) -> Result<String> {
    let script = write_diskpart_script("hangar-disk.txt", script)?;
    let mut diskpart = system_tool("diskpart.exe")?;
    let output = diskpart
        .arg("/s")
        .arg(&script)
        .stdin(Stdio::null())
        .output()
        .map_err(|error| Error::step("run diskpart", error))?;
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// Windows PE's temporary folder is on its own RAM drive, which nothing else writes to.
fn write_diskpart_script(name: &str, script: &str) -> Result<PathBuf> {
    let path = std::env::temp_dir().join(name);
    fs::write(&path, script).map_err(|error| Error::file("write", path.display(), error))?;
    Ok(path)
}

/// The full System32 path keeps a same-named program elsewhere on the search path from running.
fn system_tool(name: &str) -> Result<Command> {
    let system32 = sys::system32().map_err(|error| Error::step("find System32", error))?;
    let mut command = Command::new(system32.join(name));
    command
        .creation_flags(CREATE_NO_WINDOW)
        .stdin(Stdio::null());
    Ok(command)
}

/// Time-stamped lines, with the tools' own output between them.
struct Log {
    file: File,
}

impl Log {
    fn create(path: &Path) -> Result<Log> {
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .map_err(|error| Error::file("open", path.display(), error))?;
        Ok(Log { file })
    }

    fn line(&mut self, text: &str) {
        let seconds = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |since| since.as_secs());
        let written = writeln!(self.file, "[{}] {text}\r", plan::time_of_day(seconds));
        hangar_error::note_failure("a line is missing from the install log", written);
    }

    fn run(&mut self, step: &str, tool: &str, arguments: &[&OsStr]) -> Result<()> {
        let mut command = system_tool(tool)?;
        command.args(arguments);
        self.run_command(step, command)
    }

    /// The tool writes straight into the log; a failure names the step.
    fn run_command(&mut self, step: &str, mut command: Command) -> Result<()> {
        let status = self
            .output_handles()
            .and_then(|(output, errors)| command.stdout(output).stderr(errors).status());
        hangar_error::check_exit(step, status)
    }

    fn output_handles(&self) -> io::Result<(File, File)> {
        Ok((self.file.try_clone()?, self.file.try_clone()?))
    }
}
