use super::*;

fn quoted(text: &str) -> String {
    let mut json = String::new();
    push_string(&mut json, text);
    json
}

#[test]
fn plain_text_is_only_quoted() {
    assert_eq!(quoted(""), r#""""#);
    assert_eq!(quoted("notes.txt"), r#""notes.txt""#);
}

#[test]
fn quotes_and_backslashes_are_escaped() {
    assert_eq!(quoted(r#"say "hi""#), r#""say \"hi\"""#);
    assert_eq!(quoted(r"C:\Users\admin"), r#""C:\\Users\\admin""#);
}

#[test]
fn every_control_character_is_escaped() {
    assert_eq!(quoted("a\nb\rc\td"), r#""a\nb\rc\td""#);
    assert_eq!(quoted("\u{8}\u{c}"), r#""\b\f""#);
    assert_eq!(
        quoted("\u{0}\u{1}\u{1b}\u{1f}"),
        r#""\u0000\u0001\u001b\u001f""#
    );
}

#[test]
fn non_ascii_stays_utf8() {
    assert_eq!(quoted("Müşteri 文件 \u{fffd}"), "\"Müşteri 文件 \u{fffd}\"");
    assert_eq!(quoted("\u{7f}"), "\"\u{7f}\"");
}
