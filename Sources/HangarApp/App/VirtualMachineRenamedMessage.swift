import Foundation

nonisolated struct VirtualMachineRenamedMessage: NotificationCenter.AsyncMessage {
    typealias Subject = AnyObject
    let oldName: String
    let newName: String
}
