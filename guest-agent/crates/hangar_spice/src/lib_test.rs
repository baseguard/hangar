use super::*;

fn decode_in_small_pieces(bytes: &[u8]) -> Result<Vec<Message>, DecodeError> {
    let mut decoder = Decoder::default();
    let mut messages = Vec::new();

    for piece in bytes.chunks(7) {
        messages.extend(decoder.feed(piece)?);
    }

    Ok(messages)
}

/// The host stops reading after a message split into chunks, so long text goes in one chunk.
#[test]
fn long_text_goes_in_one_chunk_and_is_read_back() -> Result<(), DecodeError> {
    let sample = "ğüşiöç ".repeat(600);

    let bytes = encode(&clipboard(&sample, true));
    let received = decode_in_small_pieces(&bytes)?;

    assert_eq!(u32_at(&bytes, 0), Some(CLIENT_PORT));
    assert_eq!(
        u32_at(&bytes, 4).map(|size| size as usize),
        Some(bytes.len() - CHUNK_HEADER)
    );
    assert_eq!(received.len(), 1);
    assert_eq!(text(&received[0], true).as_deref(), Some(sample.as_str()));
    assert_eq!(text(&received[0], false), None);

    Ok(())
}

#[test]
fn a_grab_is_the_bytes_the_host_reads() -> Result<(), DecodeError> {
    let bytes = encode(&grab(false));
    let expected = [
        1, 0, 0, 0, 24, 0, 0, 0, 1, 0, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 1, 0,
        0, 0,
    ];

    assert_eq!(bytes, expected);
    assert_eq!(decode_in_small_pieces(&bytes)?, vec![grab(false)]);

    Ok(())
}

#[test]
fn a_session_follows_the_host() {
    let mut session = Session::default();
    let mut host = announce(true);
    host.data[4..8].copy_from_slice(&SELECTION.to_le_bytes());

    assert_eq!(
        session.receive(&host),
        Some(Reply::SendToHost(announce(false)))
    );

    assert_eq!(session.guest_copied(), grab(true));

    assert_eq!(
        session.receive(&grab(true)),
        Some(Reply::SendToHost(request(true)))
    );

    assert_eq!(
        session.receive(&clipboard("from the Mac", true)),
        Some(Reply::SetGuestText("from the Mac".into()))
    );

    assert_eq!(session.receive(&request(true)), Some(Reply::SendGuestText));

    assert_eq!(
        text(&session.guest_text("from the guest"), true).as_deref(),
        Some("from the guest")
    );
}

#[test]
fn clipboard_types_other_than_text_are_ignored() {
    let mut session = Session::default();
    let image_grab = Message {
        kind: GRAB,
        data: 2u32.to_le_bytes().to_vec(),
    };

    let reply = session.receive(&image_grab);

    assert_eq!(reply, None);
}

#[test]
fn a_chunk_over_the_limit_ends_the_stream() {
    let mut oversized = CLIENT_PORT.to_le_bytes().to_vec();
    oversized.extend(u32::MAX.to_le_bytes());

    let decoded = Decoder::default().feed(&oversized);

    assert_eq!(decoded, Err(DecodeError::OversizedChunk));
}

/// The host splits what it sends into chunks of `VD_AGENT_MAX_DATA_SIZE`.
fn as_the_host_sends(message: &Message) -> Vec<u8> {
    let one_chunk = encode(message);
    let mut bytes = Vec::new();
    for chunk in one_chunk[CHUNK_HEADER..].chunks(2048) {
        bytes.extend(CLIENT_PORT.to_le_bytes());
        bytes.extend(length(chunk.len()).to_le_bytes());
        bytes.extend(chunk);
    }
    bytes
}

/// A message over the limit used to end the stream, and the next connection then read the rest
/// of it as garbage.
#[test]
fn a_message_over_the_limit_is_skipped_and_the_next_one_read() -> Result<(), DecodeError> {
    let oversized = Message {
        kind: CLIPBOARD,
        data: vec![b'x'; MESSAGE_LIMIT + 1],
    };
    let mut bytes = as_the_host_sends(&oversized);
    bytes.extend(as_the_host_sends(&grab(true)));

    let mut decoder = Decoder::default();
    let mut received = Vec::new();
    for piece in bytes.chunks(64 * 1024) {
        received.extend(decoder.feed(piece)?);
    }

    assert_eq!(received, vec![grab(true)]);
    assert!(decoder.stream.capacity() < 2 * 64 * 1024 + MESSAGE_HEADER);
    Ok(())
}

#[test]
fn text_too_long_for_a_message_goes_as_empty_text() {
    let session = Session::default();
    let longest = "x".repeat(MESSAGE_LIMIT - SELECTION_PREFIX - 4);

    let too_long = session.guest_text(&format!("{longest}x"));
    let fitting = session.guest_text(&longest);

    assert_eq!(text(&too_long, false).as_deref(), Some(""));
    assert_eq!(
        text(&fitting, false).map(|text| text.len()),
        Some(longest.len())
    );
}

#[test]
fn a_message_of_another_protocol_ends_the_stream() {
    let mut wrong_protocol = CLIENT_PORT.to_le_bytes().to_vec();
    wrong_protocol.extend(20u32.to_le_bytes());
    wrong_protocol.extend([9; 20]);

    let decoded = Decoder::default().feed(&wrong_protocol);

    assert_eq!(decoded, Err(DecodeError::UnknownMessage));
}

#[test]
fn a_truncated_clipboard_message_is_ignored() {
    let mut session = Session::default();
    let truncated = Message {
        kind: CLIPBOARD,
        data: vec![1, 0],
    };

    let reply = session.receive(&truncated);

    assert_eq!(reply, None);
}
