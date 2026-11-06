import Foundation

/// The OCI image layout that Hangar's image files hold: a version marker, an index naming one manifest, and
/// the blobs by digest.
enum OCILayout {
    struct Index: Codable {
        var schemaVersion = 2
        var mediaType: String? = "application/vnd.oci.image.index.v1+json"
        var manifests: [VMImage.Descriptor]
    }

    static let marker = Data(#"{"imageLayoutVersion":"1.0.0"}"#.utf8)

    static func blobPath(_ digest: String) -> String {
        "blobs/sha256/\(Digests.hex(of: digest))"
    }
}
