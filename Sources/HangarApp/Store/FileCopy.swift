import Foundation

struct FileCopy: Identifiable {
    let vm: String
    let title: String
    var copied: UInt64
    var total: UInt64

    var id: String { vm }
    var fraction: Double { total > 0 ? Double(copied) / Double(total) : 0 }
}
