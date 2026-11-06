use super::*;

const AGENT: &str = r"C:\Program Files\Hangar\hangar-agent.exe";

struct FakePipe {
    client: Option<(u32, u32)>,
    client_program: Option<&'static str>,
    console: u32,
    server_session: Option<u32>,
    server_owner: Option<Account>,
}

impl Default for FakePipe {
    fn default() -> Self {
        FakePipe {
            client: Some((7, 1)),
            client_program: Some(r"c:\program files\hangar\HANGAR-AGENT.EXE"),
            console: 1,
            server_session: Some(0),
            server_owner: Some(Account::System),
        }
    }
}

impl PipeFacts for FakePipe {
    fn client_process_id(&self) -> Option<u32> {
        self.client.map(|(process, _)| process)
    }

    fn client_session_id(&self) -> Option<u32> {
        self.client.map(|(_, session)| session)
    }

    fn console_session_id(&self) -> u32 {
        self.console
    }

    fn program_of(&self, process: u32) -> Option<PathBuf> {
        let program = self
            .client_program
            .filter(|_| Some(process) == self.client_process_id())?;
        Some(PathBuf::from(program))
    }

    fn server_session_id(&self) -> Option<u32> {
        self.server_session
    }

    fn server_owned_by(&self, account: Account) -> io::Result<bool> {
        let owner = self
            .server_owner
            .ok_or_else(|| io::Error::other("no owner"))?;
        Ok(owner == account)
    }
}

struct FakeItem {
    kind: ItemKind,
    owner: Option<Account>,
}

impl ItemFacts for FakeItem {
    fn kind(&self) -> io::Result<ItemKind> {
        Ok(self.kind)
    }

    fn owned_by(&self, account: Account) -> io::Result<bool> {
        Ok(self.owner == Some(account))
    }
}

#[test]
fn only_the_agent_in_the_console_session_gets_the_clipboard() {
    let this_program = Path::new(AGENT);
    let other_session = FakePipe {
        client: Some((7, 2)),
        ..FakePipe::default()
    };
    let other_program = FakePipe {
        client_program: Some(r"C:\Users\x\hangar-agent.exe"),
        ..FakePipe::default()
    };
    let unknown_client = FakePipe {
        client: None,
        ..FakePipe::default()
    };
    let unknown_program = FakePipe {
        client_program: None,
        ..FakePipe::default()
    };

    assert!(client_is_console_helper(&FakePipe::default(), this_program));
    assert!(!client_is_console_helper(&other_session, this_program));
    assert!(!client_is_console_helper(&other_program, this_program));
    assert!(!client_is_console_helper(&unknown_client, this_program));
    assert!(!client_is_console_helper(&unknown_program, this_program));
}

#[test]
fn only_a_pipe_system_serves_from_session_zero_is_trusted() {
    let user_session = FakePipe {
        server_session: Some(1),
        ..FakePipe::default()
    };
    let administrators = FakePipe {
        server_owner: Some(Account::Administrators),
        ..FakePipe::default()
    };
    let unknown_owner = FakePipe {
        server_owner: None,
        ..FakePipe::default()
    };
    let unknown_session = FakePipe {
        server_session: None,
        ..FakePipe::default()
    };

    assert!(served_by_system(&FakePipe::default()));
    assert!(!served_by_system(&user_session));
    assert!(!served_by_system(&administrators));
    assert!(!served_by_system(&unknown_owner));
    assert!(!served_by_system(&unknown_session));
}

#[test]
fn the_agent_folder_must_be_a_real_folder_owned_by_system_or_administrators() {
    let path = Path::new(r"C:\Program Files\Hangar");
    let folder = |kind, owner| FakeItem { kind, owner };

    let by_system = check_agent_folder(path, &folder(ItemKind::Folder, Some(Account::System)));
    let by_administrators = check_agent_folder(
        path,
        &folder(ItemKind::Folder, Some(Account::Administrators)),
    );
    let by_someone = check_agent_folder(path, &folder(ItemKind::Folder, None));
    let link = check_agent_folder(path, &folder(ItemKind::Link, Some(Account::System)));
    let file = check_agent_folder(path, &folder(ItemKind::Other, Some(Account::System)));

    assert!(by_system.is_ok());
    assert!(by_administrators.is_ok());
    assert!(by_someone.is_err());
    assert!(link.is_err());
    assert!(file.is_err());
}

#[test]
fn a_missing_helper_is_started_after_the_grace_time() {
    let soon = HELPER_GRACE.saturating_sub(Duration::from_secs(1));

    assert!(!should_start_helper(soon, None, None));
    assert!(should_start_helper(HELPER_GRACE, None, None));
}

#[test]
fn a_helper_busy_with_a_command_is_not_missing() {
    let took_a_command = Some(Duration::from_secs(3));
    let ended_long_ago = Some(HELPER_GRACE);

    assert!(!should_start_helper(HELPER_GRACE, took_a_command, None));
    assert!(should_start_helper(HELPER_GRACE, ended_long_ago, None));
}

#[test]
fn a_started_helper_gets_time_to_take_over_before_another_starts() {
    let early = HELPER_START_PAUSE.saturating_sub(Duration::from_secs(1));

    assert!(!should_start_helper(HELPER_GRACE, None, Some(early)));
    assert!(should_start_helper(
        HELPER_GRACE,
        None,
        Some(HELPER_START_PAUSE)
    ));
}
