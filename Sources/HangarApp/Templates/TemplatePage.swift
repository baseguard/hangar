import HangarKit
import SwiftUI

/// The New VM sheet's page for a .hangarvm file: the template is read, then its form asks what this Mac must add.
struct TemplatePage: View {
    let url: URL
    let back: (() -> Void)?
    let close: () -> Void
    let created: (UUID) -> Void
    @State private var loaded: Result<VMTemplate, any Error>?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "New VM from “\(templateName)”", back: back) {}
            Divider()
            switch loaded {
            case .success(let template):
                TemplateForm(template: template, templateName: templateName, close: close, created: created)
            case .failure(let error):
                TemplateProblem(message: error.localizedDescription, close: close)
            case nil:
                ProgressView().frame(height: CreateForm.formHeight)
            }
        }
        .task { await load() }
    }

    private var templateName: String { url.deletingPathExtension().lastPathComponent }

    private func load() async {
        let url = url
        do {
            loaded = .success(try await runInBackground { try VMTemplate.read(from: url) })
        } catch {
            loaded = .failure(error)
        }
    }
}

private struct TemplateProblem: View {
    let message: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ContentUnavailableView(
                "Can't Use This Template", systemImage: "exclamationmark.triangle", description: Text(message)
            )
            .frame(height: CreateForm.formHeight)
            Divider()
            HStack {
                Spacer()
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
            }
            .scenePadding()
        }
    }
}
