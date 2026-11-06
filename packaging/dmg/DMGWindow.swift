// Draws the disk image's background and writes the .DS_Store that lays out its Finder window.
// Usage: swift DMGWindow.swift background <dir> | layout <volume> <app>

import AppKit

let windowSize = CGSize(width: 660, height: 420)
let titleBarHeight = 32.0
let iconSize = 128.0
let appPoint = CGPoint(x: 170, y: 206)
let applicationsPoint = CGPoint(x: 490, y: 206)
/// Finder counts hidden items when it sizes the scroll area, and a Mac with a mouse always shows scroll bars, so they
/// stay inside the window, in its top corners, clear of the arrow and the titles when hidden files are shown. An item
/// with its label reaches 105 points to each side of its point and 82 above it (measured on macOS 27); any closer to
/// an edge and Finder shifts every icon off the background.
let hiddenItemReach = CGSize(width: 105, height: 82)
let backgroundFolderPoint = CGPoint(x: hiddenItemReach.width, y: hiddenItemReach.height)
let volumeIconPoint = CGPoint(x: windowSize.width - hiddenItemReach.width, y: hiddenItemReach.height)
let backgroundBottom = (red: 0.949, green: 0.953, blue: 0.961)

// MARK: - Background

/// A y measured from the top of the window, in AppKit's bottom-up coordinates.
func fromTop(_ y: Double) -> Double {
    windowSize.height - y
}

func renderBackground(scale: Double, to url: URL) throws {
    let bitmap = try makeBitmap(scale: scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    drawGradient()
    drawDivider()
    drawArrow()
    drawTitles()

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: url)
}

func makeBitmap(scale: Double) throws -> NSBitmapImageRep {
    let width = Int(windowSize.width * scale)
    let height = Int(windowSize.height * scale)
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { throw CocoaError(.fileWriteUnknown) }
    bitmap.size = windowSize
    return bitmap
}

func drawGradient() {
    let top = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    let bottom = NSColor(
        srgbRed: backgroundBottom.red, green: backgroundBottom.green, blue: backgroundBottom.blue, alpha: 1)
    let bounds = CGRect(origin: .zero, size: windowSize)
    NSGradient(colors: [top, bottom], atLocations: [0, 1], colorSpace: .sRGB)?.draw(in: bounds, angle: -90)
}

func drawDivider() {
    NSColor(srgbRed: 0.886, green: 0.894, blue: 0.910, alpha: 1).setFill()
    NSBezierPath(rect: CGRect(x: 48, y: fromTop(358), width: windowSize.width - 96, height: 1)).fill()
}

func drawArrow() {
    let arrow = NSBezierPath()
    let y = fromTop(appPoint.y)
    arrow.move(to: CGPoint(x: 284, y: y))
    arrow.line(to: CGPoint(x: 374, y: y))
    arrow.move(to: CGPoint(x: 362, y: y + 9))
    arrow.line(to: CGPoint(x: 376, y: y))
    arrow.line(to: CGPoint(x: 362, y: y - 9))
    arrow.lineWidth = 2.5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor.systemBlue.setStroke()
    arrow.stroke()
}

func drawTitles() {
    let title = NSColor(srgbRed: 0.114, green: 0.114, blue: 0.122, alpha: 1)
    let subtitle = NSColor(srgbRed: 0.431, green: 0.431, blue: 0.451, alpha: 1)
    let footnote = NSColor(srgbRed: 0.525, green: 0.525, blue: 0.545, alpha: 1)
    drawCentered("Install Hangar", size: 20, weight: .semibold, color: title, y: 46)
    drawCentered("Drag Hangar into the Applications folder.", size: 13, weight: .regular, color: subtitle, y: 74)
    drawCentered("Requires macOS 27 or later on Apple silicon", size: 11, weight: .regular, color: footnote, y: 388)
}

func drawCentered(_ text: String, size: Double, weight: NSFont.Weight, color: NSColor, y: Double) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: paragraph,
    ]
    let string = NSAttributedString(string: text, attributes: attributes)
    let height = string.size().height
    string.draw(in: CGRect(x: 0, y: fromTop(y) - height / 2, width: windowSize.width, height: height))
}

// MARK: - Big-endian bytes

