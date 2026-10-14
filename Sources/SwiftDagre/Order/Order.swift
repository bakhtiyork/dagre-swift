// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Order optimization to minimize edge crossings
public enum Order {

    /// Applies heuristics to minimize edge crossings in the graph
    ///
    /// Preconditions:
    ///   1. Graph must be DAG
    ///   2. Graph nodes must be objects with a "rank" attribute
    ///   3. Graph edges must have the "weight" attribute
    ///
    /// Postconditions:
    ///   1. Graph nodes will have an "order" attribute based on the results
    ///
    /// - Parameters:
    ///   - g: The graph to order
    ///   - disableOptimization: Skip the optimization heuristic
    ///   - customOrder: Optional custom order function that overrides the heuristic
    public static func run(
        _ g: DagreGraph,
        disableOptimization: Bool = false,
        customOrder: ((DagreGraph, [[String]]) -> Void)? = nil
    ) throws {
        // Check for custom order function first (matches TypeScript behavior)
        // TypeScript: if (opts && typeof opts.customOrder === 'function') { opts.customOrder(g, order); return; }
        if let customOrder = customOrder {
            let layering = InitOrder.run(g)
            customOrder(g, layering)
            return
        }

        let maxRank = GraphUtil.maxRank(g)

        // Get initial layering
        let layering = InitOrder.run(g)
        assignOrder(g, layering: layering)

        if disableOptimization {
            return
        }

        // The sweeps work on node indices: node i is ids[i], and index ids.count stands for the
        // layer graphs' root. Orders live in `order` until the best layering is applied.
        let ids = g.nodes()
        var index: [String: Int] = [:]
        index.reserveCapacity(ids.count)
        for (i, v) in ids.enumerated() {
            index[v] = i
        }
        let root = ids.count
        let parent: [Int?] = ids.map { v in g.parent(v).map { index[$0]! } ?? root } + [nil]
        var order = ids.map { g.node($0)?.order ?? 0 }
        let inEdges: [[(u: Int, weight: Int)]] = ids.map { v in
            (g.inEdges(v) ?? []).map { (u: index[$0.v]!, weight: g.edge($0.id)?.weight ?? 1) }
        }
        let outEdges: [[(u: Int, weight: Int)]] = ids.map { v in
            (g.outEdges(v) ?? []).map { (u: index[$0.w]!, weight: g.edge($0.id)?.weight ?? 1) }
        }

        // Build layer graphs for sweeping
        // downGraphs: ranks 1 to maxRank, using inEdges
        // upGraphs: ranks maxRank-1 down to 0, using outEdges
        let nodesWithRank = nodesByRank(g, ids: ids)
        let builder = IndexedLayerGraphBuilder(g, ids: ids, index: index, parent: parent)
        let downRanks = maxRank >= 1 ? Array(1...maxRank) : []
        let upRanks = maxRank >= 1 ? Array((0..<maxRank).reversed()) : []
        let downGraphs = downRanks.map { builder.build(rank: $0, nodes: nodesWithRank[$0] ?? [], neighbors: inEdges) }
        let upGraphs = upRanks.map { builder.build(rank: $0, nodes: nodesWithRank[$0] ?? [], neighbors: outEdges) }

        // Nodes of each layer in graph order, as GraphUtil.buildLayerMatrix collects them
        var layerNodes: [[Int]] = Array(repeating: [], count: max(maxRank, 0) + 1)
        for (i, v) in ids.enumerated() {
            if let rank = g.node(v)?.rank, rank >= 0 && rank < layerNodes.count {
                layerNodes[rank].append(i)
            }
        }
        var southPos = Array(repeating: -1, count: ids.count)

        // Track best solution
        var bestCC = Int.max
        var bestLayering: [[Int]] = []

        // Iterate until no improvement for 4 consecutive iterations
        var lastBest = 0
        var i = 0

        while lastBest < 4 {
            // Alternate between down-sweep and up-sweep
            // Also alternate bias (i % 4 >= 2)
            let useDownGraphs = (i % 2) == 1
            let biasRight = (i % 4) >= 2

            let layerGraphs = useDownGraphs ? downGraphs : upGraphs
            sweepLayerGraphs(layerGraphs, order: &order, parent: parent, biasRight: biasRight)

            // Rebuild layering from current order (GraphUtil.buildLayerMatrix)
            let layering = layerNodes.map { $0.sorted { order[$0] < order[$1] } }

            // Count crossings
            let cc = CrossCount.count(layering: layering, outEdges: outEdges, southPos: &southPos)

            if cc < bestCC {
                lastBest = 0
                bestCC = cc
                bestLayering = layering
            } else {
                lastBest += 1
            }

            i += 1
        }

        // Apply best solution over the orders the sweeps left
        for (i, v) in ids.enumerated() {
            g.node(v)?.order = order[i]
        }
        assignOrder(g, layering: bestLayering.map { $0.map { ids[$0] } })
    }

    /// Indices of the nodes that belong to each rank, in graph order. Compound nodes belong to
    /// every rank they span, other nodes to their own rank (see BuildLayerGraph).
    private static func nodesByRank(_ g: DagreGraph, ids: [String]) -> [Int: [Int]] {
        var nodesByRank: [Int: [Int]] = [:]
        for (i, v) in ids.enumerated() {
            guard let node = g.node(v) else { continue }

            if let minRank = node.minRank, let maxRank = node.maxRank {
                for r in minRank...maxRank {
                    nodesByRank[r, default: []].append(i)
                }
            } else {
                nodesByRank[node.rank, default: []].append(i)
            }
        }
        return nodesByRank
    }

    /// Sweeps through all layer graphs, sorting each one and updating node orders
    private static func sweepLayerGraphs(
        _ layerGraphs: [IndexedLayerGraph],
        order: inout [Int],
        parent: [Int?],
        biasRight: Bool
    ) {
        // Constraint graph tracks ordering relationships between subgraphs
        let cg = IndexedConstraintGraph(nodeCount: parent.count)

        for lg in layerGraphs {
            let sorted = SortSubgraph.sortLayerGraph(lg.root, order: order, cg: cg, biasRight: biasRight)
            for (i, v) in sorted.vs.enumerated() {
                order[v] = i
            }

            // Add subgraph constraints for next iteration
            AddSubgraphConstraints.run(parent: parent, cg: cg, vs: sorted.vs)
        }
    }

    /// Assigns order values to nodes based on layering
    private static func assignOrder(_ g: DagreGraph, layering: [[String]]) {
        for layer in layering {
            for (i, v) in layer.enumerated() {
                g.node(v)?.order = i
            }
        }
    }
}
