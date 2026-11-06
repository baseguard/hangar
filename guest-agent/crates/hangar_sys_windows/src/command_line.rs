//! The command lines that start the agent's programs; pure, so their tests run on any host.

use std::{io, path::Path};

/// Runas on a program on the virtiofs share fails with `ERROR_UNRECOGNIZED_VOLUME`, so `cmd.exe`
/// from System32 starts it; `/d` skips the registry's `AutoRun` commands.
pub(crate) fn elevated_command(program: &Path, parameters: &str) -> io::Result<String> {
    // `cmd.exe` expands `%` and ends the quoted program at `"`.
    if program.to_string_lossy().contains(['%', '"']) {
        return Err(io::Error::other(format!(
            "{} can't be run from a path with % or \" in it.",
            program.display()
        )));
    }

    // The parameters stand outside the quotes, where `cmd.exe` would act on `&`, `|`, `<`, `^`.
    if !is_plain_words(parameters) {
        return Err(io::Error::other(format!(
            "\"{parameters}\" isn't plain words for cmd.exe."
        )));
    }

    Ok(format!("/d /c \"\"{}\" {parameters}\"", program.display()))
}

/// A service's or a Run value's command line. The program is quoted, so a space in its path can't
/// start another program; nothing escapes a quote inside the quotes, so a quote is refused.
pub fn program_command_line(program: &Path, arguments: &[&str]) -> io::Result<String> {
    if program.to_string_lossy().contains('"') {
        return Err(io::Error::other(format!(
            "{} can't be run from a path with \" in it.",
            program.display()
        )));
    }

    // Plain words need no quotes, so none of the quoting rules can split or join them.
    if let Some(argument) = arguments.iter().find(|argument| !is_plain_word(argument)) {
        return Err(io::Error::other(format!(
            "\"{argument}\" isn't a plain word."
        )));
    }

    let mut line = format!("\"{}\"", program.display());
    for argument in arguments {
        line.push(' ');
        line.push_str(argument);
    }

    Ok(line)
}

/// The command line that gives a program exactly `arguments`.
///
/// By the rules Microsoft's C runtime splits a command line with: an argument with a space, a tab
/// or a quote goes in quotes, a quote in it gets a backslash, and backslashes before a quote are
/// doubled.
pub fn command_line_of(arguments: &[String]) -> String {
    arguments
        .iter()
        .map(|argument| quoted(argument))
        .collect::<Vec<_>>()
        .join(" ")
}

fn quoted(argument: &str) -> String {
    let needs_quotes = argument.is_empty() || argument.contains([' ', '\t', '\n', '\u{b}', '"']);
    if !needs_quotes {
        return argument.to_string();
    }

    let mut quoted = String::from("\"");
    let mut backslashes = 0;
    for character in argument.chars() {
        match character {
            '\\' => backslashes += 1,
            '"' => {
                quoted.push_str(&"\\".repeat(backslashes * 2 + 1));
                quoted.push('"');
                backslashes = 0;
            }
            _ => {
                quoted.push_str(&"\\".repeat(backslashes));
                quoted.push(character);
                backslashes = 0;
            }
        }
    }
    quoted.push_str(&"\\".repeat(backslashes * 2));
    quoted.push('"');
    quoted
}

/// Words of letters, digits and `-`, separated by single spaces.
fn is_plain_words(text: &str) -> bool {
    text.split(' ').all(is_plain_word)
}

fn is_plain_word(word: &str) -> bool {
    !word.is_empty()
        && word
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
}

#[cfg(test)]
#[path = "command_line_test.rs"]
mod tests;
