//! The agent's one error type; its messages are the whole sentences a person sees.

#![forbid(unsafe_code)]

use std::{
    fmt,
    io::{self, Write},
    process::ExitStatus,
};

#[derive(Debug)]
pub enum Error {
    Usage(&'static str),
    NeedsRoot,
    /// `update` needs root, and `sudo` had no password or refused the one it got.
    NeedsPassword,
    /// The agent Hangar copied in for `update` no longer has the SHA-256 Hangar gave.
    CopiedAgentChanged,
    NoHome,
    File {
        action: &'static str,
        path: String,
        reason: String,
    },
    Step {
        step: &'static str,
        reason: String,
    },
    Program {
        name: String,
        exit: Exit,
    },
    Plain(&'static str),
}

/// How a program that didn't succeed ended.
#[derive(Debug, PartialEq, Eq)]
pub enum Exit {
    Code(i32),
    Signal,
    NotStarted(String),
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    pub fn file(action: &'static str, path: impl fmt::Display, reason: impl fmt::Display) -> Self {
        Self::File {
            action,
            path: path.to_string(),
            reason: reason.to_string(),
        }
    }

    pub fn step(step: &'static str, reason: impl fmt::Display) -> Self {
        Self::Step {
            step,
            reason: reason.to_string(),
        }
    }

    pub fn program(name: impl fmt::Display, exit: Exit) -> Self {
        Self::Program {
            name: name.to_string(),
            exit,
        }
    }
}

/// `Ok` when the program ran and succeeded.
pub fn check_exit(name: impl fmt::Display, status: io::Result<ExitStatus>) -> Result<()> {
    let exit = match status {
        Ok(status) if status.success() => return Ok(()),
        Ok(status) => status.code().map_or(Exit::Signal, Exit::Code),
        Err(error) => Exit::NotStarted(error.to_string()),
    };

    Err(Error::program(name, exit))
}

impl fmt::Display for Error {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Usage(usage) => write!(formatter, "{usage}"),
            Self::NeedsRoot => write!(formatter, "Run this with sudo."),
            Self::NeedsPassword => {
                write!(formatter, "A password is needed to update Hangar's agent.")
            }
            Self::CopiedAgentChanged => write!(
                formatter,
                "The copied agent changed before it could be installed."
            ),
            Self::NoHome => write!(formatter, "HOME isn't set."),
            Self::File {
                action,
                path,
                reason,
            } => write!(formatter, "Could not {action} {path}: {reason}"),
            Self::Step { step, reason } => write!(formatter, "Could not {step}: {reason}"),
            Self::Program { name, exit } => match exit {
                Exit::Code(code) => write!(formatter, "{name} failed (exit status {code})."),
                Exit::Signal => write!(formatter, "{name} was stopped by a signal."),
                Exit::NotStarted(reason) => write!(formatter, "Could not start {name}: {reason}"),
            },
            Self::Plain(sentence) => write!(formatter, "{sentence}"),
        }
    }
}

impl std::error::Error for Error {}

/// For failures the agent deliberately works around: `outcome` says what happens instead. The
/// line goes to stderr, which the guest keeps in the agent's log (journal, launchd, setup log).
pub fn note_failure<T, E: fmt::Display>(outcome: &str, result: std::result::Result<T, E>) {
    if let Err(error) = result {
        write_to_log(&format!("{error} ({outcome})"));
    }
}

fn write_to_log(line: &str) {
    // With stderr gone too there is nowhere left to write, and the agent goes on either way.
    let _unwritten = writeln!(io::stderr().lock(), "hangar-agent: {line}");
}

#[cfg(all(test, unix))]
#[path = "lib_test.rs"]
mod tests;
