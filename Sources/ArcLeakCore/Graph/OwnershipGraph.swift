/// Type-level ownership graph over a whole analyzed corpus.
///
/// Nodes are the corpus's known reference types (class/actor declared in the
/// analyzed files). Edges are strong stored-property references whose declared
/// type resolves to another corpus node. Weak/unowned properties and
/// unresolved names produce no edge; self-edges (`var next: Node?`) are
/// excluded — a strong self-type link models chains, not certain cycles.
/// SwiftData `@Model` types contribute no outgoing edges: the macro rewrites
/// stored properties into accessors over managed backing storage, so a
/// `@Relationship` pair is not an ARC cycle (dogfood-exposed false positive).
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

    static func build(from corpus: [FileFacts]) -> OwnershipGraph {
        let files = corpus.sorted { $0.path < $1.path }

        var referenceTypes: Set<String> = []
        for file in files {
            for type in file.types where type.isReferenceType == true {
                referenceTypes.insert(type.name)
            }
        }
        let names = referenceTypes.sorted()
        let indexByName = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })

        var edges: [Edge] = []
        for file in files {
            for type in file.types {
                guard let from = indexByName[type.name] else { continue }
                // `@Model` storage is macro-managed, not ARC-owned. (Caveat:
                // an `@Transient` property IS real storage; accepted gap.)
                guard !type.attributeNames.contains("Model") else { continue }
                for property in type.storedProperties where property.strength == .strong {
                    for target in property.referencedTypeNames {
                        guard let to = indexByName[target], to != from else { continue }
                        edges.append(
                            Edge(
                                from: from,
                                to: to,
                                property: property.name,
                                path: file.path,
                                position: property.position
                            )
                        )
                    }
                }
            }
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