struct DataWriter {
    var data = Data()

    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func i16(_ value: Int16) { u16(UInt16(bitPattern: value)) }
    mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func bytes(_ value: Data) { data.append(value) }
    mutating func bytes(_ value: String) { data.append(contentsOf: Array(value.utf8)) }
    mutating func utf16(_ value: String) { for unit in value.utf16 { u16(unit) } }

    /// A length byte and the name, cut to fit and padded to the field's size, with the HFS separator swapped out.
    mutating func pascal(_ value: String, size: Int) {
        let raw = Array(value.replacingOccurrences(of: ":", with: "/").utf8.prefix(size - 1))
        u8(UInt8(raw.count))
        data.append(contentsOf: raw)
        data.append(contentsOf: [UInt8](repeating: 0, count: size - 1 - raw.count))
    }

    mutating func pad(to length: Int) {
        if data.count < length { data.append(Data(count: length - data.count)) }
    }

    /// An alias record extra: id, length, payload, padded to an even length.
    mutating func aliasTag(_ id: Int16, _ payload: Data) {
        i16(id)
        u16(UInt16(payload.count))
        bytes(payload)
        if payload.count % 2 == 1 { u8(0) }
    }
}

// MARK: - Alias record

/// Seconds since 1904, as the classic Mac OS counted them.
func macTime(_ date: Date) -> Double {
    date.timeIntervalSince1970 + 2_082_844_800
}

/// A date with a 16-bit fraction, as alias records carry it.
func highResolutionDate(_ macTime: Double) -> Data {
    var writer = DataWriter()
    writer.u64(UInt64(macTime * 65536))
    return writer.data
}

func inode(_ path: String) throws -> UInt32 {
    var info = stat()
    guard lstat(path, &info) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
    return UInt32(truncatingIfNeeded: info.st_ino)
}

/// What an alias record says about a file: the volume it is on, its folder and its dates.
struct AliasTarget {
    let volume: URL
    let volumeName: String
    let volumeDate: Double
    let relativePath: String
    let file: URL
    let created: Double
    let parent: URL

    init(relativePath: String, in volume: URL) throws {
        let file = volume.appendingPathComponent(relativePath)
        let volumeValues = try volume.resourceValues(forKeys: [.volumeNameKey, .volumeCreationDateKey])
        self.volume = volume
        volumeName = volumeValues.volumeName ?? volume.lastPathComponent
        volumeDate = macTime(volumeValues.volumeCreationDate ?? Date())
        self.relativePath = relativePath
        self.file = file
        created = macTime(try file.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date())
        parent = file.deletingLastPathComponent()
    }
}

/// A version 2 alias record for a file on the volume; Finder resolves the background image through it.
func alias(for relativePath: String, in volume: URL) throws -> Data {
    let target = try AliasTarget(relativePath: relativePath, in: volume)
    var record = DataWriter()
    try writeAliasHeader(of: target, into: &record)
    try writeAliasTags(of: target, into: &record)
    record.i16(-1)
    record.u16(0)
    return withRecordLength(record.data)
}

func writeAliasHeader(of target: AliasTarget, into record: inout DataWriter) throws {
    record.bytes(Data(count: 4))  // user type
    record.u16(0)  // record length, filled in last
    record.u16(2)  // version
    record.i16(0)  // kind: file
    record.pascal(target.volumeName, size: 28)
    record.u32(UInt32(target.volumeDate))
    record.bytes("H+")  // file system
    record.i16(0)  // drive type: fixed disk
    record.u32(try inode(target.parent.path))
    record.pascal(target.file.lastPathComponent, size: 64)
    record.u32(try inode(target.file.path))
    record.u32(UInt32(target.created))
    record.bytes(Data(count: 8))  // type and creator
    record.i16(-1)  // levels from root: unknown
    record.i16(-1)  // levels to root: unknown
    record.u32(0)  // volume attributes
    record.bytes(Data(count: 2))  // volume file system id
    record.bytes(Data(count: 10))  // reserved
}

