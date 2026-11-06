//! Reading a Windows environment block: `name=value` entries of UTF-16 text, each ended by a NUL,
//! and an empty entry after the last; pure, so its tests run on any host.

const EQUALS: u16 = b'=' as u16;

/// The block's variables as name and value. Windows keeps each drive's current folder in a variable
/// whose name starts with `=`, so a name ends at the first `=` after its first character.
pub(crate) fn variables(block: &[u16]) -> Vec<(&[u16], &[u16])> {
    let mut variables = Vec::new();
    for entry in block.split(|&unit| unit == 0) {
        if entry.is_empty() {
            break;
        }
        let Some(equals) = entry.iter().skip(1).position(|&unit| unit == EQUALS) else {
            continue;
        };
        let (name, value) = entry.split_at(equals + 1);
        variables.push((name, &value[1..]));
    }
    variables
}

#[cfg(test)]
#[path = "environment_block_test.rs"]
mod tests;
