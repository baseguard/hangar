//! The frames `hangar exec` sends on its vsock connection, one connection per command; pure, so
//! the tests run on any host. The host side is `ExecFrame.swift` in `Sources/HangarKit/Guest`; a
//! change to the layout goes in both.
//!
//! A frame is a kind byte, the payload length as a big-endian `u32`, then the payload. The host
//! sends one `Start`, then input and resizes; the agent answers with output and ends with `Exit` or
//! `Failed`. Either side closing the connection ends the command.

#![forbid(unsafe_code)]

use std::io::{self, Read};

/// The guest's vsock port for `hangar exec`, the same on every system. Below 1024, so on Linux only
/// root can listen on it. The host's copy is `ExecBridge.port`.
pub const VSOCK_PORT: u32 = 700;
/// Larger payloads are refused on both sides.
pub const MAX_PAYLOAD: usize = 64 * 1024;

const HEADER_LEN: usize = 5;
const TTY_FLAG: u8 = 1;
const INTERACTIVE_FLAG: u8 = 2;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// Host to guest, first: a [`StartRequest`].
    Start,
    /// Host to guest: bytes for the command's standard input; an empty payload ends it.
    Input,
    /// Host to guest: the terminal's new columns and rows, two big-endian `u16`s.
    Resize,
    /// Guest to host: bytes the command wrote to standard output, or to its terminal.
    Output,
    /// Guest to host: bytes the command wrote to standard error.
    ErrorOutput,
    /// Guest to host: the command's exit code as a big-endian `i32`; the last frame.
    Exit,
    /// Guest to host: why the command couldn't run, in UTF-8; the last frame.
    Failed,
}

impl Kind {
    fn byte(self) -> u8 {
        match self {
            Kind::Start => 1,
            Kind::Input => 2,
            Kind::Resize => 3,
            Kind::Output => 18,
            Kind::ErrorOutput => 19,
            Kind::Exit => 20,
            Kind::Failed => 21,
        }
    }

