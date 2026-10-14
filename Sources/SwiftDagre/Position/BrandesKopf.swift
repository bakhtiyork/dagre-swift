// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

/// Brandes-Kopf algorithm for x-coordinate assignment
/// "Fast and Simple Horizontal Coordinate Assignment"
public enum BrandesKopf {

    /// Alignment data for vertical block formation
    public struct Alignment {
        /// Maps each node to its block root
        public var root: [String: String]
        /// Maps each node to the next node in its block
        public var align: [String: String]

        public init() {
            self.root = [:]
            self.align = [:]
        }
    }

    /// Conflict set for edges that shouldn't be aligned
    public struct Conflicts {
        private var conflicts: [String: Set<String>] = [:]

        public mutating func add(_ v: String, _ w: String) {
            let (smaller, larger) = v < w ? (v, w) : (w, v)
            conflicts[smaller, default: []].insert(larger)
        }

        public func has(_ v: String, _ w: String) -> Bool {
            let (smaller, larger) = v < w ? (v, w) : (w, v)
            return conflicts[smaller]?.contains(larger) ?? false
        }
    }

    /// The graph's nodes by index with their labels and neighbors, so the passes below don't hash
    /// node IDs
    private struct IndexedNodes {
        let ids: [String]
        let index: [String: Int]
        let labels: [DagreNodeLabel?]
        let predecessors: [[Int]]
        let successors: [[Int]]

        init(_ g: DagreGraph) {
            ids = g.nodes()
            var index: [String: Int] = [:]
            index.reserveCapacity(ids.count)
            for (i, v) in ids.enumerated() {
                index[v] = i
            }
            self.index = index
            labels = ids.map { g.node($0) }
            predecessors = ids.map { (g.predecessors($0) ?? []).map { index[$0]! } }
            successors = ids.map { (g.successors($0) ?? []).map { index[$0]! } }
        }
    }

    /// `Conflicts` on node indices
    private struct IndexedConflicts {
        private var pairs = Set<Int>()
        private let nodeCount: Int

        init(nodeCount: Int) {
            self.nodeCount = nodeCount
        }

        mutating func add(_ v: Int, _ w: Int) {
            pairs.insert(min(v, w) * nodeCount + max(v, w))
        }

        func has(_ v: Int, _ w: Int) -> Bool {
            pairs.contains(min(v, w) * nodeCount + max(v, w))
        }
    }

    /// Computes x-coordinates using the Brandes-Kopf algorithm
    /// Returns x-coordinate for each node
    /// - Throws: `GraphError.namedEdgeOnNonMultigraph` if edge operations fail
    public static func positionX(_ g: DagreGraph, nodesep: Double, edgesep: Double, align: LayoutOptions.Alignment? = nil) throws -> [String: Double] {
        let nodes = IndexedNodes(g)
        let layering = GraphUtil.buildLayerMatrix(g).map { $0.map { nodes.index[$0]! } }

        // Find type-1 and type-2 conflicts
        var conflicts = IndexedConflicts(nodeCount: nodes.ids.count)
        findType1Conflicts(nodes, layering: layering, conflicts: &conflicts)
        findType2Conflicts(nodes, layering: layering, conflicts: &conflicts)

        // Compute 4 alignments (all combinations of up/down, left/right)
        var xss: [String: [String: Double]] = [:]

        for vert in ["u", "d"] {
            let isUp = vert == "u"
            var adjustedLayering = isUp ? layering : Array(layering.reversed())

            for horiz in ["l", "r"] {
                let isLeft = horiz == "l"

                // Reverse layer order for right-biased
                if !isLeft {
                    adjustedLayering = adjustedLayering.map { Array($0.reversed()) }
                }

                // Build alignment
                let neighbors = isUp ? nodes.predecessors : nodes.successors
                let root = verticalAlignment(nodes, layering: adjustedLayering, conflicts: conflicts, neighbors: neighbors)

                // Compute x-coordinates
                let xs = horizontalCompaction(nodes, layering: adjustedLayering, root: root, reverseSep: !isLeft, nodesep: nodesep, edgesep: edgesep)

                // Flip x-coordinates for right-biased
                var xsByID: [String: Double] = [:]
                xsByID.reserveCapacity(nodes.ids.count)
                for layer in layering {
                    for v in layer {
                        xsByID[nodes.ids[v]] = isLeft ? xs[v] : -xs[v]
                    }
                }

                xss[vert + horiz] = xsByID

                // Restore layering for next iteration
                if !isLeft {
                    adjustedLayering = adjustedLayering.map { Array($0.reversed()) }
                }
            }
        }

        // Find smallest width alignment and align others to it
        let smallestWidth = findSmallestWidthAlignment(g, xss: xss)
        alignCoordinates(&xss, alignTo: smallestWidth)

        // Balance: pick median of 4 alignments (or specific one if requested)
        return balance(xss, align: align)
    }

