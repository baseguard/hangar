//! The clipboard part of the SPICE vdagent protocol (`spice/vd_agent.h`), plain UTF-8 text only.

#![forbid(unsafe_code)]

/// `VD_AGENT_CLIPBOARD_UTF8_TEXT`.
const UTF8_TEXT: u32 = 1;
/// `VD_AGENT_PROTOCOL`.
const PROTOCOL: u32 = 1;
/// `VDP_CLIENT_PORT`.
const CLIENT_PORT: u32 = 1;

/// `VD_AGENT_MAX_DATA_SIZE`.
const CHUNK_LIMIT: usize = 2048;
/// Bigger messages count as a broken channel.
const MESSAGE_LIMIT: usize = 16 << 20;
const CHUNK_HEADER: usize = 8;
const MESSAGE_HEADER: usize = 20;

/// `VD_AGENT_CAP_CLIPBOARD_BY_DEMAND`.
const BY_DEMAND: u32 = 1 << 5;
/// `VD_AGENT_CAP_CLIPBOARD_SELECTION`: clipboard payloads start with a 4-byte selection prefix.
const SELECTION: u32 = 1 << 6;
const SELECTION_PREFIX: usize = 4;

/// `VD_AGENT_CLIPBOARD`.
const CLIPBOARD: u32 = 4;
/// `VD_AGENT_ANNOUNCE_CAPABILITIES`.
const ANNOUNCE: u32 = 6;
/// `VD_AGENT_CLIPBOARD_GRAB`: "my clipboard has new contents of these types".
const GRAB: u32 = 7;
/// `VD_AGENT_CLIPBOARD_REQUEST`.
const REQUEST: u32 = 8;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Message {
    kind: u32,
    data: Vec<u8>,
}

/// The connection should be dropped.
#[derive(Debug, PartialEq, Eq)]
pub enum DecodeError {
    OversizedChunk,
    UnknownMessage,
}

struct HostCapabilities {
    wants_reply: bool,
    has_selection: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Reply {
    SendToHost(Message),
    SetGuestText(String),
    /// Read the guest's clipboard and send it with [`Session::guest_text`].
    SendGuestText,
}

/// The host's announce on a connection decides whether payloads carry a selection prefix.
#[derive(Debug, Default)]
pub struct Session {
    has_selection: bool,
}

/// The first message the guest sends on a new connection.
pub fn hello() -> Message {
    announce(true)
}

impl Session {
    pub fn guest_copied(&self) -> Message {
        grab(self.has_selection)
    }

    pub fn guest_text(&self, text: &str) -> Message {
        clipboard(text, self.has_selection)
    }

    pub fn receive(&mut self, message: &Message) -> Option<Reply> {
        match message.kind {
            ANNOUNCE => self.receive_announce(message),
            GRAB if offered_types(message, self.has_selection).contains(&UTF8_TEXT) => {
                Some(Reply::SendToHost(request(self.has_selection)))
            }
            CLIPBOARD => text(message, self.has_selection).map(Reply::SetGuestText),
            REQUEST => Some(Reply::SendGuestText),
            _ => None,
        }
    }

    fn receive_announce(&mut self, message: &Message) -> Option<Reply> {
        let capabilities = capabilities(message)?;
        self.has_selection = capabilities.has_selection;

        if capabilities.wants_reply {
            Some(Reply::SendToHost(announce(false)))
        } else {
            None
        }
    }
}

#[derive(Debug, Default)]
pub struct Decoder {
    chunk_left: usize,
    chunk_header: Vec<u8>,
    stream: Vec<u8>,
}

impl Decoder {
    pub fn feed(&mut self, bytes: &[u8]) -> Result<Vec<Message>, DecodeError> {
        self.take_chunk_bytes(bytes)?;
        self.take_messages()
    }

    fn take_chunk_bytes(&mut self, bytes: &[u8]) -> Result<(), DecodeError> {
        let mut rest = bytes;

        while !rest.is_empty() {
            let taken = if self.chunk_left == 0 {
                self.take_chunk_header(rest)?
            } else {
                let taken = self.chunk_left.min(rest.len());
                self.stream.extend_from_slice(&rest[..taken]);
                self.chunk_left -= taken;
                taken
            };
            rest = &rest[taken..];
        }

        Ok(())
    }

    /// A chunk header may arrive split across reads; returns the bytes used.
    fn take_chunk_header(&mut self, bytes: &[u8]) -> Result<usize, DecodeError> {
        let taken = (CHUNK_HEADER - self.chunk_header.len()).min(bytes.len());
        self.chunk_header.extend_from_slice(&bytes[..taken]);

        if self.chunk_header.len() == CHUNK_HEADER {
            let size = u32_at(&self.chunk_header, 4).unwrap_or_default() as usize;
            self.chunk_header.clear();
            if size > MESSAGE_LIMIT {
                return Err(DecodeError::OversizedChunk);
            }
            self.chunk_left = size;
        }

        Ok(taken)
    }