    fn from_byte(byte: u8) -> Option<Kind> {
        match byte {
            1 => Some(Kind::Start),
            2 => Some(Kind::Input),
            3 => Some(Kind::Resize),
            18 => Some(Kind::Output),
            19 => Some(Kind::ErrorOutput),
            20 => Some(Kind::Exit),
            21 => Some(Kind::Failed),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Frame {
    pub kind: Kind,
    pub payload: Vec<u8>,
}

impl Frame {
    /// `None` for a payload over [`MAX_PAYLOAD`].
    pub fn new(kind: Kind, payload: Vec<u8>) -> Option<Frame> {
        (payload.len() <= MAX_PAYLOAD).then_some(Frame { kind, payload })
    }

    pub fn exit(code: i32) -> Frame {
        Frame {
            kind: Kind::Exit,
            payload: code.to_be_bytes().to_vec(),
        }
    }

    /// The message is cut at a character boundary to fit in one frame.
    pub fn failed(message: &str) -> Frame {
        let mut end = message.len().min(MAX_PAYLOAD);
        while !message.is_char_boundary(end) {
            end -= 1;
        }

        Frame {
            kind: Kind::Failed,
            payload: message.as_bytes()[..end].to_vec(),
        }
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(HEADER_LEN + self.payload.len());
        bytes.push(self.kind.byte());
        bytes.extend_from_slice(&payload_len(&self.payload).to_be_bytes());
        bytes.extend_from_slice(&self.payload);
        bytes
    }

    /// The next frame on the connection; `None` once it closed between frames. An unknown kind or
    /// an over-long payload is an error, after which the connection is closed.
    pub fn read_from(connection: &mut impl Read) -> io::Result<Option<Frame>> {
        let mut header = [0; HEADER_LEN];
        if !read_header(connection, &mut header)? {
            return Ok(None);
        }

        let kind = Kind::from_byte(header[0]).ok_or_else(|| invalid("an unknown frame kind"))?;
        let length = u32::from_be_bytes([header[1], header[2], header[3], header[4]]);
        let length = usize::try_from(length)
            .ok()
            .filter(|&length| length <= MAX_PAYLOAD)
            .ok_or_else(|| invalid("a frame over 64 KiB"))?;

        let mut payload = vec![0; length];
        connection.read_exact(&mut payload)?;
        Ok(Some(Frame { kind, payload }))
    }

    /// The columns and rows of a `Resize` frame.
    pub fn terminal_size(&self) -> Option<(u16, u16)> {
        let mut reader = PayloadReader::new(&self.payload);
        let size = (reader.u16()?, reader.u16()?);
        reader.is_done().then_some(size)
    }
}

/// False when the connection closed before the header's first byte.
fn read_header(connection: &mut impl Read, header: &mut [u8; HEADER_LEN]) -> io::Result<bool> {
    let mut filled = 0;
    while filled < HEADER_LEN {
        match connection.read(&mut header[filled..]) {
            Ok(0) if filled == 0 => return Ok(false),
            Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
            Ok(count) => filled += count,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(true)
}

fn invalid(what: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, format!("Hangar sent {what}."))
}

fn payload_len(payload: &[u8]) -> u32 {
    u32::try_from(payload.len()).unwrap_or(u32::MAX)
}

/// What the `Start` frame asks for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StartRequest {
    /// The program and its arguments; never empty.
    pub command: Vec<String>,
    pub tty: bool,
    pub interactive: bool,
    pub columns: u16,
    pub rows: u16,
    /// The VM's own account, for when nobody is signed in at the guest's screen.
    pub fallback_user: Option<String>,
}

impl StartRequest {
    /// `command` is never empty: `parse` refuses an empty one.
    pub fn program(&self) -> &str {
        self.command.first().map_or("", String::as_str)
    }

    pub fn arguments(&self) -> &[String] {
        self.command.get(1..).unwrap_or(&[])
    }

    /// The payload is the flags byte, columns and rows as `u16`s, the fallback user as a `u16`
    /// length and UTF-8 (empty for none), then the argument count as a `u16` and each argument as
    /// a `u32` length and UTF-8. `None` for anything else, an empty command included.
    pub fn parse(payload: &[u8]) -> Option<StartRequest> {
        let mut reader = PayloadReader::new(payload);
        let flags = reader.u8()?;
        let columns = reader.u16()?;
        let rows = reader.u16()?;
        let user_len = usize::from(reader.u16()?);
        let user = reader.text(user_len)?;
        let count = reader.u16()?;

        let mut command = Vec::with_capacity(usize::from(count));
        for _ in 0..count {
            let len = usize::try_from(reader.u32()?).ok()?;
            command.push(reader.text(len)?);
        }

        if command.is_empty() || !reader.is_done() {
            return None;
        }

        Some(StartRequest {
            command,
            tty: flags & TTY_FLAG != 0,
            interactive: flags & INTERACTIVE_FLAG != 0,
            columns,
            rows,
            fallback_user: (!user.is_empty()).then_some(user),
        })
    }
}

struct PayloadReader<'a> {
    bytes: &'a [u8],
}

impl<'a> PayloadReader<'a> {
    fn new(bytes: &'a [u8]) -> PayloadReader<'a> {
        PayloadReader { bytes }
    }

    fn take(&mut self, count: usize) -> Option<&'a [u8]> {
        if self.bytes.len() < count {
            return None;
        }

        let (taken, rest) = self.bytes.split_at(count);
        self.bytes = rest;
        Some(taken)
    }

    fn u8(&mut self) -> Option<u8> {
        Some(self.take(1)?[0])
    }

    fn u16(&mut self) -> Option<u16> {
        Some(u16::from_be_bytes(self.take(2)?.try_into().ok()?))
    }

    fn u32(&mut self) -> Option<u32> {
        Some(u32::from_be_bytes(self.take(4)?.try_into().ok()?))
    }

    fn text(&mut self, len: usize) -> Option<String> {
        String::from_utf8(self.take(len)?.to_vec()).ok()
    }

    fn is_done(&self) -> bool {
        self.bytes.is_empty()
    }
}

#[cfg(test)]
#[path = "lib_test.rs"]
mod tests;
