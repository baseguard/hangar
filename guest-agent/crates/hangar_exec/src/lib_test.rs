use std::{os::unix::net::UnixStream, thread::JoinHandle, time::Instant};

use super::*;

/// The host's end of a connection the agent serves on a thread of its own.
struct Connection(UnixStream);

/// Serves one connection the way the agent does, with `launch_with_sh`.
fn serve_pair() -> (Connection, JoinHandle<()>) {
    let (agent, host) = UnixStream::pair().unwrap();
    let writer = agent.try_clone().unwrap();
    let served = thread::spawn(move || serve_connection(agent, writer, launch_with_sh));
    (Connection(host), served)
}

impl Connection {
    fn start(script: &str, tty: bool, interactive: bool) -> Connection {
        let (mut connection, _served) = serve_pair();
        connection.send_start(&["/bin/sh", "-c", script], tty, interactive);
        connection
    }

    fn send_start(&mut self, command: &[&str], tty: bool, interactive: bool) {
        let mut payload = vec![
            u8::from(tty) | (u8::from(interactive) << 1),
            0,
            100,
            0,
            30,
            0,
            0,
        ];
        payload.extend_from_slice(&u16::try_from(command.len()).unwrap().to_be_bytes());
        for argument in command {
            payload.extend_from_slice(&u32::try_from(argument.len()).unwrap().to_be_bytes());
            payload.extend_from_slice(argument.as_bytes());
        }
        self.send(&Frame::new(Kind::Start, payload).unwrap());
    }

    fn send(&mut self, frame: &Frame) {
        self.0.write_all(&frame.encode()).unwrap();
    }

    fn next(&mut self) -> Frame {
        Frame::read_from(&mut self.0)
            .unwrap()
            .expect("the agent closed the connection")
    }

    /// The output until it holds `end`.
    fn output_until(&mut self, end: &str) -> String {
        let mut output = String::new();
        while !output.contains(end) {
            let frame = self.next();
            assert_eq!(frame.kind, Kind::Output);
            output.push_str(&String::from_utf8_lossy(&frame.payload));
        }
        output
    }

    /// The output until the exit, with the exit code.
    fn run_to_exit(&mut self) -> (Vec<u8>, Vec<u8>, i32) {
        let (mut output, mut errors) = (Vec::new(), Vec::new());
        loop {
            let frame = self.next();
            match frame.kind {
                Kind::Output => output.extend(frame.payload),
                Kind::ErrorOutput => errors.extend(frame.payload),
                Kind::Exit => {
                    let code = i32::from_be_bytes(frame.payload.try_into().unwrap());
                    return (output, errors, code);
                }
                Kind::Failed => panic!("{}", String::from_utf8_lossy(&frame.payload)),
                Kind::Start | Kind::Input | Kind::Resize => {
                    panic!("{:?} from the agent", frame.kind)
                }
            }
        }
    }
}

/// Runs commands as whoever runs the tests, with no user switch.
fn launch_with_sh(request: &StartRequest) -> Result<Launch, String> {
    if request
        .command
        .iter()
        .any(|argument| argument.contains("refuse"))
    {
        return Err("refused".into());
    }
    let mut command = Command::new(&request.command[0]);
    command.args(&request.command[1..]);
    let account = hangar_sys_unix::current_account().ok_or("no account")?;
    Ok(Launch {
        command,
        account,
        switches_user: false,
    })
}

fn request_for(command: &[&str]) -> StartRequest {
    StartRequest {
        command: command.iter().map(ToString::to_string).collect(),
        tty: false,
        interactive: false,
        columns: 80,
        rows: 24,
        fallback_user: None,
    }
}

#[test]
fn hangar_agent_runs_this_agents_own_program() {
    let agent = with_agent_program(request_for(&["hangar-agent", "cp-out", "/tmp/a"])).unwrap();
    let other = with_agent_program(request_for(&["/usr/bin/hangar-agent", "cp-out"])).unwrap();

    let this_program = std::env::current_exe().unwrap();
    assert_eq!(agent.command[0], this_program.to_str().unwrap());
    assert_eq!(agent.command[1..], ["cp-out", "/tmp/a"]);
    assert_eq!(other.command[0], "/usr/bin/hangar-agent");
}

