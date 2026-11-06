//! The SHA-256 hash Hangar names the agent it copies into a guest by: the guest checks the bytes
//! against it before root or SYSTEM runs them.

#![forbid(unsafe_code)]

use std::fmt;

use sha2::Digest as _;

/// How a hash goes on a command line: Hangar runs `update --sha256 <hex>`, and the update passes it
/// on to the half that installs as root or SYSTEM the same way.
pub const FLAG: &str = "--sha256";

const HEX_LENGTH: usize = 64;

/// A SHA-256 hash.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Sha256([u8; 32]);

impl Sha256 {
    pub fn of(data: &[u8]) -> Sha256 {
        Sha256(sha2::Sha256::digest(data).into())
    }

    /// `arguments` are exactly `--sha256 <hex>`.
    pub fn from_flag(arguments: &[String]) -> Option<Sha256> {
        match arguments {
            [flag, hex] if flag == FLAG => Sha256::from_hex(hex),
            _ => None,
        }
    }

    /// Exactly 64 lowercase hex digits, the one form Hangar sends; anything else is `None`.
    pub fn from_hex(text: &str) -> Option<Sha256> {
        let is_lowercase_hex = text
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'));
        if text.len() != HEX_LENGTH || !is_lowercase_hex {
            return None;
        }

        let mut hash = [0; 32];
        hex::decode_to_slice(text, &mut hash).ok()?;
        Some(Sha256(hash))
    }
}

/// Lowercase hex, the form `from_hex` reads.
impl fmt::Display for Sha256 {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&hex::encode(self.0))
    }
}

#[cfg(test)]
#[path = "lib_test.rs"]
mod tests;
