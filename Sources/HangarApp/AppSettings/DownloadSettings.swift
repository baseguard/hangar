import Foundation
import HangarKit
import HangarSupport
import SwiftUI

struct DownloadSettings: View {
    static let listHeight: CGFloat = 360

    @Environment(VMStore.self) private var store
    @State private var entries: [CacheEntry]?
    @State private var deleting: Set<URL> = []

    var body: some View {
        Form {
            if let entries {
                if entries.isEmpty {
                    Text("Nothing downloaded yet.").foregroundStyle(.secondary)
                }
                ForEach(CacheEntry.Kind.allCases, id: \.self) { kind in
                    let group = entries.filter { $0.kind == kind }
                    if !group.isEmpty {
                        Section(kind.rawValue) {
                            ForEach(group) { entry in row(entry) }
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .frame(height: Self.listHeight)
        .safeAreaInset(edge: .bottom) {
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
        }
        .task { await load() }
    }

    private var summary: String {
        let total = entries?.reduce(0) { $0 + $1.size } ?? 0
        return
            "\(ByteSize.format(total)) in all. Anything deleted is downloaded again when a new VM needs it. Copies that VMs share free less space than shown."
    }

    private func row(_ entry: CacheEntry) -> some View {
        LabeledContent {
            HStack {
                Text(ByteSize.format(entry.size)).monospacedDigit().foregroundStyle(.secondary)
                Button {
                    delete(entry)
                } label: {
                    Image(systemName: "trash").minimumHitArea()
                }
                .buttonStyle(.borderless)
                .disabled(deleting.contains(entry.url))
                .accessibilityLabel("Delete \(entry.title)")
            }
        } label: {
            Text(entry.title).lineLimit(1).truncationMode(.middle)
        }
    }

    private func load() async {
        entries = await CacheStore.entries()
    }

    private func delete(_ entry: CacheEntry) {
        deleting.insert(entry.url)
        Task {
            defer { deleting.remove(entry.url) }
            do {
                try await CacheStore.delete(entry)
            } catch {
                store.report(error, doing: "delete \(entry.title)")
            }
            await load()
        }
    }
}
