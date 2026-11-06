//! The Linux guest's commands; elsewhere only the pure `port_path` module builds, so its tests run
//! on any host.

#![cfg(any(target_os = "linux", test))]
#![forbid(unsafe_code)]

#[cfg(target_os = "linux")]
pub mod clipboard;
#[cfg(target_os = "linux")]
pub mod exec;
#[cfg(target_os = "linux")]
pub mod install;
mod port_path;
#[cfg(target_os = "linux")]
pub mod report;
mod screen;
mod seat;
#[cfg(target_os = "linux")]
mod trust;
mod trust_files;
#[cfg(target_os = "linux")]
pub mod update;

#[cfg(target_os = "linux")]
use hangar_error::{Error, Exit};
#[cfg(target_os = "linux")]
use hangar_sys_linux::gtk::{self, Event, Gtk, Library};

#[cfg(target_os = "linux")]
fn load_gtk() -> hangar_error::Result<Library> {
    gtk::load().ok_or_else(|| match gtk::missing_function() {
        Some(function) => Error::step(
            "start GTK 4",
            format!("this GTK has no {function}; it is too old for Hangar's agent"),
        ),
        None => Error::Plain("GTK 4 isn't installed."),
    })
}

#[cfg(target_os = "linux")]
fn run_desktop_helper(
    gtk: Library,
    id: &str,
    handler: impl FnMut(Gtk, Event) + 'static,
) -> hangar_error::Result<()> {
    let Some(status) = gtk.run_application(id, handler) else {
        return Err(Error::Plain("GTK couldn't start."));
    };

    if status != 0 {
        return Err(Error::program("GTK", Exit::Code(status)));
    }

    Ok(())
}

#[cfg(target_os = "linux")]
const SEAT_FILE: &str = "/run/systemd/seats/seat0";

/// Every signed-in user runs the clipboard helper on the same port; only the one at the screen may
/// use it. Read on every check, so switching users takes effect at once.
#[cfg(target_os = "linux")]
fn is_at_the_screen() -> bool {
    let record = std::fs::read_to_string(SEAT_FILE);
    seat::is_at_the_screen(record, hangar_sys_unix::effective_uid())
}

/// Merged-/usr systems keep their programs in /usr/bin, older ones in /bin, and tools only root
/// runs, like `update-ca-certificates`, in the sbin folders; the root service and the installer
/// never look them up through PATH.
#[cfg(target_os = "linux")]
fn system_program(name: &str) -> String {
    let candidates =
        ["/usr/bin", "/bin", "/usr/sbin", "/sbin"].map(|folder| format!("{folder}/{name}"));
    let found = candidates
        .iter()
        .find(|path| std::path::Path::new(path).exists());
    found.unwrap_or(&candidates[0]).clone()
}
