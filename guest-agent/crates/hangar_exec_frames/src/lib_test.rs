use super::*;

/// The same bytes are in `ExecFrameTests.swift`: the host writes this start, and reads this exit.
const START_GOLDEN: &str = "010000001d0300500018000561646d696e000200000005756e616d65000000022d61";
const EXIT_GOLDEN: &str = "1400000004fffffffd";

fn bytes(hex: &str) -> Vec<u8> {
    (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap())
        .collect()
}

fn frames_in(bytes: &[u8]) -> io::Result<Vec<Frame>> {
    let mut connection = bytes;
    let mut frames = Vec::new();
    while let Some(frame) = Frame::read_from(&mut connection)? {
        frames.push(frame);
    }
    Ok(frames)
}

#[test]
fn the_hosts_start_frame_reads_as_its_request() {
    let frames = frames_in(&bytes(START_GOLDEN)).unwrap();

    assert_eq!(frames.len(), 1);
    assert_eq!(frames[0].kind, Kind::Start);
    let request = StartRequest::parse(&frames[0].payload).unwrap();
    assert_eq!(request.command, ["uname", "-a"]);
    assert!(request.tty && request.interactive);
    assert_eq!((request.columns, request.rows), (80, 24));
    assert_eq!(request.fallback_user.as_deref(), Some("admin"));
}

#[test]
fn an_exit_frame_is_written_the_way_the_host_reads_it() {
    assert_eq!(Frame::exit(-3).encode(), bytes(EXIT_GOLDEN));
}

#[test]
fn frames_follow_each_other_on_the_connection() {
    let output = Frame::new(Kind::Output, b"hello".to_vec()).unwrap();
    let mut stream = output.encode();
    stream.extend(Frame::exit(0).encode());

    assert_eq!(frames_in(&stream).unwrap(), [output, Frame::exit(0)]);
}

#[test]
fn a_connection_closed_inside_a_frame_is_an_error() {
    let encoded = Frame::new(Kind::Output, b"hello".to_vec())
        .unwrap()
        .encode();

    for cut in [3, encoded.len() - 1] {
        assert!(frames_in(&encoded[..cut]).is_err(), "cut at {cut}");
    }
}

#[test]
fn an_over_long_or_unknown_frame_is_an_error() {
    let mut too_long = vec![2];
    too_long.extend_from_slice(&u32::try_from(MAX_PAYLOAD + 1).unwrap().to_be_bytes());
    let unknown_kind = [0x63, 0, 0, 0, 0];

    assert!(frames_in(&too_long).is_err());
    assert!(frames_in(&unknown_kind).is_err());
    assert!(Frame::new(Kind::Output, vec![0; MAX_PAYLOAD + 1]).is_none());
}

#[test]
fn a_start_without_a_command_or_with_leftovers_is_refused() {
    let mut empty_command = bytes(START_GOLDEN)[5..14].to_vec();
    empty_command.extend_from_slice(&[0, 0]);
    let mut leftover = bytes(START_GOLDEN)[5..].to_vec();
    leftover.push(0);

    assert!(StartRequest::parse(&empty_command).is_none());
    assert!(StartRequest::parse(&leftover).is_none());
    assert!(StartRequest::parse(&[]).is_none());
}

#[test]
fn a_resize_carries_columns_then_rows() {
    let resize = Frame::new(Kind::Resize, vec![0, 120, 0, 40]).unwrap();

    assert_eq!(resize.terminal_size(), Some((120, 40)));
    assert_eq!(
        Frame::new(Kind::Resize, vec![0, 120])
            .unwrap()
            .terminal_size(),
        None
    );
}

#[test]
fn a_failure_message_is_cut_at_a_character_boundary() {
    let message = "é".repeat(MAX_PAYLOAD);

    let frame = Frame::failed(&message);

    assert!(frame.payload.len() <= MAX_PAYLOAD);
    assert!(String::from_utf8(frame.payload).is_ok());
}
