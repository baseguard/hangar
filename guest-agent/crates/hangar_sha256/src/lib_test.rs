use super::*;

fn hex_of(data: &[u8]) -> String {
    Sha256::of(data).to_string()
}

#[test]
fn known_inputs_give_the_published_hashes() {
    assert_eq!(
        hex_of(b""),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    );
    assert_eq!(
        hex_of(b"abc"),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
    assert_eq!(
        hex_of(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    );
    assert_eq!(
        hex_of(
            b"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrl\
              mnopqrsmnopqrstnopqrstu"
        ),
        "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"
    );
}

#[test]
fn lowercase_hex_reads_back_as_the_same_hash() {
    let hash = Sha256::of(b"abc");

    assert_eq!(Sha256::from_hex(&hash.to_string()), Some(hash));
}

#[test]
fn hex_of_another_length_case_or_alphabet_is_refused() {
    let valid = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

    assert_eq!(Sha256::from_hex(&valid[1..]), None);
    assert_eq!(Sha256::from_hex(&format!("{valid}0")), None);
    assert_eq!(Sha256::from_hex(&valid.to_uppercase()), None);
    assert_eq!(Sha256::from_hex(&valid.replace('a', "g")), None);
    assert_eq!(Sha256::from_hex(""), None);
    // 64 bytes, but not 64 characters: a multi-byte character must not split into "hex".
    assert_eq!(Sha256::from_hex(&format!("é{}", &valid[2..])), None);
}

#[test]
fn the_flag_is_the_hash_after_sha256_and_nothing_else() {
    let hex = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    let arguments = |list: &[&str]| list.iter().map(ToString::to_string).collect::<Vec<_>>();

    assert_eq!(
        Sha256::from_flag(&arguments(&["--sha256", hex])),
        Some(Sha256::of(b"abc"))
    );
    assert_eq!(Sha256::from_flag(&arguments(&[])), None);
    assert_eq!(Sha256::from_flag(&arguments(&["--sha256"])), None);
    assert_eq!(Sha256::from_flag(&arguments(&["--sha", hex])), None);
    assert_eq!(
        Sha256::from_flag(&arguments(&["--sha256", hex, "more"])),
        None
    );
}
