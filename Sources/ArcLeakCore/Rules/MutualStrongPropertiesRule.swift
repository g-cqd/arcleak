/// Cross-file cycle detection: strongly-connected components of the
/// type-level ownership graph (strong stored-property edges between corpus
/// reference types). Reports one finding per component, anchored at the first
/// edge of the shortest cycle, with the full retention path in the message.
///
/// Type-level honesty: an SCC proves the *types* can form a cycle; specific
/// instances may still be acyclic (two objects chained, not looped). Hence
/// "potential", warning by default, and a note naming every link so the reader
/// can pick which direction becomes weak/unowned. SwiftData `@Model` types are
/// exempt at graph construction — their stored properties are macro-managed,
/// so `@Relationship` pairs are not ARC cycles.
struct MutualStrongPropertiesRule: CorpusRule {
    static let emits: [RuleID] = [.mutualStrongProperties]

    static func check(
        corpus: [FileFacts],
        configuration: Configuration,
        index: (any IndexReading)?
    ) -> [Finding] {
        let graph = OwnershipGraph.build(from: corpus, index: index)
        guard !graph.nodeNames.isEmpty else { return [] }

        let components =
            StronglyConnectedComponents
            .find(nodeCount: graph.nodeNames.count, adjacency: graph.adjacency)
            .filter { $0.count >= 2 }
            .sorted { ($0.min() ?? 0) < ($1.min() ?? 0) }

        return components.compactMap { component in
            let cycle = graph.shortestCycle(in: component)
            guard let anchor = cycle.first else { return nil }

            // Bound the printed chain — a pathological 5 000-type ring must not
            // produce a 100 KB diagnostic.
            let maxPrintedLinks = 8
            let shown = cycle.prefix(maxPrintedLinks)
            let elided = cycle.count - shown.count
            var pathDescription = ([anchor.from] + shown.map(\.to))
                .map { graph.nodeNames[$0] }
                .joined(separator: " → ")
            if elided > 0 {
                pathDescription += " → … (+\(elided) more links) → \(graph.nodeNames[anchor.from])"
            }
            var links =
                shown
                .map { edge in
                    "\(graph.nodeNames[edge.from]).\(edge.property) → \(graph.nodeNames[edge.to])"
                        + " (\(edge.path):\(edge.position.line))"
                }
                .joined(separator: "; ")
            if elided > 0 {
                links += "; … (+\(elided) more)"
            }

            let extra =
                component.count > cycle.count
                ? " (\(component.count) types entangled in total)"
                : ""
            return Finding(
                rule: .mutualStrongProperties,
                severity: configuration.severity(for: .mutualStrongProperties),
                path: anchor.path,
                line: anchor.position.line,
                column: anchor.position.column,
                message: "potential retain cycle across types: \(pathDescription)\(extra)",
                note:
                    "strong links: \(links) — make one direction weak (shorter-lived side) or unowned (same-or-longer lifetime); type-level analysis: verify which side owns the other"
            )
        }
    }
}