    fn take_messages(&mut self) -> Result<Vec<Message>, DecodeError> {
        let mut messages = Vec::new();

        while let (Some(protocol), Some(kind), Some(size)) = (
            u32_at(&self.stream, 0),
            u32_at(&self.stream, 4),
            u32_at(&self.stream, 16),
        ) {
            let size = size as usize;
            if protocol != PROTOCOL || size > MESSAGE_LIMIT {
                return Err(DecodeError::UnknownMessage);
            }

            let end = MESSAGE_HEADER + size;
            if self.stream.len() < end {
                break;
            }

            messages.push(Message {
                kind,
                data: self.stream[MESSAGE_HEADER..end].to_vec(),
            });
            self.stream.drain(..end);
        }

        Ok(messages)
    }
}

pub fn encode(message: &Message) -> Vec<u8> {
    let mut body = Vec::with_capacity(MESSAGE_HEADER + message.data.len());
    body.extend(PROTOCOL.to_le_bytes());
    body.extend(message.kind.to_le_bytes());
    body.extend([0; 8]);
    body.extend(length(message.data.len()).to_le_bytes());
    body.extend(&message.data);

    let chunks = body.len().div_ceil(CHUNK_LIMIT);
    let mut output = Vec::with_capacity(body.len() + chunks * CHUNK_HEADER);
    for chunk in body.chunks(CHUNK_LIMIT) {
        output.extend(CLIENT_PORT.to_le_bytes());
        output.extend(length(chunk.len()).to_le_bytes());
        output.extend(chunk);
    }

    output
}

/// Clipboard text never comes near 4 GiB.
fn length(bytes: usize) -> u32 {
    u32::try_from(bytes).unwrap_or(u32::MAX)
}

fn u32_at(bytes: &[u8], offset: usize) -> Option<u32> {
    let field = bytes.get(offset..offset.checked_add(4)?)?;
    Some(u32::from_le_bytes(field.try_into().ok()?))
}

fn selection_prefix(has_selection: bool) -> Vec<u8> {
    if has_selection {
        vec![0; SELECTION_PREFIX]
    } else {
        Vec::new()
    }
}

fn payload_start(has_selection: bool) -> usize {
    if has_selection { SELECTION_PREFIX } else { 0 }
}

fn announce(wants_reply: bool) -> Message {
    let mut data = Vec::with_capacity(8);
    data.extend(u32::from(wants_reply).to_le_bytes());
    data.extend((BY_DEMAND | SELECTION).to_le_bytes());

    Message {
        kind: ANNOUNCE,
        data,
    }
}

fn grab(has_selection: bool) -> Message {
    let mut data = selection_prefix(has_selection);
    data.extend(UTF8_TEXT.to_le_bytes());

    Message { kind: GRAB, data }
}

fn request(has_selection: bool) -> Message {
    let mut data = selection_prefix(has_selection);
    data.extend(UTF8_TEXT.to_le_bytes());

    Message {
        kind: REQUEST,
        data,
    }
}

fn clipboard(text: &str, has_selection: bool) -> Message {
    let mut data = selection_prefix(has_selection);
    data.extend(UTF8_TEXT.to_le_bytes());
    data.extend(text.as_bytes());

    Message {
        kind: CLIPBOARD,
        data,
    }
}

fn capabilities(message: &Message) -> Option<HostCapabilities> {
    if message.kind != ANNOUNCE {
        return None;
    }

    let wants_reply = u32_at(&message.data, 0)? != 0;
    let has_selection = u32_at(&message.data, 4)? & SELECTION != 0;

    Some(HostCapabilities {
        wants_reply,
        has_selection,
    })
}

fn offered_types(message: &Message, has_selection: bool) -> Vec<u32> {
    let types = message
        .data
        .get(payload_start(has_selection)..)
        .unwrap_or_default();

    let mut offered = Vec::with_capacity(types.len() / 4);
    let (groups, _incomplete) = types.as_chunks::<4>();
    for group in groups {
        offered.push(u32::from_le_bytes(*group));
    }

    offered
}

/// The text of a clipboard message, up to the first NUL; `None` for anything but UTF-8 text.
fn text(message: &Message, has_selection: bool) -> Option<String> {
    let start = payload_start(has_selection);
    if message.kind != CLIPBOARD || u32_at(&message.data, start)? != UTF8_TEXT {
        return None;
    }

    let bytes = message.data.get(start + 4..)?;
    let end = bytes
        .iter()
        .position(|&byte| byte == 0)
        .unwrap_or(bytes.len());

    Some(String::from_utf8_lossy(&bytes[..end]).into_owned())
}

#[cfg(test)]
#[path = "lib_test.rs"]
mod tests;
