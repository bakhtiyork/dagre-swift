// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

/// A layer graph (see `BuildLayerGraph`) compiled once per `Order.run` into node indices, so the
/// sweeps sort without hashing node IDs. Each subgraph keeps what `SortSubgraph.sortLayerGraph`
/// reads from the layer graph: its movable children in layer graph order, their in-edges, and
/// the rank's border nodes.
struct IndexedLayerGraph {
    struct Subgraph {
        /// Children other than the border nodes, in layer graph insertion order
        var movable: [Int] = []
        /// For each movable node: its in-edges in the layer graph as (source, weight)
        var inEdges: [[(u: Int, weight: Int)]] = []
        /// For each movable node: its own subgraph, if it has children in this layer
        var nested: [Subgraph?] = []
        var borders: (left: Int, right: Int)?
        /// First predecessor of each border node, when both have one
        var borderPredecessors: (left: Int, right: Int)?
    }

    let root: Subgraph

    init(_ lg: Graph<BuildLayerGraph.LayerNodeLabel, BuildLayerGraph.LayerEdgeLabel>, root: String, index: [String: Int]) {
        self.root = Self.subgraph(lg, root, index)
    }

    private static func subgraph(
        _ lg: Graph<BuildLayerGraph.LayerNodeLabel, BuildLayerGraph.LayerEdgeLabel>,
        _ v: String,
        _ index: [String: Int]
    ) -> Subgraph {
        var sg = Subgraph()
        var movable = lg.children(v) ?? []
        let label = lg.node(v)

        if let bl = label?.borderLeft, let br = label?.borderRight {
            movable = movable.filter { $0 != bl && $0 != br }
            sg.borders = (index[bl]!, index[br]!)
            if let blPred = lg.predecessors(bl)?.first, let brPred = lg.predecessors(br)?.first {
                sg.borderPredecessors = (index[blPred]!, index[brPred]!)
            }
        }

        for w in movable {
            sg.movable.append(index[w]!)
            sg.inEdges.append((lg.inEdges(w) ?? []).map { (u: index[$0.v]!, weight: lg.edge($0.id)?.weight ?? 1) })
            let hasChildren = !(lg.children(w) ?? []).isEmpty
            sg.nested.append(hasChildren ? subgraph(lg, w, index) : nil)
        }
        return sg
    }
}

/// The constraint graph of one `Order` sweep, on node indices. Like the `Graph<Void, Void>` it
/// replaces, it keeps every added edge, repeats included, in insertion order.
final class IndexedConstraintGraph {
    private var edges: [(v: Int, w: Int)] = []
    private var out: [[Int]]
    /// Scratch: position of each node among the entries being resolved, or -1
    private var positions: [Int]

    init(nodeCount: Int) {
        out = Array(repeating: [], count: nodeCount)
        positions = Array(repeating: -1, count: nodeCount)
    }

    func setEdge(_ v: Int, _ w: Int) {
        out[v].append(edges.count)
        edges.append((v, w))
    }

    /// Edges between nodes of `vs`, in insertion order, as pairs of positions in `vs`
    func constraints(among vs: [Int]) -> [(v: Int, w: Int)] {
        if edges.isEmpty { return [] }

        for (i, v) in vs.enumerated() { positions[v] = i }
        var ids: [Int] = []
        for v in vs {
            ids += out[v].filter { positions[edges[$0].w] >= 0 }
        }
        ids.sort()
        let result = ids.map { (v: positions[edges[$0].v], w: positions[edges[$0].w]) }
        for v in vs { positions[v] = -1 }
        return result
    }
}
