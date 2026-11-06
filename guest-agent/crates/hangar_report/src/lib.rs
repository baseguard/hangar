//! The memory report: one JSON line every few seconds on the host's report port. The host reads
//! it with `GuestReport.swift` in the hangar repo; a change to the fields goes in both.

#![forbid(unsafe_code)]

#[cfg(any(target_os = "linux", test))]
use std::io::Read;
use std::{io::Write, thread::sleep, time::Duration};

/// Well within `GuestReportReader.staleAfter` on the host, which treats an older report as gone.
const REPORT_INTERVAL: Duration = Duration::from_secs(2);
const OPEN_RETRY: Duration = Duration::from_secs(5);
const REOPEN_PAUSE: Duration = Duration::from_secs(1);

/// `MemTotal` and `MemAvailable` come first in `/proc/meminfo` on every kernel.
#[cfg(any(target_os = "linux", test))]
const MEMINFO_LIMIT: u64 = 16 * 1024;

/// The agent version the host compares against `GuestSetup.agentVersion`.
const VERSION: u32 = parse_version(option_env!("HANGAR_AGENT_VERSION"));

/// In bytes, with `used` never above `total`, which the host checks before it believes a report.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Memory {
    total: u64,
    used: u64,
}

impl Memory {
    /// `None` for a guest without memory; a count above the total (page accounting can overshoot
    /// for a moment) reads as all of it.
    pub fn new(total: u64, used: u64) -> Option<Memory> {
        if total == 0 {
            return None;
        }

        Some(Memory {
            total,
            used: used.min(total),
        })
    }

    /// Used memory is total minus available.
    pub fn from_total_and_available(total: u64, available: u64) -> Option<Memory> {
        Memory::new(total, total.saturating_sub(available))
    }
}

/// `open` and `memory` may fail for a while (the port exists only while the host listens);
/// both are simply tried again. `has_screen` is `None` where every guest has one.
pub fn send<P: Write>(
    open: impl Fn() -> Option<P>,
    memory: impl Fn() -> Option<Memory>,
    has_screen: impl Fn() -> Option<bool>,
) -> ! {
    loop {
        let Some(mut port) = open() else {
            sleep(OPEN_RETRY);
            continue;
        };

        report_until_broken(&mut port, &memory, &has_screen);
        sleep(REOPEN_PAUSE);
    }
}

fn report_until_broken(
    port: &mut impl Write,
    memory: impl Fn() -> Option<Memory>,
    has_screen: impl Fn() -> Option<bool>,
) {
    loop {
        if let Some(memory) = memory() {
            let report = line(memory, has_screen(), VERSION);
            if port.write_all(report.as_bytes()).is_err() {
                return;
            }
        }

        sleep(REPORT_INTERVAL);
    }
}

/// 0 for a build without `HANGAR_AGENT_VERSION`.
pub fn version() -> u32 {
    VERSION
}

fn line(memory: Memory, has_screen: Option<bool>, version: u32) -> String {
    let screen = has_screen
        .map(|has_screen| format!(",\"screen\":{has_screen}"))
        .unwrap_or_default();
    format!(
        "{{\"memory\":{{\"total\":{},\"used\":{}}}{screen},\"version\":{version}}}\n",
        memory.total, memory.used
    )
}

#[cfg(any(target_os = "linux", test))]
pub fn memory_from_meminfo(meminfo: impl Read) -> Option<Memory> {
    let mut text = String::new();
    meminfo.take(MEMINFO_LIMIT).read_to_string(&mut text).ok()?;

    let mut total_kilobytes = None;
    let mut available_kilobytes = None;

    for line in text.lines() {
        let mut fields = line.split_whitespace();
        let (Some(name), Some(value)) = (fields.next(), fields.next()) else {
            continue;
        };
        match name {
            "MemTotal:" => total_kilobytes = value.parse::<u64>().ok(),
            "MemAvailable:" => available_kilobytes = value.parse::<u64>().ok(),
            _ => {}
        }
    }

    let total = total_kilobytes?.checked_mul(1024)?;
    let available = available_kilobytes?.checked_mul(1024)?;

    Memory::from_total_and_available(total, available)
}

/// A `HANGAR_AGENT_VERSION` that isn't a number stops the build.
const fn parse_version(text: Option<&str>) -> u32 {
    let Some(text) = text else { return 0 };

    let digits = text.as_bytes();
    assert!(!digits.is_empty(), "HANGAR_AGENT_VERSION is empty");

    let mut version: u32 = 0;
    let mut index = 0;

    while index < digits.len() {
        let digit = digits[index];
        assert!(
            digit.is_ascii_digit(),
            "HANGAR_AGENT_VERSION must be a number"
        );
        version = version * 10 + (digit - b'0') as u32;
        index += 1;
    }

    version
}

#[cfg(test)]
#[path = "lib_test.rs"]
mod tests;
