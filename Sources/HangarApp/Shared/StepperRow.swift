import SwiftUI

struct StepperRow: View {
    let title: String
    let value: String
    @Binding var number: Int
    let range: ClosedRange<Int>
    var step = 1

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(value).monospacedDigit()
                Stepper(title, value: $number, in: range, step: step)
                    .labelsHidden()
            }
        }
    }
}
