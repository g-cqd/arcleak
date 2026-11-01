// swift-format-ignore-file
import Foundation

// A binding that shares a method's name is the binding, not a bound method reference to self: nothing here stores a
// closure.
final class LoopVariableShadowsMethod {
    var values: [String: Int] = [:]
    var holder = Holder()

    func value(for key: String) -> Int { 0 }

    func fill(_ source: [String: Int]) {
        for (key, value) in source {
            values[key] = value
            holder.values[key] = value
        }
    }

    func fillIfPresent(_ value: Int?) {
        if let value { holder.values["a"] = value }
        guard let value else { return }
        values["b"] = value
    }

    func fillFromCase(_ result: Result<Int, Error>) {
        switch result {
        case .success(let value): values["c"] = value
        case .failure: break
        }
    }

    func fillFromClosure(_ items: [Int]) {
        items.forEach { value in values["d"] = value }
    }
}

struct Holder { var values: [String: Int] = [:] }
