import HangarKit
import SwiftUI

/// A VM whose agent is installed by hand: none answers, or one too old to update over `hangar exec`.
struct AgentInstallTarget: Identifiable {
    let vm: String
    let os: GuestOS
    let isUpdate: Bool

    var id: String { vm }
}

/// The steps to install Hangar's agent in a guest, with the command to run there ready to copy.
struct AgentInstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    let target: AgentInstallTarget

    var body: some View {
        let guide = GuestTools.installGuide(for: target.os, in: target.vm)
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.title3.weight(.semibold))
                .scenePadding()
            Form {
                Section {
                    ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                        InstallStepRow(number: index + 1, step: step)
                    }
                } footer: {
                    Text(guide.summary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .scenePadding()
        }
        .frame(width: ExportSheet.width)
    }

    private var title: String {
        target.isUpdate
            ? "Update Hangar's Guest Agent in “\(target.vm)”" : "Install Hangar's Guest Agent in “\(target.vm)”"
    }
}

private struct InstallStepRow: View {
    let number: Int
    let step: GuestTools.InstallGuide.Step

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            Text("\(number). \(step.text)")
            if let command = step.command {
                CommandBox(command: command)
            }
        }
    }
}

/// The command on one line that scrolls sideways instead of breaking inside a word, so it reads as it is typed.
private struct CommandBox: View {
    let command: String

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            ScrollView(.horizontal) {
                Text(command)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(Metrics.spacing)
            }
            .background(.quaternary, in: .rect(cornerRadius: Metrics.cornerRadius))
            CopyButton(text: command)
        }
    }
}
