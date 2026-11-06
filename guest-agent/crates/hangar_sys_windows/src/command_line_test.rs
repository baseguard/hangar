use super::*;

fn line(arguments: &[&str]) -> String {
    command_line_of(
        &arguments
            .iter()
            .map(|&argument| argument.to_owned())
            .collect::<Vec<_>>(),
    )
}

#[test]
fn plain_arguments_stay_as_they_are() {
    assert_eq!(line(&["cmd", "/c", "dir"]), "cmd /c dir");
}

#[test]
fn spaces_quotes_and_empty_arguments_are_quoted() {
    assert_eq!(line(&["echo", "a b", ""]), r#"echo "a b" """#);
    assert_eq!(line(&["echo", r#"say "hi""#]), r#"echo "say \"hi\"""#);
}

#[test]
fn backslashes_double_only_before_a_quote() {
    assert_eq!(line(&[r"C:\Program Files\"]), r#""C:\Program Files\\""#);
    assert_eq!(line(&[r"a\b c"]), r#""a\b c""#);
    assert_eq!(line(&[r#"a\"b"#]), r#""a\\\"b""#);
}

const AGENT: &str = r"C:\Program Files\Hangar\hangar-agent.exe";

#[test]
fn the_install_parameters_pass() -> io::Result<()> {
    let command = elevated_command(Path::new(AGENT), "install --elevated")?;

    assert_eq!(
        command,
        r#"/d /c ""C:\Program Files\Hangar\hangar-agent.exe" install --elevated""#
    );
    Ok(())
}

#[test]
fn parameters_that_cmd_would_act_on_are_refused() {
    let refused = [
        "install %PATH%",
        "install \"x\"",
        "install & calc",
        "install ^",
        "install | more",
        "install < input",
        "install > output",
        "install\n--elevated",
        "",
        " install",
        "install ",
        "install  --elevated",
    ];

    for parameters in refused {
        assert!(
            elevated_command(Path::new(AGENT), parameters).is_err(),
            "{parameters:?}"
        );
    }
}

#[test]
fn a_service_command_quotes_the_program_and_keeps_plain_arguments() -> io::Result<()> {
    let agent = program_command_line(Path::new(AGENT), &["service"])?;
    let shares = program_command_line(Path::new(r"C:\Program Files\Hangar\virtiofs.exe"), &[])?;

    assert_eq!(
        agent,
        r#""C:\Program Files\Hangar\hangar-agent.exe" service"#
    );
    assert_eq!(shares, r#""C:\Program Files\Hangar\virtiofs.exe""#);
    Ok(())
}

#[test]
fn a_service_command_with_a_quote_or_a_spaced_argument_is_refused() {
    let quoted_program = program_command_line(Path::new(r#"C:\a"b\hangar-agent.exe"#), &[]);
    let quoted_argument = program_command_line(Path::new(AGENT), &["a\"b"]);
    let spaced_argument = program_command_line(Path::new(AGENT), &["two words"]);
    let empty_argument = program_command_line(Path::new(AGENT), &[""]);

    assert!(quoted_program.is_err());
    assert!(quoted_argument.is_err());
    assert!(spaced_argument.is_err());
    assert!(empty_argument.is_err());
}

#[test]
fn a_program_path_with_percent_or_quote_is_refused() {
    let percent = elevated_command(Path::new(r"C:\100%\hangar-agent.exe"), "install");
    let quote = elevated_command(Path::new(r#"C:\a"b\hangar-agent.exe"#), "install");

    assert!(percent.is_err());
    assert!(quote.is_err());
}
