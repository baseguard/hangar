import Darwin
import Foundation
import HangarDisks
import HangarSupport

actor ImageArchiveWriter: ImageSink {
    private let target: URL
    private let temporary: URL
    private let handle: FileHandle
    private let canReplace: Bool
    private var written: Set<String> = []

    /// Writes beside `target` and puts the file in its place only when it is finished, so a failed or cancelled
    /// export leaves a file that was there as it was. Without `replacing`, a file at `target` is refused.
    init(creating target: URL, replacing canReplace: Bool = false) throws {
        guard target.pathExtension == "tar" else { throw HangarError("An image file ends in .tar.") }
        guard canReplace || !FileManager.default.fileExists(atPath: target.path) else {
            throw HangarError("\(target.path) already exists.")
        }

        // Not hidden: a partial file the app's Quit leaves behind can be tens of GB, so the user must see it.
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent("\(target.lastPathComponent).\(UUID().uuidString.prefix(8)).partial")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw HangarError(errno: errno, "Could not create \(temporary.path)")
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)

        do {
            try Self.add("oci-layout", OCILayout.marker, to: handle)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }

        self.target = target
        self.temporary = temporary
        self.handle = handle
        self.canReplace = canReplace
    }

    func upload(_ data: Data, digest: String) throws {
        guard written.insert(digest).inserted else { return }
        try Self.add(OCILayout.blobPath(digest), data, to: handle)
    }

    func finish(manifest: Data) throws -> String {
        let digest = VMImage.digest(of: manifest)
        try upload(manifest, digest: digest)
        let index = OCILayout.Index(manifests: [
            VMImage.Descriptor(
                mediaType: RegistryClient.manifestType, digest: digest,
                size: Int64(manifest.count))
        ])
        try Self.add("index.json", try JSONEncoder().encode(index), to: handle)
        try handle.write(contentsOf: Data(count: 2 * Tar.blockSize))
        try handle.synchronize()
        try handle.close()
        try moveIntoPlace()
        return digest
    }

    private func moveIntoPlace() throws {
        if canReplace {
            guard rename(temporary.path, target.path) == 0 else {
                throw HangarError(errno: errno, "Could not save \(target.path)")
            }
            return
        }
        guard try FileMove.withoutReplacing(temporary, to: target) else {
            throw HangarError("\(target.path) already exists.")
        }
    }

    func discard() {
        try? handle.close()
        try? FileManager.default.removeItem(at: temporary)
    }

    private static func add(_ name: String, _ data: Data, to handle: FileHandle) throws {
        try handle.write(contentsOf: Self.header(name: name, size: data.count))
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data(count: Tar.padding(after: data.count)))
    }

    static func header(name: String, size: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: Tar.blockSize)
        func put(_ text: String, at offset: Int) {
            bytes.replaceSubrange(offset..<offset + text.utf8.count, with: text.utf8)
        }

        func octal(_ value: Int, digits: Int) -> String {
            let text = String(value, radix: 8)
            return String(repeating: "0", count: max(0, digits - text.count)) + text
        }
        put(name, at: Tar.nameField.lowerBound)
        put("0000644", at: Tar.modeField.lowerBound)
        put("0000000", at: Tar.uidField.lowerBound)
        put("0000000", at: Tar.gidField.lowerBound)
        put(octal(size, digits: 11), at: Tar.sizeField.lowerBound)
        put(octal(0, digits: 11), at: Tar.modifiedField.lowerBound)
        put("0", at: Tar.typeField)
        put("ustar", at: Tar.magicField.lowerBound)
        put("00", at: Tar.versionField.lowerBound)
        bytes.replaceSubrange(Tar.checksumField, with: Tar.checksumBytes(of: bytes))

        return Data(bytes)
    }
}
