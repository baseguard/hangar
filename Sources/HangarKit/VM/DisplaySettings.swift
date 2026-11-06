import Foundation

package struct DisplaySettings: Codable, Hashable, Sendable {
    package var width: Int
    package var height: Int
    package var pixelsPerInch: Int

    package init(width: Int, height: Int, pixelsPerInch: Int = 144) {
        self.width = width
        self.height = height
        self.pixelsPerInch = pixelsPerInch
    }

    package static let macDefault = DisplaySettings(width: 2560, height: 1600, pixelsPerInch: 144)
    package static let linuxDefault = DisplaySettings(width: 1920, height: 1080, pixelsPerInch: 96)
}
