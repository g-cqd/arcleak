// swift-format-ignore-file
// Bare identifiers that *shadow* member-method names: parameters win the
// lookup, so these assignments store values, not bound self methods. Reduced
// from two dogfooded apps (setter parameter vs `color(for:)` overloads; init
// parameter vs a same-named static factory).
import SwiftUI

@Observable
final class SelectionState {
    private var defaultColor: Color = .red
    private(set) var colors: [UInt8: String] = [:]

    func color(for value: UInt8) -> String {
        colors[value] ?? "none"
    }

    func setDefaultColor(_ color: Color) {
        defaultColor = color
    }
}

final class ArchiveEntry {
    var compositeId: String

    init(compositeId: String) {
        self.compositeId = compositeId
    }

    static func compositeId(sourceId: String, id: Int) -> String {
        "\(sourceId)#\(id)"
    }
}
