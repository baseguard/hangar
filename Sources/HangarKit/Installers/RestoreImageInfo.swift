import Foundation

package struct RestoreImageInfo: Sendable {
    package let url: URL
    package let buildVersion: String
    package let version: String
}