#[test]
fn output_errors_and_the_exit_code_come_back() {
    let mut connection = Connection::start("echo out; echo err >&2; exit 3", false, false);

    let (output, errors, code) = connection.run_to_exit();

    assert_eq!(
        (output.as_slice(), errors.as_slice(), code),
        (&b"out\n"[..], &b"err\n"[..], 3)
    );
}

#[test]
fn a_background_process_that_keeps_writing_does_not_hold_the_exit_back() {
    let ticks = "i=0; while [ $i -lt 25 ]; do echo tick; sleep 0.2; i=$((i+1)); done";
    let started = Instant::now();
    let mut connection = Connection::start(&format!("({ticks}) & exit 0"), false, false);

    let (_, _, code) = connection.run_to_exit();

    assert_eq!(code, 0);
    assert!(
        started.elapsed() < Duration::from_secs(3),
        "{:?}",
        started.elapsed()
    );
}

#[test]
fn output_waiting_for_a_slow_host_comes_before_the_exit() {
    let mut connection = Connection::start("head -c 30000 /dev/zero", false, false);

    thread::sleep(Duration::from_secs(2));
    let (output, _, code) = connection.run_to_exit();

    assert_eq!((output.len(), code), (30000, 0));
}

#[test]
fn input_reaches_the_command_and_an_empty_input_ends_it() {
    let mut connection = Connection::start("cat", false, true);

    connection.send(&Frame::new(Kind::Input, b"hello".to_vec()).unwrap());
    connection.send(&Frame::new(Kind::Input, Vec::new()).unwrap());

    assert_eq!(connection.run_to_exit(), (b"hello".to_vec(), Vec::new(), 0));
}

#[test]
fn a_terminal_has_the_requested_size_and_follows_resizes() {
    let mut connection =
        Connection::start("test -t 0 && stty size; read line; stty size", true, true);

    let first = connection.output_until("\n");
    connection.send(&Frame::new(Kind::Resize, vec![0, 120, 0, 40]).unwrap());
    connection.send(&Frame::new(Kind::Input, b"go\n".to_vec()).unwrap());
    let (rest, _, code) = connection.run_to_exit();

    assert_eq!(first.trim(), "30 100");
    assert!(String::from_utf8_lossy(&rest).contains("40 120"));
    assert_eq!(code, 0);
}

#[test]
fn the_host_going_away_ends_the_command() {
    let (mut connection, served) = serve_pair();
    connection.send_start(&["/bin/sh", "-c", "echo $$; exec sleep 60"], false, false);
    let pid = connection.output_until("\n").trim().to_string();

    connection.0.shutdown(std::net::Shutdown::Both).unwrap();
    served.join().unwrap();

    let still_there = Command::new("/bin/kill")
        .args(["-0", &pid])
        .status()
        .unwrap()
        .success();
    assert!(!still_there, "sleep {pid} still runs");
}

#[test]
fn a_refused_or_missing_command_says_why() {
    let mut refused = Connection::start("refuse", false, false);
    assert_eq!(refused.next(), Frame::failed("refused"));

    let (mut missing, _served) = serve_pair();
    missing.send_start(&["/no/such/prog"], false, false);
    let failed = missing.next();
    assert_eq!(failed.kind, Kind::Failed);
    assert!(String::from_utf8_lossy(&failed.payload).starts_with("Could not start /no/such/prog"));
}

#[test]
fn a_connection_that_starts_with_anything_else_is_refused() {
    let (mut connection, _served) = serve_pair();

    connection.send(&Frame::new(Kind::Input, b"x".to_vec()).unwrap());

    assert_eq!(connection.next().kind, Kind::Failed);
}
