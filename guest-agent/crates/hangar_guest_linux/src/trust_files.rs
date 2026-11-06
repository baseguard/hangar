//! The files that give every login shell and user session Hangar's placeholder variables; pure,
//! so the tests run on any host. Names and values come checked from `hangar_host_commands`.

const HEADER: &str =
    "# Hangar's agent writes this file and replaces it whenever Hangar's settings change.\n";

/// For `/etc/profile.d`, which login shells source; `None` when there is nothing to set.
pub(crate) fn profile_script(variables: &[(String, String)]) -> Option<String> {
    file_with(variables, |name, value| {
        format!("export {name}='{value}'\n")
    })
}

/// For `/etc/environment.d`, which systemd reads for each user session; `None` when there is
/// nothing to set.
pub(crate) fn environment_file(variables: &[(String, String)]) -> Option<String> {
    file_with(variables, |name, value| format!("{name}={value}\n"))
}

/// The header and one `line` per variable; `None` when there is nothing to set.
fn file_with(
    variables: &[(String, String)],
    line: impl Fn(&str, &str) -> String,
) -> Option<String> {
    if variables.is_empty() {
        return None;
    }

    let lines: String = variables
        .iter()
        .map(|(name, value)| line(name, value))
        .collect();
    Some(format!("{HEADER}{lines}"))
}

#[cfg(test)]
#[path = "trust_files_test.rs"]
mod tests;
