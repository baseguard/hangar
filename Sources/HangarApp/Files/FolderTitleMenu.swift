import HangarKit
import SwiftUI

/// The window title's menu, like a Finder window's: the folders that enclose the one shown, nearest first.
struct FolderTitleMenu: View {
    let browser: FilesBrowser

    var body: some View {
        ForEach(browser.enclosingFolders.dropLast().reversed(), id: \.self) { path in
            Button(browser.displayName(of: path), systemImage: browser.symbol(forFolderAt: path)) {
                browser.open(path)
            }
        }
    }
}
