/// The folders a Files window went back from and forward from, like a Finder window's Back and Forward.
struct FolderHistory {
    private(set) var back: [String] = []
    private(set) var forward: [String] = []

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// Opening a folder starts a new way forward.
    mutating func left(_ path: String) {
        back.append(path)
        forward.removeAll()
    }

    mutating func wentBack(from path: String) {
        guard !back.isEmpty else { return }
        back.removeLast()
        forward.append(path)
    }

    mutating func wentForward(from path: String) {
        guard !forward.isEmpty else { return }
        forward.removeLast()
        back.append(path)
    }
}
