// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Longest path ranking algorithm
/// Assigns ranks by finding the longest path to each node from sources
///
/// This algorithm does not normalize layers because it will be used by other
/// algorithms in most cases. If using this algorithm directly, be sure to
/// run normalize at the end.
public enum LongestPath {

    /// Assigns ranks using longest path algorithm
    /// Matches TypeScript longestPath in rank/util.js lines 31-59
    public static func run(_ g: DagreGraph) {
        var visited = Set<String>()

        // The DFS keeps its own stack of frames, one per node whose successors are being
        // ranked, so its depth is not bounded by the thread's stack
        struct Frame {
            let label: DagreNodeLabel
            let outEdges: [Edge]
            var next = 0
            var minSuccRank = Int.max
        }
        var stack: [Frame] = []

        // Visits v: returns its rank if that is already known, otherwise pushes a frame for it
        func enter(_ v: String) -> Int? {
            guard let label = g.node(v) else { return 0 }

            if visited.contains(v) {
                return label.rank
            }

            visited.insert(v)
            stack.append(Frame(label: label, outEdges: g.outEdges(v) ?? []))
            return nil
        }

        // Process only from source nodes (TypeScript line 58: g.sources().forEach(dfs))
        // Sources are nodes with no incoming edges
        for source in g.sources() {
            var succRank = enter(source)

            while let top = stack.indices.last {
                // Fold in the rank of the successor that was just visited
                if let rank = succRank {
                    let edge = stack[top].outEdges[stack[top].next]
                    let minlen = g.edge(edge.id)?.minlen ?? 1
                    stack[top].minSuccRank = min(stack[top].minSuccRank, rank - minlen)
                    stack[top].next += 1
                    succRank = nil
                }

                if stack[top].next < stack[top].outEdges.count {
                    succRank = enter(stack[top].outEdges[stack[top].next].w)
                } else {
                    // If no successors, this is a sink - use rank 0
                    // Otherwise, use minimum successor rank - minlen
                    let frame = stack.removeLast()
                    let rank = frame.minSuccRank == Int.max ? 0 : frame.minSuccRank
                    frame.label.rank = rank
                    succRank = rank
                }
            }
        }

        // NOTE: TypeScript's longestPath does NOT normalize ranks
        // normalization is done elsewhere if needed
    }
}

// MARK: - Rank Utilities

/// Utilities for rank calculations
public enum RankUtil {

    /// Calculates the slack for an edge (how much longer it is than its minlen)
    /// slack = rank(w) - rank(v) - minlen
    public static func slack(_ g: DagreGraph, edge: Edge) -> Int {
        guard let vLabel = g.node(edge.v),
              let wLabel = g.node(edge.w),
              let edgeLabel = g.edge(edge.id) else {
            return 0
        }

        return wLabel.rank - vLabel.rank - edgeLabel.minlen
    }

    /// Returns true if the edge is tight (slack = 0)
    public static func isTight(_ g: DagreGraph, edge: Edge) -> Bool {
        slack(g, edge: edge) == 0
    }

    /// Finds all tight edges in the graph
    public static func tightEdges(_ g: DagreGraph) -> [Edge] {
        g.edges().filter { isTight(g, edge: $0) }
    }
}
