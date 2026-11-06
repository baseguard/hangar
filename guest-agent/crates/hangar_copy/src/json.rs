//! Text as a JSON string, for the one JSON object `ls` writes.

/// Appends `text` to `json` as a quoted JSON string; non-ASCII stays UTF-8, which JSON allows.
pub(crate) fn push_string(json: &mut String, text: &str) {
    json.push('"');
    for character in text.chars() {
        match character {
            '"' => json.push_str("\\\""),
            '\\' => json.push_str("\\\\"),
            '\n' => json.push_str("\\n"),
            '\r' => json.push_str("\\r"),
            '\t' => json.push_str("\\t"),
            '\u{8}' => json.push_str("\\b"),
            '\u{c}' => json.push_str("\\f"),
            control if control < ' ' => {
                let escape = format!("\\u{:04x}", u32::from(control));
                json.push_str(&escape);
            }
            other => json.push(other),
        }
    }
    json.push('"');
}

#[cfg(test)]
#[path = "json_test.rs"]
mod tests;
