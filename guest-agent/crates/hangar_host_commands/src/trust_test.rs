use super::*;

#[test]
fn only_hangars_own_ca_names_are_taken_for_hangars() {
    assert!(is_hangar_ca_name("Hangar 6BE3E2E9"));
    assert!(!is_hangar_ca_name("Hangar 6BE3E2E9 hosts"));
    assert!(!is_hangar_ca_name("Hangar Corp Root CA"));
    assert!(!is_hangar_ca_name("Hangar 6be3e2e9"));
}

fn variable(name: &str, value: &str) -> (String, String) {
    (name.to_string(), value.to_string())
}

#[test]
fn the_line_the_host_writes_is_read() {
    let state = parse_trust("3003020101 GITHUB_TOKEN=abc123 NODE_ENV_X=Z9");

    assert_eq!(
        state,
        Some(TrustState {
            ca_der: Some(vec![0x30, 0x03, 0x02, 0x01, 0x01]),
            variables: vec![
                variable("GITHUB_TOKEN", "abc123"),
                variable("NODE_ENV_X", "Z9")
            ],
        })
    );
}

#[test]
fn a_dash_alone_is_the_empty_state() {
    assert_eq!(parse_trust("-"), Some(TrustState::default()));
}

#[test]
fn variables_without_a_ca_are_read() {
    let state = parse_trust("- _A=1");

    assert_eq!(
        state,
        Some(TrustState {
            ca_der: None,
            variables: vec![variable("_A", "1")],
        })
    );
}

#[test]
fn bad_names_refuse_the_line() {
    let long_name = "A".repeat(65);
    for item in [
        "github_token=abc",
        "1TOKEN=abc",
        "TO-KEN=abc",
        "=abc",
        "TOKEN",
        &format!("{long_name}=abc"),
    ] {
        assert_eq!(parse_trust(&format!("- {item}")), None, "{item}");
    }
}

#[test]
fn names_that_steer_programs_refuse_the_line() {
    for name in [
        "PATH",
        "HOME",
        "BASH_ENV",
        "SYSTEMROOT",
        "NODE_OPTIONS",
        "NODE_EXTRA_CA_CERTS",
        "_JAVA_OPTIONS",
        "JDK_JAVA_OPTIONS",
        "CLASSPATH",
        "PERL5LIB",
        "PERLLIB",
        "RUBYLIB",
        "NODE_PATH",
        "PYTHONSTARTUP",
        "GCONV_PATH",
        "LD_PRELOAD",
        "LD_",
        "DYLD_INSERT_LIBRARIES",
    ] {
        assert_eq!(parse_trust(&format!("- TOKEN=a {name}=x")), None, "{name}");
    }
}

#[test]
fn names_that_only_look_like_denied_ones_are_read() {
    let state = parse_trust("- PATHS=x MY_HOME=x LDAP_HOST=x XDYLD_X=x _JAVA_OPTS=x");

    assert_eq!(state.map(|state| state.variables.len()), Some(5));
}

#[test]
fn bad_values_refuse_the_line() {
    let long_value = "a".repeat(129);
    for item in [
        "TOKEN=",
        "TOKEN=a b",
        "TOKEN=a=b",
        "TOKEN=$(id)",
        "TOKEN='x'",
        "TOKEN=ü",
        &format!("TOKEN={long_value}"),
    ] {
        assert_eq!(parse_trust(&format!("- {item}")), None, "{item}");
    }
}

#[test]
fn the_longest_name_and_value_are_read() {
    let (name, value) = ("N".repeat(64), "v".repeat(128));

    let state = parse_trust(&format!("- {name}={value}"));

    assert_eq!(
        state.map(|state| state.variables),
        Some(vec![(name, value)])
    );
}

#[test]
fn a_name_given_twice_refuses_the_line() {
    assert_eq!(parse_trust("- TOKEN=a OTHER=b TOKEN=c"), None);
}

#[test]
fn more_than_32_variables_refuse_the_line() {
    let items: Vec<String> = (0..33).map(|index| format!("V{index}=x")).collect();

    let at_the_limit = parse_trust(&format!("- {}", items[..32].join(" ")));
    let past_the_limit = parse_trust(&format!("- {}", items.join(" ")));

    assert_eq!(at_the_limit.map(|state| state.variables.len()), Some(32));
    assert_eq!(past_the_limit, None);
}

#[test]
fn extra_spaces_refuse_the_line() {
    assert_eq!(parse_trust("- TOKEN=a "), None);
    assert_eq!(parse_trust("-  TOKEN=a"), None);
    assert_eq!(parse_trust(""), None);
}

#[test]
fn bad_hex_refuses_the_line() {
    for ca in [
        "300302010",
        "3003020101ZZ",
        "3003020G01",
        "30030201AB",
        "300302Ab",
    ] {
        assert_eq!(parse_trust(ca), None, "{ca}");
    }
}

#[test]
fn anything_but_one_whole_certificate_refuses_the_line() {
    for ca in [
        "3103020101",
        "300302010100",
        "30030201",
        "3080020101",
        "3085000000000101",
        "30",
        "30030201013003020101",
    ] {
        assert_eq!(parse_trust(ca), None, "{ca}");
    }
}

#[test]
fn a_long_form_length_is_read() {
    let contents = "00".repeat(200);

    let state = parse_trust(&format!("3081c8{contents}"));

    assert_eq!(
        state.and_then(|state| state.ca_der).map(|der| der.len()),
        Some(203)
    );
}

#[test]
fn a_certificate_past_8_kib_refuses_the_line() {
    let fits = format!("30821ffc{}", "00".repeat(8188));
    let too_big = format!("30821ffd{}", "00".repeat(8189));

    assert!(parse_trust(&fits).is_some());
    assert_eq!(parse_trust(&too_big), None);
}

#[test]
fn base64_pads_the_last_group() {
    assert_eq!(base64(b"foobar"), "Zm9vYmFy");
    assert_eq!(base64(b"fooba"), "Zm9vYmE=");
    assert_eq!(base64(b"foob"), "Zm9vYg==");
    assert_eq!(base64(b""), "");
}

#[test]
fn pem_wraps_at_64_characters() {
    let der = vec![0xff; 49];

    let pem = pem(&der);

    let first_line = "/".repeat(64);
    let expected =
        format!("-----BEGIN CERTIFICATE-----\n{first_line}\n/w==\n-----END CERTIFICATE-----\n");
    assert_eq!(pem, expected);
}

#[test]
fn node_learns_the_ca_file_only_with_a_ca() {
    let with_ca = parse_trust("3003020101 TOKEN=a");
    let without_ca = parse_trust("- TOKEN=a");

    let with_ca = with_ca.map(|state| state.variables_with_node_ca(Some("/ca.pem")));
    let without_ca = without_ca.map(|state| state.variables_with_node_ca(Some("/ca.pem")));

    assert_eq!(
        with_ca,
        Some(vec![
            variable("TOKEN", "a"),
            variable(NODE_CA_VARIABLE, "/ca.pem")
        ])
    );
    assert_eq!(without_ca, Some(vec![variable("TOKEN", "a")]));
}
