//! SHA-256 (FIPS 180-4) in plain Rust: Hangar names the agent it copies into a guest by this hash,
//! and the guest checks the bytes against it before root or SYSTEM runs them. No platform has a
//! hash call that all three agents can use, and the agent takes no third-party crates for it.

#![forbid(unsafe_code)]

use std::fmt;

/// How a hash goes on a command line: Hangar runs `update --sha256 <hex>`, and the update passes it
/// on to the half that installs as root or SYSTEM the same way.
pub const FLAG: &str = "--sha256";

const BLOCK_LENGTH: usize = 64;
const HEX_LENGTH: usize = 64;

const INITIAL_STATE: [u32; 8] = [
    0x6a09_e667,
    0xbb67_ae85,
    0x3c6e_f372,
    0xa54f_f53a,
    0x510e_527f,
    0x9b05_688c,
    0x1f83_d9ab,
    0x5be0_cd19,
];

const ROUND_CONSTANTS: [u32; 64] = [
    0x428a_2f98,
    0x7137_4491,
    0xb5c0_fbcf,
    0xe9b5_dba5,
    0x3956_c25b,
    0x59f1_11f1,
    0x923f_82a4,
    0xab1c_5ed5,
    0xd807_aa98,
    0x1283_5b01,
    0x2431_85be,
    0x550c_7dc3,
    0x72be_5d74,
    0x80de_b1fe,
    0x9bdc_06a7,
    0xc19b_f174,
    0xe49b_69c1,
    0xefbe_4786,
    0x0fc1_9dc6,
    0x240c_a1cc,
    0x2de9_2c6f,
    0x4a74_84aa,
    0x5cb0_a9dc,
    0x76f9_88da,
    0x983e_5152,
    0xa831_c66d,
    0xb003_27c8,
    0xbf59_7fc7,
    0xc6e0_0bf3,
    0xd5a7_9147,
    0x06ca_6351,
    0x1429_2967,
    0x27b7_0a85,
    0x2e1b_2138,
    0x4d2c_6dfc,
    0x5338_0d13,
    0x650a_7354,
    0x766a_0abb,
    0x81c2_c92e,
    0x9272_2c85,
    0xa2bf_e8a1,
    0xa81a_664b,
    0xc24b_8b70,
    0xc76c_51a3,
    0xd192_e819,
    0xd699_0624,
    0xf40e_3585,
    0x106a_a070,
    0x19a4_c116,
    0x1e37_6c08,
    0x2748_774c,
    0x34b0_bcb5,
    0x391c_0cb3,
    0x4ed8_aa4a,
    0x5b9c_ca4f,
    0x682e_6ff3,
    0x748f_82ee,
    0x78a5_636f,
    0x84c8_7814,
    0x8cc7_0208,
    0x90be_fffa,
    0xa450_6ceb,
    0xbef9_a3f7,
    0xc671_78f2,
];

/// A SHA-256 hash.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Sha256([u8; 32]);

impl Sha256 {
    pub fn of(data: &[u8]) -> Sha256 {
        let mut state = INITIAL_STATE;
        let padded = padded_blocks(data);
        for block in padded.as_chunks::<BLOCK_LENGTH>().0 {
            mix_block(&mut state, block);
        }

        let mut hash = [0; 32];
        for (bytes, word) in hash.as_chunks_mut::<4>().0.iter_mut().zip(state) {
            *bytes = word.to_be_bytes();
        }
        Sha256(hash)
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
        if text.len() != HEX_LENGTH {
            return None;
        }

        let mut hash = [0; 32];
        for (byte, [high, low]) in hash.iter_mut().zip(text.as_bytes().as_chunks::<2>().0) {
            *byte = lowercase_hex_digit(*high)? << 4 | lowercase_hex_digit(*low)?;
        }
        Some(Sha256(hash))
    }
}

/// Lowercase hex, the form `from_hex` reads.
impl fmt::Display for Sha256 {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        for byte in self.0 {
            write!(formatter, "{byte:02x}")?;
        }
        Ok(())
    }
}

fn lowercase_hex_digit(character: u8) -> Option<u8> {
    match character {
        b'0'..=b'9' => Some(character - b'0'),
        b'a'..=b'f' => Some(character - b'a' + 10),
        _ => None,
    }
}

/// `data`, a 1 bit, zeros, and the length in bits, filling whole blocks. The agent is a few
/// megabytes and is hashed once per update, so the copy is no matter.
fn padded_blocks(data: &[u8]) -> Vec<u8> {
    let length_in_bits = u64::try_from(data.len())
        .unwrap_or(u64::MAX)
        .wrapping_mul(8);

    let mut padded = data.to_vec();
    padded.push(0x80);
    while padded.len() % BLOCK_LENGTH != BLOCK_LENGTH - 8 {
        padded.push(0);
    }
    padded.extend_from_slice(&length_in_bits.to_be_bytes());
    padded
}

#[expect(
    clippy::many_single_char_names,
    reason = "a to h are the working variables' names in FIPS 180-4"
)]
fn mix_block(state: &mut [u32; 8], block: &[u8; BLOCK_LENGTH]) {
    let schedule = message_schedule(block);
    let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = *state;

    for (constant, word) in ROUND_CONSTANTS.iter().zip(schedule) {
        let choice = (e & f) ^ (!e & g);
        let majority = (a & b) ^ (a & c) ^ (b & c);
        let sum_e = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
        let sum_a = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);

        let first = h
            .wrapping_add(sum_e)
            .wrapping_add(choice)
            .wrapping_add(*constant)
            .wrapping_add(word);
        let second = sum_a.wrapping_add(majority);

        h = g;
        g = f;
        f = e;
        e = d.wrapping_add(first);
        d = c;
        c = b;
        b = a;
        a = first.wrapping_add(second);
    }

    for (word, mixed) in state.iter_mut().zip([a, b, c, d, e, f, g, h]) {
        *word = word.wrapping_add(mixed);
    }
}

fn message_schedule(block: &[u8; BLOCK_LENGTH]) -> [u32; 64] {
    let mut schedule = [0; 64];
    for (word, bytes) in schedule.iter_mut().zip(block.as_chunks::<4>().0) {
        *word = u32::from_be_bytes(*bytes);
    }

    for index in 16..64 {
        let before_15 = schedule[index - 15];
        let before_2 = schedule[index - 2];
        let sigma_0 = before_15.rotate_right(7) ^ before_15.rotate_right(18) ^ (before_15 >> 3);
        let sigma_1 = before_2.rotate_right(17) ^ before_2.rotate_right(19) ^ (before_2 >> 10);
        schedule[index] = schedule[index - 16]
            .wrapping_add(sigma_0)
            .wrapping_add(schedule[index - 7])
            .wrapping_add(sigma_1);
    }
    schedule
}

#[cfg(test)]
#[path = "lib_test.rs"]
mod tests;
