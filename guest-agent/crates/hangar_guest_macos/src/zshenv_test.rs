use super::*;

fn variables() -> Vec<(String, String)> {
    vec![
        ("GITHUB_TOKEN".to_string(), "hgr7Hq2".to_string()),
        (
            "NODE_EXTRA_CA_CERTS".to_string(),
            "/Library/Application Support/Hangar/hangar-secrets.pem".to_string(),
        ),
    ]
}

const BLOCK: &str = "# >>> hangar secrets >>>\n\
                     export GITHUB_TOKEN='hgr7Hq2'\n\
                     export NODE_EXTRA_CA_CERTS='/Library/Application Support/Hangar/hangar-secrets.pem'\n\
                     # <<< hangar secrets <<<\n";

#[test]
fn the_block_is_added_after_what_is_there() {
    let text = with_hangar_block("path+=(/opt/bin)", &variables());

    assert_eq!(text, format!("path+=(/opt/bin)\n{BLOCK}"));
}

#[test]
fn a_missing_file_gets_just_the_block() {
    assert_eq!(with_hangar_block("", &variables()), BLOCK);
}

#[test]
fn the_old_block_is_replaced_and_the_rest_kept() {
    let old = "a=1\n# >>> hangar secrets >>>\nexport OLD='x'\n# <<< hangar secrets <<<\nb=2\n";

    let text = with_hangar_block(old, &variables());

    assert_eq!(text, format!("a=1\nb=2\n{BLOCK}"));
}

#[test]
fn no_variables_remove_the_block() {
    let old = format!("a=1\n{BLOCK}");

    assert_eq!(with_hangar_block(&old, &[]), "a=1\n");
    assert_eq!(with_hangar_block(BLOCK, &[]), "");
}

#[test]
fn writing_the_same_variables_again_changes_nothing() {
    let once = with_hangar_block("a=1\n", &variables());

    let twice = with_hangar_block(&once, &variables());

    assert_eq!(twice, once);
}

#[test]
fn the_block_names_are_read_back() {
    let text = format!("export NOT_OURS='x'\n{BLOCK}");

    assert_eq!(
        hangar_block_names(&text),
        ["GITHUB_TOKEN", "NODE_EXTRA_CA_CERTS"]
    );
}

#[test]
fn a_start_marker_without_an_end_takes_the_block_to_the_end() {
    let cut_off = "a=1\n# >>> hangar secrets >>>\nexport OLD='x'\nexport B=2\n";

    assert_eq!(with_hangar_block(cut_off, &[]), "a=1\n");
    assert_eq!(hangar_block_names(cut_off), ["OLD", "B"]);
    assert_eq!(
        with_hangar_block("# <<< hangar secrets <<<\nb=2\n", &[]),
        "# <<< hangar secrets <<<\nb=2\n"
    );
}
