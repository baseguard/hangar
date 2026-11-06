import Foundation
import HangarDisks
import HangarSupport

enum WindowsMedia {
    static let drivers = ["NetKVM", "viogpudo", "viorng", "vioserial", "viofs", "viosock"]
    /// The media holds the install image plus Windows PE, the drivers and the installer's own files.
    private static let roomBesideInstallImage = 3 * ByteSize.gib
    private static let bootPartitionSize = "2G"
    private static let statusLimit = 256
    private static let logLimit = 1 << 20
    private static let shownLogLines = 15
    private static let copyPiece = 16 << 20
    private static let progressInterval: TimeInterval = 0.5
    private static let defaultLanguage = "en-US"

    static func create(
        at url: URL, windowsISO: URL, driversISO: URL, winFsp: URL, computerName: String,
        account: WindowsInstaller.Account, progress: @escaping ProgressHandler
    ) throws {
        progress(CreationProgress(phase: "Reading the Windows ISO"))
        let iso = try DiskImage.attach(windowsISO, readOnly: true)
        defer { iso.detach() }
        let source = try InstallSource(iso, name: windowsISO.lastPathComponent)
        let language = setupLanguage(isoRoot: source.root)

        progress(CreationProgress(phase: "Creating the installation media"))
        let imageSize = (try source.installImage.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
        try createPartitionedDisk(at: url, room: imageSize)
        let mountRoot = try privateMountRoot(beside: url)
        defer { rmdir(mountRoot.path) }
        let media = try DiskImage.attach(url, readOnly: false, mountRoot: mountRoot)
        defer { media.detach() }
        guard let boot = media.volumes["msdos"], let images = media.volumes["exfat"] else {
            throw HangarError("Could not partition the Windows installation media.")
        }

        progress(CreationProgress(phase: "Copying Windows PE"))
        try copyWindowsPE(from: source.root, to: boot)
        let hangar = boot.appendingPathComponent("hangar")
        try writeSetupFiles(to: boot, hangar: hangar, language: language)
        try copyDrivers(from: driversISO, to: hangar.appendingPathComponent("drivers"))
        try FileManager.default.copyItem(at: winFsp, to: hangar.appendingPathComponent("winfsp.msi"))
        try copyInstallImage(source.installImage, size: imageSize, to: images, progress: progress)
        // The answer file holds the account's password: written last, it spends the least time on the mounted media.
        try writeAnswerFile(to: hangar, computerName: computerName, account: account, language: language)

        for volume in [boot, images] {
            try ProcessUtil.run("/usr/sbin/dot_clean", ["-m", volume.path])
        }
    }

    private struct InstallSource {
        let root: URL
        let installImage: URL

        init(_ iso: DiskImage, name: String) throws {
            guard let root = iso.mountPoints.first else {
                throw HangarError("\(name) has no file system macOS can read.")
            }

            let installImage = ["sources/install.wim", "sources/install.esd"]
                .map { root.appendingPathComponent($0) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
            guard let installImage else {
                throw HangarError("\(name) is not a Windows installation ISO.")
            }
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent("efi/boot/bootaa64.efi").path)
            else {
                throw HangarError("\(name) is not for Arm. Use the Windows 11 Arm64 ISO.")
            }
            self.root = root
            self.installImage = installImage
        }
    }

    private static func createPartitionedDisk(at url: URL, room imageSize: UInt64) throws {
        let mib = ByteSize.mib
        try SparseFile.create(at: url, size: (imageSize + roomBesideInstallImage + mib - 1) / mib * mib)
        let blank = try DiskImage.attach(url, readOnly: false, mount: false)
        defer { blank.detach() }
        try ProcessUtil.run(
            "/usr/sbin/diskutil",
            [
                "partitionDisk", blank.device, "2", "MBR",
                "FAT32", "HANGAR", bootPartitionSize, "ExFAT", "HANGARWIM", "R",
            ])
    }

    private static func copyWindowsPE(from isoRoot: URL, to boot: URL) throws {
        let files = FileManager.default
        for item in ["boot", "efi", "bootmgr.efi"]
        where files.fileExists(atPath: isoRoot.appendingPathComponent(item).path) {
            try files.copyItem(at: isoRoot.appendingPathComponent(item), to: boot.appendingPathComponent(item))
        }
        try files.createDirectory(at: boot.appendingPathComponent("sources"), withIntermediateDirectories: true)
        try files.copyItem(
            at: isoRoot.appendingPathComponent("sources/boot.wim"),
            to: boot.appendingPathComponent("sources/boot.wim"))

        try files.moveItem(
            at: boot.appendingPathComponent("efi/boot/bootaa64.efi"),
            to: boot.appendingPathComponent("efi/boot/windows.efi"))
        try WindowsFirmware.bootstrap.write(to: boot.appendingPathComponent("efi/boot/bootaa64.efi"))
        try files.createDirectory(at: boot.appendingPathComponent("EFI/Hangar"), withIntermediateDirectories: true)
        try WindowsFirmware.framebufferDriver.write(to: boot.appendingPathComponent("EFI/Hangar/hangarfb.efi"))
    }

    /// The boot volume is FAT32, which has no file permissions, and gets the account's password, so the media's
    /// volumes mount inside the VM's private staging folder instead of /Volumes.
    private static func privateMountRoot(beside media: URL) throws -> URL {
        let folder = media.deletingLastPathComponent().appendingPathComponent("media-volumes", isDirectory: true)
        return try HangarPaths.createDirectory(folder)
    }

    private static func writeSetupFiles(to boot: URL, hangar: URL, language: String) throws {
        try FileManager.default.createDirectory(at: hangar, withIntermediateDirectories: true)
        try winPEAnswerFile(language: language).write(
            to: boot.appendingPathComponent("autounattend.xml"),
            atomically: false, encoding: .utf8)
        try GuestFiles.data("windows/\(GuestTools.windowsAgent)").write(
            to: hangar.appendingPathComponent(GuestTools.windowsAgent))
    }

    private static func writeAnswerFile(
        to hangar: URL, computerName: String, account: WindowsInstaller.Account, language: String
    ) throws {
        try answerFile(computerName: computerName, account: account, language: language)
            .write(to: hangar.appendingPathComponent("unattend.xml"), atomically: false, encoding: .utf8)
    }

    private static func copyInstallImage(
        _ installImage: URL, size imageSize: UInt64, to images: URL, progress: @escaping ProgressHandler
    ) throws {
        let sources = images.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try copy(installImage, to: sources.appendingPathComponent(installImage.lastPathComponent), size: imageSize) {
            copied in
            progress(
                CreationProgress(
                    phase: "Copying the Windows image", fraction: Double(copied) / Double(max(imageSize, 1)),
                    detail: "\(ByteSize.format(copied)) / \(ByteSize.format(imageSize))"))
        }
    }

    static func checkResult(_ url: URL) throws {
        let volume = try FATVolume(image: url)
        defer { volume.close() }
        let status = try volume.readFile(["hangar", "status"], limit: statusLimit).map {
            String(decoding: $0, as: UTF8.self)
        }
        if status?.trimmingCharacters(in: .whitespacesAndNewlines) == "OK" { return }

        let log =
            try volume.readFile(["hangar", "install.log"], limit: logLimit).flatMap {
                String(data: $0, encoding: .isoLatin1)
            } ?? ""
        let tail = log.split(whereSeparator: \.isNewline).suffix(shownLogLines).joined(separator: "\n")
        throw HangarError(
            status == nil
                ? "Windows was not installed: the installer did not finish."
                : "Windows installation failed:\n\(tail)")
    }

    /// The ISO's first UI language, from `sources/lang.ini`; the installer is told it so it asks nothing.
    private static func setupLanguage(isoRoot: URL) -> String {
        var encoding = String.Encoding.utf8
        guard
            let ini = try? String(
                contentsOf: isoRoot.appendingPathComponent("sources/lang.ini"), usedEncoding: &encoding)
        else {
            return defaultLanguage
        }

        var inSection = false
        for line in ini.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("[") {
                inSection = line.lowercased() == "[available ui languages]"
                continue
            }
            guard inSection, let name = line.split(separator: "=").first?.trimmingCharacters(in: .whitespaces),
                name.wholeMatch(of: /[a-zA-Z]{2,3}(?:-[a-zA-Z]{4})?-[a-zA-Z]{2,3}/) != nil
            else { continue }
            return normalizedLanguageTag(name)
        }
        return defaultLanguage
    }

