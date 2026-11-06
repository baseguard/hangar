use super::*;

fn variables() -> Vec<(String, String)> {
    vec![
        ("GITHUB_TOKEN".to_string(), "hgr7Hq2".to_string()),
        (
            "NODE_EXTRA_CA_CERTS".to_string(),
            "/ca/hangar.crt".to_string(),
        ),
    ]
}

#[test]
fn the_profile_script_exports_each_variable() {
    let script = profile_script(&variables());

    let expected = format!(
        "{HEADER}export GITHUB_TOKEN='hgr7Hq2'\nexport NODE_EXTRA_CA_CERTS='/ca/hangar.crt'\n"
    );
    assert_eq!(script, Some(expected));
}

#[test]
fn the_environment_file_lists_each_variable() {
    let file = environment_file(&variables());

    let expected = format!("{HEADER}GITHUB_TOKEN=hgr7Hq2\nNODE_EXTRA_CA_CERTS=/ca/hangar.crt\n");
    assert_eq!(file, Some(expected));
}

#[test]
fn no_variables_means_no_files() {
    assert_eq!(profile_script(&[]), None);
    assert_eq!(environment_file(&[]), None);
}
