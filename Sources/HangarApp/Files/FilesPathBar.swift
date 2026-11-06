import HangarKit
import SwiftUI

/// Finder's path bar: each folder from the disk down to the one shown; clicking one opens it.
struct FilesPathBar: View {
    let browser: FilesBrowser

    var body: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(Array(browser.enclosingFolders.enumerated()), id: \.element) { index, path in
                    if index > 0 {
                        Image(systemName: "chevron.forward")
                            .imageScale(.small)
                            .foregroundStyle(.tertiary)
                    }
                    Button(browser.displayName(of: path), systemImage: browser.symbol(forFolderAt: path)) {
                        browser.open(path)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .scrollIndicators(.never)
    }
}