    /// `en-us` as `en-US`, and `zh-hans-cn` as `zh-Hans-CN`: the way Windows writes its tags.
    private static func normalizedLanguageTag(_ tag: String) -> String {
        let parts = tag.split(separator: "-").map(String.init)
        guard parts.count == 3 else { return "\(parts[0].lowercased())-\(parts[1].uppercased())" }
        let script = parts[1].prefix(1).uppercased() + parts[1].dropFirst().lowercased()
        return "\(parts[0].lowercased())-\(script)-\(parts[2].uppercased())"
    }

    private static func copyDrivers(from iso: URL, to folder: URL) throws {
        let image = try DiskImage.attach(iso, readOnly: true)
        defer { image.detach() }
        guard let root = image.mountPoints.first else { throw HangarError("Could not read the virtio-win drivers.") }

        for driver in drivers {
            let source = root.appendingPathComponent("\(driver)/w11/ARM64")
            let destination = folder.appendingPathComponent(driver.lowercased())
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            where file.pathExtension.lowercased() != "pdb" {
                try FileManager.default.copyItem(
                    at: file, to: destination.appendingPathComponent(file.lastPathComponent))
            }
        }
    }

    private static func copy(_ source: URL, to destination: URL, size: UInt64, progress: (UInt64) -> Void) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var copied: UInt64 = 0
        var lastReport = Date.distantPast

        while let chunk = try input.readPiece(upToCount: copyPiece), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
            copied += UInt64(chunk.count)
            if Date().timeIntervalSince(lastReport) > progressInterval || copied == size {
                progress(copied)
                lastReport = Date()
            }
        }

        try output.synchronize()
    }
}
