use super::*;

fn commands_in(port: &[u8]) -> Vec<HostCommand> {
    let mut commands = Vec::new();
    follow_host_commands(port, |command| commands.push(command));
    commands
}

#[test]
fn shutdown_is_obeyed_and_other_lines_are_skipped() {
    let commands = commands_in(b"hello\nshutdown\n");

    assert_eq!(commands, vec![HostCommand::ShutDown]);
}

#[test]
fn a_trust_line_is_obeyed_and_a_bad_one_is_skipped() {
    let commands = commands_in(b"trust - TOKEN=a\ntrust - token=a\ntrust\n");

    let expected = TrustState {
        ca_der: None,
        variables: vec![("TOKEN".to_string(), "a".to_string())],
    };
    assert_eq!(commands, vec![HostCommand::Trust(expected)]);
}

#[test]
fn a_line_past_the_limit_ends_the_reading() {
    let mut port = vec![b'x'; 16_400];
    port.extend(b"\nshutdown\n");

    let commands = commands_in(&port);

    assert_eq!(commands, Vec::new());
}

#[test]
fn a_command_cut_off_by_the_end_of_the_port_never_runs() {
    let commands = commands_in(b"shutdown");

    assert_eq!(commands, Vec::new());
}

#[test]
fn a_line_just_inside_the_limit_is_read() {
    let mut port = vec![b'x'; 16_383];
    port.extend(b"\nshutdown\n");

    let commands = commands_in(&port);

    assert_eq!(commands, vec![HostCommand::ShutDown]);
}
