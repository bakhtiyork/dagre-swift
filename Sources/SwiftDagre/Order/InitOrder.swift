// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

/// Assigns initial ordering via DFS traversal
public enum InitOrder {

    /// Assigns an initial order value for each node by performing a DFS search
    /// starting from nodes in the first rank.
    ///
    /// Nodes are assigned an order in their rank as they are first visited.
    /// From Gansner, et al., "A Technique for Drawing Directed Graphs."
    ///
    /// Returns a layering matrix with an array per layer, each layer sorted by
    /// the order of its nodes.
    public static func run(_ g: DagreGraph) -> [[String]] {
        var visited = Set<String>()

        // Get simple nodes (non-compound) sorted by rank
        let simpleNodes = g.nodes().filter { g.isLeaf($0) }

        guard let maxRank = simpleNodes.compactMap({ g.node($0)?.rank }).max() else {
            return []
        }

        // Initialize layers
        var layers: [[String]] = Array(repeating: [], count: maxRank + 1)

        // Each frame is a node whose successors are being visited
        struct Frame {
            let successors: [String]
            var next = 0
        }

        func dfs(_ root: String) {
            guard !visited.contains(root) else { return }

            // Marks v visited, places it in its layer and returns the frame for its successors
            func visit(_ v: String) -> Frame {
                visited.insert(v)

                if let node = g.node(v) {
                    let rank = node.rank
                    if rank >= 0 && rank < layers.count {
                        layers[rank].append(v)
                    }
                }

                return Frame(successors: g.successors(v) ?? [])
            }

            var stack = [visit(root)]

            // Continue DFS to successors
            while let top = stack.indices.last {
                guard stack[top].next < stack[top].successors.count else {
                    stack.removeLast()
                    continue
                }

                let w = stack[top].successors[stack[top].next]
                stack[top].next += 1
                if !visited.contains(w) {
                    stack.append(visit(w))
                }
            }
        }

        // Sort nodes by rank and process via DFS
        let orderedVs = simpleNodes
            .map { (v: $0, rank: g.node($0)?.rank ?? 0) }
            .sorted { $0.rank < $1.rank }

        for (v, _) in orderedVs {
            dfs(v)
        }

        return layers
    }
}
