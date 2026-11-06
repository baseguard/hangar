use super::*;

#[test]
fn plain_names_split_into_parts() {
    assert_eq!(
        parts(b"top/a/b.txt", false),
        Ok(vec!["top".into(), "a".into(), "b.txt".into()])
    );
    assert_eq!(
        parts(b"top/dir/", true),
        Ok(vec!["top".into(), "dir".into()])
    );
    assert_eq!(
        parts(b"top/dir", true),
        Ok(vec!["top".into(), "dir".into()])
    );
}

#[test]
fn every_unsafe_name_is_refused() {
    let refused: [&[u8]; 10] = [
        b"",
        b"top/./a",
        b"top/../a",
        b"..",
        b"top/a\\b",
        b"top/a\0b",
        b"top/a\x1bb",
        b"/etc/passwd",
        b"top/\xff",
        b"top/a/",
    ];

    for name in refused {
        assert!(parts(name, false).is_err(), "{name:?} was accepted");
    }
}
