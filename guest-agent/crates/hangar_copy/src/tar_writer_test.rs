use super::*;

#[test]
fn a_pax_record_length_counts_its_own_digits() {
    assert_eq!(pax_record("size", "1"), "9 size=1\n");
    assert_eq!(pax_record("path", "abc"), "12 path=abc\n");
    let long = "x".repeat(91);
    assert_eq!(pax_record("path", &long).len(), 101);
    assert!(pax_record("path", &long).starts_with("101 "));
}

/// The host reads sizes as octal only, so 8 GiB and more goes in a PAX record it reads instead.
#[test]
fn a_size_of_8_gib_goes_in_a_pax_header_and_the_size_field_stays_octal()
-> Result<(), Box<dyn std::error::Error>> {
    let mut writer = TarWriter::new(Vec::new());

    let cut_short = writer.add_file("top/huge", false, OCTAL_LIMIT, UNIX_EPOCH, io::empty());
    let archive = writer.archive.get_ref().clone();

    assert!(cut_short.is_err());
    assert_eq!(archive[156], b'x');
    assert!(archive[512..].starts_with(b"19 size=8589934592\n"));
    assert_eq!(&archive[1024 + 124..1024 + 136], b"00000000000\0");
    let mut reader = tar::Archive::new(archive.as_slice());
    let entry = reader.entries()?.next().ok_or("no entry")??;
    assert_eq!(entry.size(), OCTAL_LIMIT);
    assert_eq!(&*entry.path_bytes(), b"top/huge");
    Ok(())
}

#[test]
fn a_file_that_got_shorter_fails() {
    let mut writer = TarWriter::new(Vec::new());

    let added = writer.add_file("top", false, 10, UNIX_EPOCH, &b"abc"[..]);

    assert!(added.is_err());
}
