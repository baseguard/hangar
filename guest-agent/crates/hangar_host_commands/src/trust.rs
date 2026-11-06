//! The `trust` command: the CA certificate the guest should trust and the placeholder variables it
//! should set, as one line `trust <ca> [NAME=VALUE ...]`. Root writes both into system files and
//! stores, so any part that is off refuses the whole line.

/// `<ca>` when the guest should trust no Hangar CA.
const NO_CA: &str = "-";
const MOST_VARIABLES: usize = 32;
const LONGEST_NAME: usize = 64;
const LONGEST_VALUE: usize = 128;
const LARGEST_CERTIFICATE: usize = 8 * 1024;
/// The tag of a DER SEQUENCE, which a whole certificate is.
const DER_SEQUENCE: u8 = 0x30;
/// A long-form DER length has at most this many length bytes here; 4 already covers 4 GiB.
const MOST_LENGTH_BYTES: usize = 4;
const PEM_LINE: usize = 64;
const BASE64_ALPHABET: &[u8; 64] =
    b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Node trusts the CAs in this file. Only the agent sets it: the host may not send it.
const NODE_CA_VARIABLE: &str = "NODE_EXTRA_CA_CERTS";

/// The agents set the variables for every program in the guest, so a name that steers a shell, the
/// dynamic loader or a language runtime would let the host's line run code in every program.
const DENIED_NAMES: [&str; 32] = [
    "PATH",
    "HOME",
    "USER",
    "LOGNAME",
    "SHELL",
    "IFS",
    "ENV",
    "BASH_ENV",
    "ZDOTDIR",
    "TMPDIR",
    "TEMP",
    "TMP",
    "COMSPEC",
    "SYSTEMROOT",
    "WINDIR",
    "PATHEXT",
    "NODE_OPTIONS",
    "PYTHONPATH",
    "PYTHONHOME",
    "PERL5OPT",
    "RUBYOPT",
    "JAVA_TOOL_OPTIONS",
    "_JAVA_OPTIONS",
    "JDK_JAVA_OPTIONS",
    "CLASSPATH",
    "PERL5LIB",
    "PERLLIB",
    "RUBYLIB",
    "NODE_PATH",
    "PYTHONSTARTUP",
    "GCONV_PATH",
    NODE_CA_VARIABLE,
];
/// The dynamic loaders of Linux and macOS read these.
const DENIED_PREFIXES: [&str; 2] = ["LD_", "DYLD_"];

/// Hangar names each VM's root [`HANGAR_CA_PREFIX`] and the first 8 hex digits of the VM's vault.
pub const HANGAR_CA_PREFIX: &str = "Hangar ";

/// The whole state Hangar wants in the guest; an empty one removes what Hangar installed.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TrustState {
    /// Exactly one DER certificate.
    pub ca_der: Option<Vec<u8>>,
    /// Names are `[A-Z_][A-Z0-9_]*` and none of [`DENIED_NAMES`] or [`DENIED_PREFIXES`]; values are
    /// ASCII letters and digits, so neither needs quoting.
    pub variables: Vec<(String, String)>,
}

impl TrustState {
    /// The CA as a PEM file's contents.
    pub fn ca_pem(&self) -> Option<String> {
        self.ca_der.as_deref().map(pem)
    }

    /// The variables, plus [`NODE_CA_VARIABLE`] naming `ca_file` when there is a CA and a file.
    pub fn variables_with_node_ca(&self, ca_file: Option<&str>) -> Vec<(String, String)> {
        let mut variables = self.variables.clone();
        if let (Some(_), Some(ca_file)) = (&self.ca_der, ca_file) {
            variables.push((NODE_CA_VARIABLE.to_string(), ca_file.to_string()));
        }
        variables
    }
}

/// `arguments` is the line after `trust `.
pub(crate) fn parse_trust(arguments: &str) -> Option<TrustState> {
    let mut items = arguments.split(' ');
    let ca_item = items.next()?;
    let ca_der = if ca_item == NO_CA {
        None
    } else {
        Some(parse_certificate(ca_item)?)
    };
    let variables = parse_variables(items)?;

    Some(TrustState { ca_der, variables })
}

/// `None` for anything but one certificate in lowercase hex.
fn parse_certificate(hex: &str) -> Option<Vec<u8>> {
    let der = decode_hex(hex)?;
    is_one_certificate(&der).then_some(der)
}

