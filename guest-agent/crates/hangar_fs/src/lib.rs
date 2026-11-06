//! A folder handle that only ever touches its direct children and never follows a link.

#[cfg(unix)]
mod unix;
#[cfg(windows)]
mod windows;

#[cfg(unix)]
pub use unix::{Dir, Entry, Kind, Listing, Owner};
#[cfg(windows)]
pub use windows::{Dir, Entry, Kind, Listing, verbatim};

/// Where a guest keeps the agent's failures in a file of its own, `Dir::open_log` moves the file
/// aside at this size when the agent starts, like the host's own logs.
pub const LOG_LIMIT: u64 = 1024 * 1024;
