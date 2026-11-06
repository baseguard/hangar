//! The service keeps a session helper running for the user at the screen. The one Windows starts
//! from the Run value at sign-in can end early, as when a `hangar exec` command started it and
//! ended, and after an update it still runs the old program.

use std::{
    path::Path,
    thread::sleep,
    time::{Duration, Instant},
};

use hangar_error::Error;
use hangar_sys_windows::{SignedInUser, channel};

use super::{exec_relay::WaitingHelper, install::SESSION_HELPER_COMMAND, policy, service};

const CHECK_INTERVAL: Duration = Duration::from_secs(2);

pub(crate) fn keep_helper_running(waiting: &WaitingHelper, this_program: &Path) {
    let mut watch = HelperWatch {
        this_program,
        missing_since: None,
        last_start: None,
        has_noted_failure: false,
    };

    // After an update the user's helper still runs the old program; this one takes over from it.
    watch.start_helper_for_console_user();

    loop {
        sleep(CHECK_INTERVAL);
        watch.check(waiting);
    }
}

struct HelperWatch<'a> {
    this_program: &'a Path,
    /// Since when the user at the screen has had no helper waiting; `None` while one waits.
    missing_since: Option<Instant>,
    last_start: Option<Instant>,
    /// Set by the first logged failure, cleared once a helper waits again.
    has_noted_failure: bool,
}

impl HelperWatch<'_> {
    fn check(&mut self, waiting: &WaitingHelper) {
        let console = channel::console_session_id();
        let has_helper = waiting.has_helper_in(console);
        if has_helper {
            self.has_noted_failure = false;
        }
        let user = if has_helper {
            None
        } else {
            self.signed_in_user(console)
        };
        // Nobody at the screen, or a helper waiting: nothing is missing.
        let Some(user) = user else {
            self.missing_since = None;
            return;
        };

        let now = Instant::now();
        let missing_for = now - *self.missing_since.get_or_insert(now);
        let since_helper_arrived = waiting.since_helper_arrived_in(console);
        let since_last_start = self.last_start.map(|start| now - start);
        if policy::should_start_helper(missing_for, since_helper_arrived, since_last_start) {
            self.start_helper(&user);
        }
    }

    fn start_helper_for_console_user(&mut self) {
        if let Some(user) = self.signed_in_user(channel::console_session_id()) {
            self.start_helper(&user);
        }
    }

    fn signed_in_user(&mut self, session: u32) -> Option<SignedInUser> {
        match SignedInUser::of_session(session) {
            Ok(user) => user,
            Err(error) => {
                self.note_failure(&Error::step("find the user at the screen", error));
                None
            }
        }
    }

    fn start_helper(&mut self, user: &SignedInUser) {
        self.last_start = Some(Instant::now());

        let started = user.start(self.this_program, &[SESSION_HELPER_COMMAND]);
        if let Err(error) = started {
            self.note_failure(&Error::step("start the session helper", error));
        }
    }

    /// The checks repeat every few seconds, so only the first failure of each time the helper is
    /// missing goes to the log.
    fn note_failure(&mut self, failure: &Error) {
        if !self.has_noted_failure {
            service::note_in_log(failure);
            self.has_noted_failure = true;
        }
    }
}
