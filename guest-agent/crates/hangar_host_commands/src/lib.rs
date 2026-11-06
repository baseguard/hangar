//! The commands Hangar sends on the agent port, one per line; pure, so the tests run on any host.
//! The host writes them in `VMSession.swift` in the hangar repo.

#![forbid(unsafe_code)]

mod trust;

pub use trust::{HANGAR_CA_PREFIX, TrustState, is_hangar_ca_name};

use std::{
    io::{BufRead, BufReader, Read},
    thread::sleep,
    time::Duration,
};

/// Longer than any command, its newline included. `trust` is the longest: Hangar's CAs are well
/// under 2 KiB, so their hex fits with room for the variables.
const LONGEST_LINE: u64 = 16384;
/// The port shows up only once the guest's driver has it.
const OPEN_RETRY: Duration = Duration::from_secs(5);
/// The pause before a port that closed, or sent an over-long line, is opened again.
const REOPEN_PAUSE: Duration = Duration::from_secs(1);

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HostCommand {
    ShutDown,
    /// The whole trust state Hangar wants; the host sends it each time the agent starts.
    Trust(TrustState),
}

/// Follows the agent port for as long as the agent runs: a port that won't open is tried again,
/// and one that closes or sends an over-long line is opened again.
pub fn follow_host_port<P: Read>(open: impl Fn() -> Option<P>, obey: impl Fn(HostCommand)) {
    loop {
        let Some(port) = open() else {
            sleep(OPEN_RETRY);
            continue;
        };

        follow_host_commands(port, &obey);
        sleep(REOPEN_PAUSE);
    }
}

/// Calls `obey` for each command until the port closes, a read fails or a line runs past
/// [`LONGEST_LINE`]; lines that aren't commands are skipped.
fn follow_host_commands(port: impl Read, mut obey: impl FnMut(HostCommand)) {
    let mut reader = BufReader::new(port);

    while let Some(line) = next_line(&mut reader) {
        if let Some(command) = parse(&line) {
            obey(command);
        }
    }
}

/// `None` for a line without its newline, within the limit or at the end: half a command never
/// runs.
fn next_line(reader: &mut impl BufRead) -> Option<Vec<u8>> {
    let mut line = Vec::new();
    reader
        .take(LONGEST_LINE)
        .read_until(b'\n', &mut line)
        .ok()?;

    let text = line.strip_suffix(b"\n")?;
    Some(text.to_vec())
}

fn parse(line: &[u8]) -> Option<HostCommand> {
    let line = std::str::from_utf8(line).ok()?;
    if line == "shutdown" {
        return Some(HostCommand::ShutDown);
    }

    let arguments = line.strip_prefix("trust ")?;
    trust::parse_trust(arguments).map(HostCommand::Trust)
}

#[cfg(test)]
#[path = "lib_test.rs"]
mod tests;
