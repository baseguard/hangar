import SwiftUI

struct KindPage: View {
    enum Mode: String, CaseIterable {
        case quick = "Quick Start"
        case advanced = "Advanced"
    }

    let kind: CreateVMView.Kind
    let back: (() -> Void)?
    let close: () -> Void
    let created: (UUID) -> Void
    @State private var mode = Mode.quick
    @State private var quickChoice: CreateVMView.Choice
    @State private var advancedChoice: CreateVMView.Choice

    init(kind: CreateVMView.Kind, back: (() -> Void)?, close: @escaping () -> Void, created: @escaping (UUID) -> Void) {
        self.kind = kind
        self.back = back
        self.close = close
        self.created = created
        _quickChoice = State(initialValue: kind.quickDefault)
        _advancedChoice = State(initialValue: kind.advancedDefault)
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: kind.formTitle, back: back) {
                if !kind.quickChoices.isEmpty {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Divider()
            if kind == .registry {
                RegistryForm(close: close, created: created)
            } else if mode == .quick, !kind.quickChoices.isEmpty {
                QuickStart(kind: kind, pick: $quickChoice, close: close, created: created)
            } else {
                CreateForm(kind: kind, choice: $advancedChoice, close: close, created: created)
            }
        }
    }
}

struct SheetHeader<Center: View>: View {
    let title: String
    let back: (() -> Void)?
    @ContentBuilder var center: Center

    var body: some View {
        ZStack {
            HStack {
                if let back {
                    Button(action: back) {
                        Image(systemName: "chevron.backward").minimumHitArea()
                    }
                    .buttonStyle(.borderless)
                    .help("Choose another kind")
                    .accessibilityLabel("Back")
                }
                Text(title).font(.title3.weight(.semibold))
                Spacer()
            }
            center
        }
        .scenePadding(.horizontal)
        .padding(.vertical, Metrics.bezelSpacing)
    }
}
