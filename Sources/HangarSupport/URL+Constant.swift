import Foundation

extension URL {
    package init(constant: StaticString) {
        guard let url = URL(string: "\(constant)") else {
            preconditionFailure("\(constant) is not a valid URL.")
        }
        self = url
    }
}
