import SwiftUI

// Value types cannot participate in reference cycles: capturing struct `self`
// copies it. SwiftUI bodies are the canonical case — flagging them is the
// single biggest false-positive source of naive linters.
struct CounterView: View {
    @State private var count = 0

    var body: some View {
        Button("count \(count)") {
            count += 1
        }
    }
}

struct Settings {
    var onChange: (() -> Void)?

    mutating func arm(handler: @escaping () -> Void) {
        onChange = handler
    }
}
