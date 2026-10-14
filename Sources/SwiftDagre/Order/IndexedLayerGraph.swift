// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

/// A layer graph (see `BuildLayerGraph`) in node indices, so the sweeps in `Order.run` sort without
/// hashing node IDs. Each subgraph keeps what `SortSubgraph.sortLayerGraph` reads from the layer
/// graph: its movable children in layer graph order, their in-edges, and the rank's border nodes.
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
}

/// Builds indexed layer graphs straight from the main graph, with the result
/// `BuildLayerGraph.build` would give: the rank's nodes under their parents (or the root), an edge
/// from each neighbor with the weights of parallel edges summed, and children in the order the
/// layer graph first saw them (as a node, a parent or a neighbor).
final class IndexedLayerGraphBuilder {
    private let g: DagreGraph
    private let ids: [String]
    private let index: [String: Int]
    /// Main graph parent of each node, with `root` for top-level nodes
    private let parent: [Int?]
    private let root: Int

    // Scratch, -1 outside of a build
    private var slot: [Int]
    private var memberPosition: [Int]
    private var edgePosition: [Int]

    init(_ g: DagreGraph, ids: [String], index: [String: Int], parent: [Int?]) {
        self.g = g
        self.ids = ids
        self.index = index
        self.parent = parent
        root = ids.count
        slot = Array(repeating: -1, count: ids.count)
        memberPosition = slot
        edgePosition = slot
    }

    /// Builds the layer graph of `rank` from its nodes in graph order, where `neighbors` gives the
    /// edges of the relationship (in-edge sources or out-edge targets) of every node
    func build(rank: Int, nodes: [Int], neighbors: [[(u: Int, weight: Int)]]) -> IndexedLayerGraph {
        var seen: [Int] = []
        func see(_ v: Int) {
            if slot[v] < 0 {
                slot[v] = seen.count
                seen.append(v)
            }
        }

        var members: [(v: Int, inEdges: [(u: Int, weight: Int)])] = []
        var children: [Int: [Int]] = [:]
        for v in nodes {
            see(v)
            let p = parent[v]!
            if p != root { see(p) }
            children[p, default: []].append(v)

            var inEdges: [(u: Int, weight: Int)] = []
            for (u, weight) in neighbors[v] {
                see(u)
                if edgePosition[u] >= 0 {
                    inEdges[edgePosition[u]].weight += weight
                } else {
                    edgePosition[u] = inEdges.count
                    inEdges.append((u, weight))
                }
            }
            for edge in inEdges { edgePosition[edge.u] = -1 }

            memberPosition[v] = members.count
            members.append((v, inEdges))
        }

        func subgraph(_ v: Int) -> IndexedLayerGraph.Subgraph {
            var sg = IndexedLayerGraph.Subgraph()
            var movable = (children[v] ?? []).sorted { slot[$0] < slot[$1] }

            if v != root, let node = g.node(ids[v]), node.minRank != nil,
               let bl = node.borderLeft[rank].map({ index[$0]! }),
               let br = node.borderRight[rank].map({ index[$0]! }) {
                movable = movable.filter { $0 != bl && $0 != br }
                sg.borders = (bl, br)
                if let blPred = predecessor(bl), let brPred = predecessor(br) {
                    sg.borderPredecessors = (blPred, brPred)
                }
            }

            for w in movable {
                sg.movable.append(w)
                sg.inEdges.append(members[memberPosition[w]].inEdges)
                sg.nested.append(children[w] == nil ? nil : subgraph(w))
            }
            return sg
        }

        func predecessor(_ v: Int) -> Int? {
            memberPosition[v] >= 0 ? members[memberPosition[v]].inEdges.first?.u : nil
        }

        let layerGraph = IndexedLayerGraph(root: subgraph(root))
        for v in seen { slot[v] = -1 }
        for member in members { memberPosition[member.v] = -1 }
        return layerGraph
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
            for edge in out[v] where positions[edges[edge].w] >= 0 {
                ids.append(edge)
            }
        }
        ids.sort()
        let result = ids.map { (v: positions[edges[$0].v], w: positions[edges[$0].w]) }
        for v in vs { positions[v] = -1 }
        return result
    }
}
