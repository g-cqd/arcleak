// swift-format-ignore-file
// A strong self-type link models a chain, not a certain cycle — self-edges are
// deliberately excluded from SCC reporting.
final class Node {
    var next: Node?
    var payload: [String: Node] = [:]
}