func writeAliasTags(of target: AliasTarget, into record: inout DataWriter) throws {
    record.aliasTag(0, Data(target.parent.lastPathComponent.utf8))
    record.aliasTag(16, highResolutionDate(target.volumeDate))
    record.aliasTag(17, highResolutionDate(target.created))
    record.aliasTag(1, try folderIDs(from: target.parent, to: target.volume))
    record.aliasTag(2, Data(carbonPath(of: target).utf8))
    record.aliasTag(14, unicodeName(target.file.lastPathComponent))
    record.aliasTag(15, unicodeName(target.volumeName))
    record.aliasTag(18, Data(("/" + target.relativePath).utf8))
    record.aliasTag(19, Data(target.volume.standardizedFileURL.path.utf8))
}

/// The inode of every folder from the file's own up to, not including, the volume.
func folderIDs(from parent: URL, to volume: URL) throws -> Data {
    var ids = DataWriter()
    var folder = parent
    while folder.standardizedFileURL.path != volume.standardizedFileURL.path {
        ids.u32(try inode(folder.path))
        folder = folder.deletingLastPathComponent()
    }
    return ids.data
}

/// The HFS form of the path: volume and folders separated by colons, with colons in names swapped out.
func carbonPath(of target: AliasTarget) -> String {
    let components = target.relativePath.split(separator: "/").map { $0.replacingOccurrences(of: ":", with: "/") }
    return target.volumeName + ":" + components.joined(separator: ":\0")
}

func unicodeName(_ name: String) -> Data {
    var writer = DataWriter()
    writer.u16(UInt16(name.utf16.count))
    writer.utf16(name.replacingOccurrences(of: ":", with: "/"))
    return writer.data
}

func withRecordLength(_ record: Data) -> Data {
    var data = record
    let length = UInt16(data.count).bigEndian
    withUnsafeBytes(of: length) { data.replaceSubrange(4..<6, with: $0) }
    return data
}

// MARK: - .DS_Store

enum Value {
    case blob(Data)
    case long(UInt32)
}

struct Record {
    let name: String
    let code: String
    let value: Value

    func encode(into writer: inout DataWriter) {
        writer.u32(UInt32(name.utf16.count))
        writer.utf16(name)
        writer.bytes(code)
        switch value {
        case .blob(let data):
            writer.bytes("blob")
            writer.u32(UInt32(data.count))
            writer.bytes(data)
        case .long(let number):
            writer.bytes("long")
            writer.u32(number)
        }
    }
}

func plist(_ object: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
}

func iconLocation(_ point: CGPoint) -> Data {
    var writer = DataWriter()
    writer.u32(UInt32(point.x))
    writer.u32(UInt32(point.y))
    writer.u32(0xFFFF_FFFF)
    writer.u32(0xFFFF_0000)
    return writer.data
}

/// The file's blocks, each 2^width bytes at its offset: the header, the master block, the root block with the free
/// lists and a single leaf node that holds every record.
let headerBlock = (offset: 0, width: 5)
let masterBlock = (offset: 0x20, width: 5)
let rootBlock = (offset: 0x800, width: 11)
let nodeBlock = (offset: 0x1000, width: 12)
let usedBlocks = [headerBlock, masterBlock, rootBlock, nodeBlock]

func dsStore(records: [Record]) -> Data {
    let sorted = records.sorted { ($0.name.lowercased(), $0.code) < ($1.name.lowercased(), $1.code) }
    var file = DataWriter()
    file.u32(1)
    file.bytes("Bud1")
    file.u32(UInt32(rootBlock.offset))
    file.u32(UInt32(1 << rootBlock.width))
    file.u32(UInt32(rootBlock.offset))
    file.bytes(Data(count: 16))

    let blocks = [
        (masterBlock, masterData(count: sorted.count)), (rootBlock, rootData()), (nodeBlock, leafData(sorted)),
    ]
    for (block, contents) in blocks {
        file.pad(to: 4 + block.offset)
        precondition(contents.count <= 1 << block.width)
        file.bytes(contents)
    }
    file.pad(to: 4 + nodeBlock.offset + (1 << nodeBlock.width))
    return file.data
}

/// The leaf node: no children, then the records in order.
func leafData(_ records: [Record]) -> Data {
    var leaf = DataWriter()
    leaf.u32(0)
    leaf.u32(UInt32(records.count))
    for record in records { record.encode(into: &leaf) }
    return leaf.data
}

