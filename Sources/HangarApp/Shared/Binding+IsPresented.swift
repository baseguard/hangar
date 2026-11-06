import SwiftUI

/// Shows a dialog while `value` holds what it is about; dismissing the dialog clears it.
func isPresented<Value>(_ value: Binding<Value?>) -> Binding<Bool> {
    Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
}
