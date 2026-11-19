import Foundation
import HangarSupport

/// Linux installers Hangar knows by name. Their ISO is downloaded once and checked against the digest Hangar knows
/// for it; the installing happens in the VM's window.
package enum LinuxInstallerISO: String, CaseIterable, Identifiable, Sendable {
    case omarchy

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .omarchy: "Omarchy 4.5"
        }
    }

    package var source: String { iso.url.host ?? "" }

    /// Omarchy names its ISOs by release, so the digest is known here rather than read from the same server.
    var iso: (url: URL, sha256: String) {
        switch self {
        case .omarchy:
            (
                URL(constant: "https://iso.omarchy.org/omarchy-4.5.0-aarch64.iso"),
                "c9a9dd1107c10924eeb1e885226f9884080b1ffbf227d1f7f9ad255e4cebfb17"
            )
        }
    }

    /// A full desktop needs more than a Linux VM's defaults; Omarchy's own test VM has a 40 GB disk.
    package var defaultCPUCount: Int {
        switch self {
        case .omarchy: 4
        }
    }

    package var defaultMemorySize: UInt64 {
        switch self {
        case .omarchy: 8 * ByteSize.gib
        }
    }

    package var defaultDiskSize: UInt64 {
        switch self {
        case .omarchy: 40 * ByteSize.gib
        }
    }

    /// Kept where `Downloader.localFile` keeps a download from the same address, so a template that names the
    /// address finds it.
    @concurrent
    package func download(progress: @escaping ProgressHandler) async throws -> URL {
        let (url, sha256) = iso
        let file = HangarPaths.isoCache.appendingPathComponent(Downloader.cacheName(for: url, fallback: "image.iso"))
        return try await Downloader.cached(
            url, as: file, digest: sha256, phase: "Downloading \(title)", progress: progress)
    }
}
