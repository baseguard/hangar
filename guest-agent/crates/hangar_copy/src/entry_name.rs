//! Which names an archive entry may have: relative, `/`-separated, UTF-8, and made of parts that
//! each name one item inside its folder. `cp-out` checks the names it writes by the same rules.

/// The parts of `name`, or why it is refused. A folder's name may end in one `/`.
pub(crate) fn parts(name: &[u8], is_folder: bool) -> Result<Vec<String>, &'static str> {
    let Ok(text) = std::str::from_utf8(name) else {
        return Err("its name isn't UTF-8");
    };
    let text = if is_folder {
        text.strip_suffix('/').unwrap_or(text)
    } else {
        text
    };
    if text.starts_with('/') {
        return Err("its name is absolute");
    }

    let mut parts = Vec::new();
    for part in text.split('/') {
        check_part(part)?;
        parts.push(part.to_string());
    }
    Ok(parts)
}

/// `Ok` for a part that names an item inside its folder and reads the same on every guest.
pub(crate) fn check_part(part: &str) -> Result<(), &'static str> {
    match part {
        "" => return Err("its name has an empty part"),
        "." => return Err("its name has a '.' part"),
        ".." => return Err("its name has a '..' part"),
        _ => {}
    }

    if part.contains('\\') {
        return Err("its name has a backslash");
    }
    if part.contains('\0') {
        return Err("its name has a NUL");
    }
    if part.contains(char::is_control) {
        return Err("its name has a control character");
    }
    Ok(())
}

#[cfg(test)]
#[path = "entry_name_test.rs"]
mod tests;
