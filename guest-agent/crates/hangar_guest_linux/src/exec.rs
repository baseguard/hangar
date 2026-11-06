//! `hangar-agent exec`: the system service that runs `hangar exec`'s commands, as the user at the
//! screen or else the VM's own account, switching users itself.

use hangar_exec::{Account, Launch, choose_account, user_command};
use hangar_exec_frames::StartRequest;
use hangar_sys_unix::{account_named, account_with_id};

use crate::{SEAT_FILE, seat};

const EXEC_PATH: &str = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
const SESSIONS_FOLDER: &str = "/run/systemd/sessions";

pub fn run() -> hangar_error::Result<()> {
    hangar_exec::serve(launch);
    Ok(())
}

fn launch(request: &StartRequest) -> Result<Launch, String> {
    let account = choose_account(
        user_at_the_screen(),
        request.fallback_user.as_deref(),
        account_named,
    )?;

    let command = user_command(
        request.program(),
        request.arguments(),
        &account,
        EXEC_PATH,
        request.tty,
    );
    Ok(Launch {
        command,
        account,
        switches_user: true,
    })
}

/// The seat's active user, if their session is a user's own: at the login screen the active
/// session is the display manager's greeter, which runs as a system user such as `Debian-gdm`.
fn user_at_the_screen() -> Option<Account> {
    let seat_record = std::fs::read_to_string(SEAT_FILE).ok()?;
    let session = seat::active_session(&seat_record)?;
    let session_record = std::fs::read_to_string(format!("{SESSIONS_FOLDER}/{session}")).ok()?;
    if !seat::is_user_session(&session_record) {
        return None;
    }
    account_with_id(seat::active_user(&seat_record)?)
}