fn parse_variables<'a>(items: impl Iterator<Item = &'a str>) -> Option<Vec<(String, String)>> {
    let mut variables: Vec<(String, String)> = Vec::new();

    for item in items {
        let (name, value) = item.split_once('=')?;
        let is_new = !variables.iter().any(|(known, _)| known == name);
        let has_room = variables.len() < MOST_VARIABLES;

        let is_allowed_name = is_variable_name(name) && !is_denied_name(name);
        if !is_allowed_name || !is_variable_value(value) || !is_new || !has_room {
            return None;
        }
        variables.push((name.to_string(), value.to_string()));
    }

    Some(variables)
}

fn is_variable_name(name: &str) -> bool {
    let Some(first) = name.bytes().next() else {
        return false;
    };
    let is_name_byte =
        |byte: u8| byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'_';

    let is_well_formed =
        (first.is_ascii_uppercase() || first == b'_') && name.bytes().all(is_name_byte);
    is_well_formed && name.len() <= LONGEST_NAME
}

fn is_denied_name(name: &str) -> bool {
    DENIED_NAMES.contains(&name)
        || DENIED_PREFIXES
            .iter()
            .any(|prefix| name.starts_with(prefix))
}

fn is_variable_value(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= LONGEST_VALUE
        && value.bytes().all(|byte| byte.is_ascii_alphanumeric())
}

/// `None` for anything but an even number of lowercase hex digits within the certificate limit.
fn decode_hex(text: &str) -> Option<Vec<u8>> {
    let is_lowercase_hex = text
        .bytes()
        .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'));
    if text.is_empty() || text.len() > 2 * LARGEST_CERTIFICATE || !is_lowercase_hex {
        return None;
    }
    hex::decode(text).ok()
}

/// One DER SEQUENCE whose definite length covers every byte after its header, so nothing rides
/// along behind the certificate.
fn is_one_certificate(der: &[u8]) -> bool {
    let Some((&DER_SEQUENCE, after_tag)) = der.split_first() else {
        return false;
    };
    let Some((length, contents)) = der_length(after_tag) else {
        return false;
    };

    contents.len() == length
}

/// The DER length at the start of `bytes`, in short or long form, and the bytes after it.
fn der_length(bytes: &[u8]) -> Option<(usize, &[u8])> {
    let (&first, rest) = bytes.split_first()?;
    if first < 0x80 {
        return Some((usize::from(first), rest));
    }

    // 0x80 alone is the indefinite length, which DER doesn't allow.
    let count = usize::from(first & 0x7f);
    if count == 0 || count > MOST_LENGTH_BYTES || rest.len() < count {
        return None;
    }

    let (length_bytes, contents) = rest.split_at(count);
    let mut length = 0;
    for &byte in length_bytes {
        length = length << 8 | usize::from(byte);
    }
    Some((length, contents))
}

fn pem(der: &[u8]) -> String {
    let mut pem = String::from("-----BEGIN CERTIFICATE-----\n");

    for (index, character) in base64(der).chars().enumerate() {
        if index > 0 && index % PEM_LINE == 0 {
            pem.push('\n');
        }
        pem.push(character);
    }

    pem.push_str("\n-----END CERTIFICATE-----\n");
    pem
}

/// Standard base64 with `=` padding.
fn base64(bytes: &[u8]) -> String {
    let mut text = String::with_capacity(bytes.len().div_ceil(3) * 4);

    for group in bytes.chunks(3) {
        let byte = |index: usize| usize::from(group.get(index).copied().unwrap_or(0));
        let bits = byte(0) << 16 | byte(1) << 8 | byte(2);

        // A group of n bytes fills n + 1 characters; `=` pads the rest.
        let filled = group.len() + 1;
        for (index, shift) in [18, 12, 6, 0].into_iter().enumerate() {
            let character = if index < filled {
                char::from(BASE64_ALPHABET[bits >> shift & 0x3f])
            } else {
                '='
            };
            text.push(character);
        }
    }

    text
}

/// Only those certificates are taken for Hangar's, not one of the user's that starts with "Hangar".
pub fn is_hangar_ca_name(name: &str) -> bool {
    name.strip_prefix(HANGAR_CA_PREFIX).is_some_and(|id| {
        id.len() == 8
            && id
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'A'..=b'F').contains(&byte))
    })
}

#[cfg(test)]
#[path = "trust_test.rs"]
mod tests;
