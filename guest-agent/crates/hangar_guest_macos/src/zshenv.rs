//! Hangar's block in `/etc/zshenv`, which every zsh reads: the placeholder variables between two
//! marker lines, with everything outside the block kept as it was.

const BLOCK_START: &str = "# >>> hangar secrets >>>";
const BLOCK_END: &str = "# <<< hangar secrets <<<";

/// `text` with Hangar's block holding `variables` at its end; without variables the block goes.
pub(crate) fn with_hangar_block(text: &str, variables: &[(String, String)]) -> String {
    let mut kept = without_hangar_block(text);
    if variables.is_empty() {
        return kept;
    }

    if !kept.is_empty() && !kept.ends_with('\n') {
        kept.push('\n');
    }
    kept.push_str(&hangar_block(variables));
    kept
}

/// The names of the variables in Hangar's block, as [`with_hangar_block`] wrote them.
pub(crate) fn hangar_block_names(text: &str) -> Vec<String> {
    let mut names = Vec::new();
    for (line, is_in_block) in lines_with_block(text) {
        if !is_in_block {
            continue;
        }
        let assignment = line
            .strip_prefix("export ")
            .and_then(|rest| rest.split_once('='));
        if let Some((name, _value)) = assignment {
            names.push(name.to_string());
        }
    }
    names
}

/// Values are letters and digits or the agent's own path, so single quotes always hold them.
fn hangar_block(variables: &[(String, String)]) -> String {
    let exports: Vec<String> = variables
        .iter()
        .map(|(name, value)| format!("export {name}='{value}'\n"))
        .collect();
    format!("{BLOCK_START}\n{}{BLOCK_END}\n", exports.concat())
}

fn without_hangar_block(text: &str) -> String {
    let mut kept = String::new();
    for (line, is_in_block) in lines_with_block(text) {
        if !is_in_block {
            kept.push_str(line);
        }
    }
    kept
}

/// Each line, with its newline, and whether it is in Hangar's block: the lines between the two
/// markers, markers excluded. A start marker without an end marker takes the block to the end of
/// the file.
fn lines_with_block(text: &str) -> Vec<(&str, bool)> {
    let mut lines = Vec::new();
    let mut is_inside = false;

    for line in text.split_inclusive('\n') {
        let marker = line.trim_end();
        if marker == BLOCK_START {
            is_inside = true;
        } else if is_inside && marker == BLOCK_END {
            is_inside = false;
        } else {
            lines.push((line, is_inside));
        }
    }
    lines
}

#[cfg(test)]
#[path = "zshenv_test.rs"]
mod tests;
