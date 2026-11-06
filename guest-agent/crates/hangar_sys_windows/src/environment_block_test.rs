use super::*;

fn block(entries: &[&str]) -> Vec<u16> {
    let mut units = Vec::new();
    for entry in entries {
        units.extend(entry.encode_utf16());
        units.push(0);
    }
    units.push(0);
    units
}

fn text(units: &[u16]) -> String {
    String::from_utf16_lossy(units)
}

#[test]
fn variables_are_split_at_the_first_equals_sign() {
    let block = block(&["Path=C:\\Windows", "GITHUB_TOKEN=hangar-placeholder=1"]);

    let found = variables(&block);

    let pairs: Vec<(String, String)> = found
        .iter()
        .map(|(name, value)| (text(name), text(value)))
        .collect();
    assert_eq!(
        pairs,
        [
            ("Path".to_owned(), "C:\\Windows".to_owned()),
            ("GITHUB_TOKEN".to_owned(), "hangar-placeholder=1".to_owned()),
        ]
    );
}

#[test]
fn a_drive_folder_variable_keeps_its_leading_equals_sign() {
    let block = block(&["=C:=C:\\Users\\admin"]);

    let found = variables(&block);

    assert_eq!(found.len(), 1);
    assert_eq!(text(found[0].0), "=C:");
    assert_eq!(text(found[0].1), "C:\\Users\\admin");
}

#[test]
fn the_block_ends_at_its_empty_entry() {
    let mut units = block(&["A=1"]);
    units.extend("B=2".encode_utf16());

    let found = variables(&units);

    assert_eq!(found.len(), 1);
    assert_eq!(variables(&block(&[])), Vec::<(&[u16], &[u16])>::new());
}