    // MARK: - Conflict Detection

    /// Finds type-1 conflicts (non-inner segment crosses inner segment)
    private static func findType1Conflicts(_ nodes: IndexedNodes, layering: [[Int]], conflicts: inout IndexedConflicts) {
        guard layering.count > 1 else { return }

        for i in 1..<layering.count {
            let prevLayer = layering[i - 1]
            let layer = layering[i]

            var k0 = 0
            var scanPos = 0
            let prevLayerLength = prevLayer.count

            for (idx, v) in layer.enumerated() {
                // Find inner segment node (both ends are dummy)
                let w = findOtherInnerSegmentNode(nodes, v)
                let k1 = w != nil ? (nodes.labels[w!]?.order ?? prevLayerLength) : prevLayerLength

                if w != nil || idx == layer.count - 1 {
                    // Scan for conflicts
                    for scanIdx in scanPos...idx {
                        let scanNode = layer[scanIdx]
                        for u in nodes.predecessors[scanNode] {
                            let uPos = nodes.labels[u]?.order ?? 0
                            let uIsDummy = nodes.labels[u]?.dummy != nil
                            let scanIsDummy = nodes.labels[scanNode]?.dummy != nil

                            if (uPos < k0 || k1 < uPos) && !(uIsDummy && scanIsDummy) {
                                conflicts.add(u, scanNode)
                            }
                        }
                    }
                    scanPos = idx + 1
                    k0 = k1
                }
            }
        }
    }

    /// Finds type-2 conflicts (at compound node borders)
    private static func findType2Conflicts(_ nodes: IndexedNodes, layering: [[Int]], conflicts: inout IndexedConflicts) {
        guard layering.count > 1 else { return }

        // Inline scan function
        func scan(south: [Int], southPos: Int, southEnd: Int, prevNorthBorder: Int, nextNorthBorder: Int) {
            for idx in southPos..<southEnd {
                let v = south[idx]
                if nodes.labels[v]?.dummy != nil {
                    for u in nodes.predecessors[v] {
                        if let uNode = nodes.labels[u], uNode.dummy != nil {
                            if uNode.order < prevNorthBorder || uNode.order > nextNorthBorder {
                                conflicts.add(u, v)
                            }
                        }
                    }
                }
            }
        }

        for i in 1..<layering.count {
            let north = layering[i - 1]
            let south = layering[i]

            var prevNorthPos = -1
            var nextNorthPos: Int = 0
            var southPos = 0
            var lastScan: (southPos: Int, north: Int)?

            for (southLookahead, v) in south.enumerated() {
                if nodes.labels[v]?.dummy == .border {
                    let preds = nodes.predecessors[v]
                    if !preds.isEmpty {
                        nextNorthPos = nodes.labels[preds[0]]?.order ?? 0
                        scan(south: south, southPos: southPos, southEnd: southLookahead, prevNorthBorder: prevNorthPos, nextNorthBorder: nextNorthPos)
                        southPos = southLookahead
                        prevNorthPos = nextNorthPos
                    }
                }
                // Final scan - called at every iteration per TypeScript line 118. Repeating it
                // with unchanged arguments adds nothing (conflicts is a set), so skip repeats.
                if lastScan?.southPos != southPos || lastScan?.north != nextNorthPos {
                    lastScan = (southPos, nextNorthPos)
                    scan(south: south, southPos: southPos, southEnd: south.count, prevNorthBorder: nextNorthPos, nextNorthBorder: north.count)
                }
            }
        }
    }

    /// Finds the other node in an inner segment (both ends dummy)
    private static func findOtherInnerSegmentNode(_ nodes: IndexedNodes, _ v: Int) -> Int? {
        guard nodes.labels[v]?.dummy != nil else { return nil }
        return nodes.predecessors[v].first { nodes.labels[$0]?.dummy != nil }
    }

    // MARK: - Vertical Alignment

