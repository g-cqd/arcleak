/// Type-level ownership graph over a whole analyzed corpus.
///
/// Nodes are the corpus's known reference types (class/actor declared in the
/// analyzed files). Edges are strong stored-property references whose declared
/// type resolves to another corpus node. Weak/unowned properties and
/// unresolved names produce no edge; self-edges (`var next: Node?`) are
/// excluded — a strong self-type link models chains, not certain cycles.
/// SwiftData `@Model` types contribute only their `@Transient` strong edges:
/// the macro rewrites every other stored property into accessors over managed
/// backing storage (a `@Relationship` pair is not an ARC cycle), but
/// `@Transient` opts a property OUT of management, so it is real ARC
/// storage and still cycles.
///
/// Construction is deterministic regardless of input order: the corpus is
/// sorted by path, nodes by name, edges by (from, to, line).
struct OwnershipGraph {
    struct Edge: Equatable {
        let from: Int
        let to: Int
        let property: String
        let path: String
        let position: SourcePosition
    }

    let nodeNames: [String]
    /// Deduplicated, sorted successor lists.
    let adjacency: [[Int]]
    /// First (lowest-line) edge per (from, to) pair, for path labeling.
    private let edgeByPair: [Pair: Edge]

    private struct Pair: Hashable {
        let from: Int
        let to: Int
    }

    func edge(from: Int, to: Int) -> Edge? {
        edgeByPair[Pair(from: from, to: to)]
    }

    /// A resolved edge before node indices are assigned (endpoints are still
    /// type *names*, so corpus and index-resolved external edges compose).
    private struct NamedEdge {
        let from: String
        let to: String
        let property: String
        let path: String
        let position: SourcePosition
    }

    /// Builds the graph. When `index` is non-nil, a strong stored property whose
    /// referenced type is *not* in the corpus is resolved through the index: if
    /// the index CONFIRMS the type is a class/actor it is added as an external
    /// node carrying its own strong references, so a cross-module back-reference
    /// can close a cycle. When `index` is nil (or resolves nothing) the result
    /// is byte-identical to corpus-only construction — never a guess.
    static func build(from corpus: [FileFacts], index: (any IndexReading)? = nil) -> OwnershipGraph {
        let files = corpus.sorted { $0.path < $1.path }

        var referenceTypes: Set<String> = []
        for file in files {
            for type in file.types where type.isReferenceType == true {
                referenceTypes.insert(type.name)
            }
        }

        // Corpus strong edges, endpoints kept as names. Targets not resolvable
        // within the corpus are queued for index resolution.
        var namedEdges: [NamedEdge] = []
        var unresolved: Set<String> = []
        for file in files {
            for type in file.types where referenceTypes.contains(type.name) {
                let isModel = type.attributeNames.contains("Model")
                for property in type.storedProperties
                where property.strength == .strong && (!isModel || property.hasTransientAttribute) {
                    for target in property.referencedTypeNames where target != type.name {
                        namedEdges.append(
                            NamedEdge(
                                from: type.name,
                                to: target,
                                property: property.name,
                                path: file.path,
                                position: property.position
                            )
                        )
                        if !referenceTypes.contains(target) {
                            unresolved.insert(target)
                        }
                    }
                }
            }
        }

        // Bounded, deterministic BFS: pull in index-confirmed external reference
        // types and their outgoing strong edges. New external targets are queued
        // so a chain (A→B→C→A across modules) can still close.
        var externalNodes: Set<String> = []
        if let index {
            var frontier = unresolved.sorted()
            var visited: Set<String> = []
            var budget = 256
            while !frontier.isEmpty, budget > 0 {
                let name = frontier.removeFirst()
                if visited.contains(name) { continue }
                visited.insert(name)
                budget -= 1
                guard referenceTypes.contains(name) == false,
                    let external = index.externalTypeFacts(name: name),
                    external.isReferenceType
                else { continue }
                externalNodes.insert(name)
                let path = external.declaringPath ?? "<external>"
                for reference in external.strongReferences {
                    for target in reference.referencedTypeNames where target != name {
                        namedEdges.append(
                            NamedEdge(
                                from: name,
                                to: target,
                                property: reference.property,
                                path: path,
                                position: reference.position
                            )
                        )
                        if !referenceTypes.contains(target), !visited.contains(target) {
                            frontier.append(target)
                            frontier.sort()
                        }
                    }
                }
            }
        }

        let names = referenceTypes.union(externalNodes).sorted()
        let indexByName = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })

        var edges: [Edge] = []
        for edge in namedEdges {
            guard let from = indexByName[edge.from], let to = indexByName[edge.to], to != from
            else { continue }
            edges.append(
                Edge(from: from, to: to, property: edge.property, path: edge.path, position: edge.position)
            )
        }
        edges.sort {
            ($0.from, $0.to, $0.position.line, $0.position.column)
                < ($1.from, $1.to, $1.position.line, $1.position.column)
        }

        var adjacency = [[Int]](repeating: [], count: names.count)
        var edgeByPair: [Pair: Edge] = [:]
        for edge in edges {
            let pair = Pair(from: edge.from, to: edge.to)
            if edgeByPair[pair] == nil {
                edgeByPair[pair] = edge
                adjacency[edge.from].append(edge.to)
            }
        }
        return OwnershipGraph(nodeNames: names, adjacency: adjacency, edgeByPair: edgeByPair)
    }

    private init(nodeNames: [String], adjacency: [[Int]], edgeByPair: [Pair: Edge]) {
        self.nodeNames = nodeNames
        self.adjacency = adjacency
        self.edgeByPair = edgeByPair
    }

    /// Shortest cycle through `component` starting (and ending) at its smallest
    /// node index — BFS over component-internal edges, deterministic.
    func shortestCycle(in component: [Int]) -> [Edge] {
        let members = Set(component)
        guard let start = component.min() else { return [] }

        var predecessor = [Int: Int]()
        var distance = [start: 0]
        var queue = [start]
        var head = 0
        while head < queue.count {
            let node = queue[head]
            head += 1
            for next in adjacency[node] where members.contains(next) {
                if next == start {
                    // Close the loop: start … node → start.
                    var reversed: [Int] = [node]
                    var current = node
                    while current != start, let previous = predecessor[current] {
                        reversed.append(previous)
                        current = previous
                    }
                    let order = reversed.reversed() + [start]
                    var path: [Edge] = []
                    var previous = start
                    for hop in order.dropFirst() {
                        guard let edge = edge(from: previous, to: hop) else { return [] }
                        path.append(edge)
                        previous = hop
                    }
                    return path
                }
                if distance[next] == nil {
                    distance[next] = distance[node, default: 0] + 1
                    predecessor[next] = node
                    queue.append(next)
                }
            }
        }
        return []
    }
}
