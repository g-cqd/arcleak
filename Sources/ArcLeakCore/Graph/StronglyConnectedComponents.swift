/// Tarjan's strongly-connected-components algorithm, fully iterative.
///
/// Explicit frame stack instead of recursion: a pathological input (a
/// 100k-node chain collapsing into one component) must not be able to blow the
/// call stack. O(V + E), deterministic for a given adjacency.
enum StronglyConnectedComponents {
    static func find(nodeCount: Int, adjacency: [[Int]]) -> [[Int]] {
        var index = [Int](repeating: -1, count: nodeCount)
        var lowlink = [Int](repeating: 0, count: nodeCount)
        var onStack = [Bool](repeating: false, count: nodeCount)
        var stack: [Int] = []
        var counter = 0
        var components: [[Int]] = []

        struct Frame {
            let node: Int
            var nextChild: Int
        }

        for start in 0..<nodeCount where index[start] == -1 {
            var frames: [Frame] = [Frame(node: start, nextChild: 0)]
            index[start] = counter
            lowlink[start] = counter
            counter += 1
            stack.append(start)
            onStack[start] = true

            while let frame = frames.last {
                let node = frame.node
                if frame.nextChild < adjacency[node].count {
                    let child = adjacency[node][frame.nextChild]
                    frames[frames.count - 1].nextChild += 1
                    if index[child] == -1 {
                        index[child] = counter
                        lowlink[child] = counter
                        counter += 1
                        stack.append(child)
                        onStack[child] = true
                        frames.append(Frame(node: child, nextChild: 0))
                    } else if onStack[child] {
                        lowlink[node] = min(lowlink[node], index[child])
                    }
                } else {
                    frames.removeLast()
                    if let parent = frames.last?.node {
                        lowlink[parent] = min(lowlink[parent], lowlink[node])
                    }
                    if lowlink[node] == index[node] {
                        var component: [Int] = []
                        while true {
                            let member = stack.removeLast()
                            onStack[member] = false
                            component.append(member)
                            if member == node { break }
                        }
                        components.append(component)
                    }
                }
            }
        }
        return components
    }
}
