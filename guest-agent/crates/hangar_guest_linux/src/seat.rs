//! Which user is at the screen, from systemd-logind's record of the first seat; pure, so the tests
//! run on any host.

use std::io;

/// An unreadable record means nobody is known to be at the screen.
pub(crate) fn is_at_the_screen(record: io::Result<String>, uid: u32) -> bool {
    record.is_ok_and(|seat| is_active_user(&seat, uid))
}

/// A missing or unreadable `ACTIVE_UID` means nobody is known to be at the screen.
pub(crate) fn is_active_user(seat: &str, uid: u32) -> bool {
    active_user(seat) == Some(uid)
}

/// The seat's active session, by the name logind files it under; `None` for anything that isn't a
/// plain session name, so it can't lead outside the sessions folder.
pub(crate) fn active_session(seat: &str) -> Option<&str> {
    let session = seat
        .lines()
        .find_map(|line| line.strip_prefix("ACTIVE="))?
        .trim();
    let is_plain = !session.is_empty() && session.chars().all(|c| c.is_ascii_alphanumeric());
    is_plain.then_some(session)
}

/// A session a person signed in to; the greeter's class is `greeter`.
pub(crate) fn is_user_session(session: &str) -> bool {
    session.lines().any(|line| line.trim() == "CLASS=user")
}

/// The user at the screen; `None` when the record names nobody.
pub(crate) fn active_user(seat: &str) -> Option<u32> {
    seat.lines()
        .find_map(|line| line.strip_prefix("ACTIVE_UID="))
        .and_then(|value| value.trim().parse::<u32>().ok())
}

#[cfg(test)]
#[path = "seat_test.rs"]
mod tests;
