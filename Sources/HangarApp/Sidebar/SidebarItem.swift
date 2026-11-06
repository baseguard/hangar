import Foundation

enum SidebarItem: Hashable {
    case vm(String)
    case job(UUID)
    case network
}