/// The master block: the tree is one leaf at the node block, one level deep, with every record in it.
func masterData(count: Int) -> Data {
    var master = DataWriter()
    master.u32(2)
    master.u32(0)
    master.u32(UInt32(count))
    master.u32(1)
    master.u32(UInt32(nodeBlock.offset))
    return master.data
}

/// The root block: the block addresses (offset | width), the "DSDB" directory pointing at the master block, and the
/// free list for every width.
func rootData() -> Data {
    let addresses = [rootBlock, masterBlock, nodeBlock].map { UInt32($0.offset | $0.width) }
    var root = DataWriter()
    root.u32(UInt32(addresses.count))
    root.u32(0)
    for index in 0..<256 { root.u32(index < addresses.count ? addresses[index] : 0) }
    root.u32(1)
    root.u8(4)
    root.bytes("DSDB")
    root.u32(1)
    for list in freeLists() {
        root.u32(UInt32(list.count))
        for offset in list { root.u32(offset) }
    }
    return root.data
}

/// Every block the used ones leave free, by width, as a buddy allocator splits the 2^31-byte space.
func freeLists() -> [[UInt32]] {
    var free = [[UInt32]](repeating: [], count: 32)
    func carve(_ offset: Int, _ width: Int) {
        if usedBlocks.contains(where: { $0.offset == offset && $0.width == width }) { return }
        let end = offset + (1 << width)
        if !usedBlocks.contains(where: { $0.offset < end && offset < $0.offset + (1 << $0.width) }) {
            free[width].append(UInt32(offset))
            return
        }
        carve(offset, width - 1)
        carve(offset + (1 << (width - 1)), width - 1)
    }
    carve(0, 31)
    return free
}

func writeLayout(volume: URL, appName: String) throws {
    let background = try alias(for: ".background/background.tiff", in: volume)
    let window: [String: Any] = [
        "ContainerShowSidebar": false, "PreviewPaneVisibility": false, "ShowPathbar": false, "ShowSidebar": false,
        "ShowStatusBar": false, "ShowTabView": false, "ShowToolbar": false, "SidebarWidth": 0,
        "WindowBounds": "{{200, 140}, {\(Int(windowSize.width)), \(Int(windowSize.height + titleBarHeight))}}",
    ]
    let view: [String: Any] = [
        "arrangeBy": "none", "backgroundColorBlue": backgroundBottom.blue,
        "backgroundColorGreen": backgroundBottom.green, "backgroundColorRed": backgroundBottom.red,
        "backgroundImageAlias": background, "backgroundType": 2, "gridOffsetX": 0.0, "gridOffsetY": 0.0,
        "gridSpacing": 100.0, "iconSize": iconSize, "labelOnBottom": true, "scrollPositionX": 0.0,
        "scrollPositionY": 0.0, "showIconPreview": true, "showItemInfo": false, "textSize": 13.0,
        "viewOptionsVersion": 1,
    ]
    let records = [
        Record(name: ".", code: "bwsp", value: .blob(try plist(window))),
        Record(name: ".", code: "icvp", value: .blob(try plist(view))),
        Record(name: ".", code: "vSrn", value: .long(1)),
        Record(name: appName, code: "Iloc", value: .blob(iconLocation(appPoint))),
        Record(name: "Applications", code: "Iloc", value: .blob(iconLocation(applicationsPoint))),
        Record(name: ".background", code: "Iloc", value: .blob(iconLocation(backgroundFolderPoint))),
        Record(name: ".VolumeIcon.icns", code: "Iloc", value: .blob(iconLocation(volumeIconPoint))),
    ]
    try dsStore(records: records).write(to: volume.appendingPathComponent(".DS_Store"))
}

// MARK: - Main

let arguments = CommandLine.arguments
switch arguments.count > 2 ? arguments[1] : "" {
case "background":
    let directory = URL(fileURLWithPath: arguments[2])
    try renderBackground(scale: 1, to: directory.appendingPathComponent("background.png"))
    try renderBackground(scale: 2, to: directory.appendingPathComponent("background@2x.png"))
case "layout" where arguments.count > 3:
    try writeLayout(volume: URL(fileURLWithPath: arguments[2]), appName: arguments[3])
default:
    FileHandle.standardError.write(Data("usage: DMGWindow.swift background <dir> | layout <volume> <app>\n".utf8))
    exit(2)
}
