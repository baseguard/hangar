import HangarKit
import SwiftUI

/// Finder's Go to Folder: a path typed in the guest's own form, or one starting with ~ for the home folder.
struct GoToFolderSheet: View {
    /// As wide as an inspector column, so a usual path shows whole.
    private static let fieldWidth = Metrics.detailsWidth

    let browser: FilesBrowser
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.bezelSpacing) {
            Text("Go to Folder")
                .font(.headline)
            TextField("Folder", text: $typed, prompt: Text(example))
                .onSubmit(go)
                .frame(minWidth: Self.fieldWidth)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Go", action: go)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .onAppear { typed = browser.folder?.path ?? "" }
    }

    private var example: String {
        browser.os == .windows ? #"C:\Users or ~\Documents"# : "/etc or ~/Documents"
    }

    private func go() {
        browser.goToFolder(typed: typed)
    }
}
