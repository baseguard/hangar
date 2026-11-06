//! `agent`: the per-user part, the clipboard. The memory report and the host's commands are the
//! system part's (`report`).

use hangar_error::Error;
use hangar_sys_macos as macos;

const LOG_FOLDER: &str = "Library/Logs/Hangar";
const LOG_FILE: &str = "agent.log";

pub fn run() -> hangar_error::Result<()> {
    if let Ok(home) = std::env::var("HOME") {
        super::send_failures_to_log_file(&format!("{home}/{LOG_FOLDER}"), LOG_FILE);
    }

    if !macos::run_app(super::clipboard::start) {
        return Err(Error::Plain("The agent has to run on the main thread."));
    }

    Ok(())
}