    /// Builds vertical alignment by aligning nodes with their median neighbors.
    /// Returns each node's block root, or -1 for nodes outside the layering.
    private static func verticalAlignment(
        _ nodes: IndexedNodes,
        layering: [[Int]],
        conflicts: IndexedConflicts,
        neighbors: [[Int]]
    ) -> [Int] {
        var root = Array(repeating: -1, count: nodes.ids.count)
        var align = root
        // Nodes outside the layering sort as position 0
        var pos = Array(repeating: 0, count: nodes.ids.count)

        // Initialize: each node is its own root and points to itself
        for layer in layering {
            for (order, v) in layer.enumerated() {
                root[v] = v
                align[v] = v
                pos[v] = order
            }
        }

        // Try to align each node with its median neighbor
        for layer in layering {
            var prevIdx = -1

            for v in layer {
                var neighbors = neighbors[v]
                guard !neighbors.isEmpty else { continue }

                // Sort neighbors by position
                neighbors.sort { pos[$0] < pos[$1] }

                // Get median neighbor(s)
                let mp = Double(neighbors.count - 1) / 2.0
                let lower = Int(mp.rounded(.down))
                let upper = Int(mp.rounded(.up))

                for i in lower...upper {
                    let w = neighbors[i]
                    let wPos = pos[w]

                    if align[v] == v && prevIdx < wPos && !conflicts.has(v, w) {
                        // Only align if w has been initialized (is in the layering)
                        let wRoot = root[w]
                        if wRoot >= 0 {
                            align[w] = v
                            align[v] = wRoot
                            root[v] = wRoot
                            prevIdx = wPos
                        }
                    }
                }
            }
        }

        return root
    }

    // MARK: - Horizontal Compaction

    /// Computes x-coordinates via horizontal compaction. Returns an x-coordinate per node,
    /// meaningful for nodes in the layering.
    private static func horizontalCompaction(
        _ nodes: IndexedNodes,
        layering: [[Int]],
        root: [Int],
        reverseSep: Bool,
        nodesep: Double,
        edgesep: Double
    ) -> [Double] {
        let nodeCount = nodes.ids.count
        var xs = Array(repeating: 0.0, count: nodeCount)

        // Build block graph
        let blockGraph = buildBlockGraph(nodes, layering: layering, root: root, reverseSep: reverseSep, nodesep: nodesep, edgesep: edgesep)

        // First pass: assign smallest coordinates (left to right)
        var visited = Array(repeating: false, count: nodeCount)
        var stack = blockGraph.nodes

        while let elem = stack.popLast() {
            if visited[elem] {
                // Process: set x to max of predecessors
                var x: Double = 0
                for edge in blockGraph.inEdges[elem] {
                    x = max(x, xs[blockGraph.edges[edge].u] + blockGraph.edges[edge].sep)
                }
                xs[elem] = x
            } else {
                visited[elem] = true
                stack.append(elem)
                stack.append(contentsOf: blockGraph.inEdges[elem].map { blockGraph.edges[$0].u })
            }
        }

        // Second pass: shift blocks to the right where possible
        visited = Array(repeating: false, count: nodeCount)
        stack = blockGraph.nodes
        let borderType: DagreNodeLabel.BorderType = reverseSep ? .left : .right

        while let elem = stack.popLast() {
            if visited[elem] {
                // Process: shift right if possible
                var minX = Double.infinity
                for edge in blockGraph.outEdges[elem] {
                    minX = min(minX, xs[blockGraph.edges[edge].w] - blockGraph.edges[edge].sep)
                }

                if minX != Double.infinity {
                    if let nodeLabel = nodes.labels[elem], nodeLabel.borderType != borderType {
                        xs[elem] = max(xs[elem], minX)
                    }
                }
            } else {
                visited[elem] = true
                stack.append(elem)
                stack.append(contentsOf: blockGraph.outEdges[elem].map { blockGraph.edges[$0].w })
            }
        }

        // Assign x to all nodes based on their root
        for layer in layering {
            for v in layer {
                xs[v] = xs[root[v]]
            }
        }

        return xs
    }

    /// Graph of block roots where edges represent separation constraints. Nodes, and each node's
    /// in- and out-edges, are in insertion order.
    private struct BlockGraph {
        var nodes: [Int] = []
        var edges: [(u: Int, w: Int, sep: Double)] = []
        var inEdges: [[Int]]
        var outEdges: [[Int]]
    }

    /// Builds a block graph where edges represent separation constraints
    private static func buildBlockGraph(
        _ nodes: IndexedNodes,
        layering: [[Int]],
        root: [Int],
        reverseSep: Bool,
        nodesep: Double,
        edgesep: Double
    ) -> BlockGraph {
        let nodeCount = nodes.ids.count
        var blockGraph = BlockGraph(inEdges: Array(repeating: [], count: nodeCount),
                                    outEdges: Array(repeating: [], count: nodeCount))
        var hasNode = Array(repeating: false, count: nodeCount)
        var edgeIndex: [Int: Int] = [:]

        for layer in layering {
            var prev: Int?
            for v in layer {
                let vRoot = root[v]
                if !hasNode[vRoot] {
                    hasNode[vRoot] = true
                    blockGraph.nodes.append(vRoot)
                }

                if let u = prev {
                    let uRoot = root[u]
                    let sep = calculateSeparation(v: nodes.labels[v], u: nodes.labels[u], reverseSep: reverseSep, nodesep: nodesep, edgesep: edgesep)
                    if let edge = edgeIndex[uRoot * nodeCount + vRoot] {
                        blockGraph.edges[edge].sep = max(sep, blockGraph.edges[edge].sep)
                    } else {
                        let edge = blockGraph.edges.count
                        edgeIndex[uRoot * nodeCount + vRoot] = edge
                        blockGraph.edges.append((uRoot, vRoot, max(sep, 0)))
                        blockGraph.outEdges[uRoot].append(edge)
                        blockGraph.inEdges[vRoot].append(edge)
                    }
                }

                prev = v
            }
        }

        return blockGraph
    }

