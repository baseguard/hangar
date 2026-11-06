use super::*;

#[test]
fn only_certificates_labelled_hangar_are_removed() {
    let listing = "SHA-256 hash: AAA1\nSHA-1 hash: B1\nkeychain: \"/Library/Keychains/System.keychain\"\n\
                   attributes:\n    \"alis\"<blob>=\"Hangar 1F2E3D4C\"\n    \"labl\"<blob>=\"Hangar 1F2E3D4C\"\n\
                   SHA-256 hash: AAA2\nSHA-1 hash: B2\nattributes:\n    \"labl\"<blob>=\"Not Hangar CA\"\n\
                   SHA-256 hash: AAA3\nSHA-1 hash: B3\nattributes:\n    \"labl\"<blob>=\"Hangar 77AA88BB\"\n\
                   SHA-256 hash: AAA4\nSHA-1 hash: B4\nattributes:\n    \"labl\"<blob>=\"Hangar Corp Root\"\n";

    assert_eq!(hangar_certificate_hashes(listing), ["AAA1", "AAA3"]);
}