    /// Calculates required separation between two adjacent nodes
    /// Matches TypeScript sep(g, v, w) function at bk.js lines 384-419
    /// Called with calculateSeparation(g, v: currentNode, u: previousNode)
    /// TypeScript: sepFn(g, v, u) where v is current (right), u is previous (left)
    private static func calculateSeparation(
        v vLabel: DagreNodeLabel?,
        u uLabel: DagreNodeLabel?,
        reverseSep: Bool,
        nodesep: Double,
        edgesep: Double
    ) -> Double {
        guard let vLabel = vLabel, let uLabel = uLabel else { return 0 }

        var sum: Double = 0
        var delta: Double = 0

        // First parameter (v) - matches TypeScript vLabel processing
        sum += vLabel.width / 2
        if let labelpos = vLabel.labelpos {
            switch labelpos {
            case .left: delta = -vLabel.width / 2
            case .right: delta = vLabel.width / 2
            case .center: break
            }
        }
        if delta != 0 {
            sum += reverseSep ? delta : -delta
        }
        delta = 0

        // Separation (depends on whether nodes are dummies)
        sum += (vLabel.dummy != nil ? edgesep : nodesep) / 2
        sum += (uLabel.dummy != nil ? edgesep : nodesep) / 2

        // Second parameter (u) - matches TypeScript wLabel processing
        sum += uLabel.width / 2
        if let labelpos = uLabel.labelpos {
            switch labelpos {
            case .left: delta = uLabel.width / 2
            case .right: delta = -uLabel.width / 2
            case .center: break
            }
        }
        if delta != 0 {
            sum += reverseSep ? delta : -delta
        }

        return sum
    }

    // MARK: - Alignment and Balancing

    /// Finds the alignment with smallest total width
    private static func findSmallestWidthAlignment(_ g: DagreGraph, xss: [String: [String: Double]]) -> [String: Double] {
        var minWidth = Double.infinity
        var result: [String: Double] = [:]

        for (_, xs) in xss {
            var maxX = -Double.infinity
            var minX = Double.infinity

            for (v, x) in xs {
                let halfWidth = (g.node(v)?.width ?? 0) / 2
                maxX = max(maxX, x + halfWidth)
                minX = min(minX, x - halfWidth)
            }

            let width = maxX - minX
            if width < minWidth {
                minWidth = width
                result = xs
            }
        }

        return result
    }

    /// Aligns all coordinate sets to the smallest width alignment
    private static func alignCoordinates(_ xss: inout [String: [String: Double]], alignTo: [String: Double]) {
        guard !alignTo.isEmpty else { return }

        let alignToMin = alignTo.values.min() ?? 0
        let alignToMax = alignTo.values.max() ?? 0

        for vert in ["u", "d"] {
            for horiz in ["l", "r"] {
                let key = vert + horiz
                guard var xs = xss[key], xs != alignTo else { continue }

                let xsMin = xs.values.min() ?? 0
                let xsMax = xs.values.max() ?? 0

                let delta: Double
                if horiz == "l" {
                    delta = alignToMin - xsMin
                } else {
                    delta = alignToMax - xsMax
                }

                if delta != 0 {
                    xs = xs.mapValues { $0 + delta }
                    xss[key] = xs
                }
            }
        }
    }

    /// Balances x-coordinates by taking median of 4 alignments
    private static func balance(_ xss: [String: [String: Double]], align: LayoutOptions.Alignment?) -> [String: Double] {
        guard let ul = xss["ul"] else { return [:] }

        var result: [String: Double] = [:]

        for v in ul.keys {
            if let specificAlign = align {
                // Use specific alignment
                let key = specificAlign.rawValue.lowercased()
                result[v] = xss[key]?[v] ?? 0
            } else {
                // Take median of 4 values
                var values: [Double] = []
                for (_, xs) in xss {
                    if let x = xs[v] {
                        values.append(x)
                    }
                }
                values.sort()

                // Median of 4 values: average of 2 middle values
                if values.count >= 4 {
                    result[v] = (values[1] + values[2]) / 2
                } else if !values.isEmpty {
                    result[v] = values[values.count / 2]
                }
            }
        }

        return result
    }
}
