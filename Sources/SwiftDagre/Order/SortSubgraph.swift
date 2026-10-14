// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

/// Sorts nodes within a subgraph using barycenter heuristic
public enum SortSubgraph {

    /// Result of subgraph sorting
    public struct Result {
        public var vs: [String]
        public var barycenter: Double?
        public var weight: Int

        public init(vs: [String] = [], barycenter: Double? = nil, weight: Int = 0) {
            self.vs = vs
            self.barycenter = barycenter
            self.weight = weight
        }
    }

    /// Entry after resolve conflicts - has vs array instead of single v
    /// Matches TypeScript return type from resolve-conflicts.js
    struct ResolvedEntry<V> {
        var vs: [V]
        var i: Int
        var barycenter: Double?
        var weight: Int
    }

    /// Sorts a layer graph recursively from the given root node
    /// This version works with layer graphs (BuildLayerGraph.LayerNodeLabel)
    public static func sortLayerGraph(
        _ g: Graph<BuildLayerGraph.LayerNodeLabel, BuildLayerGraph.LayerEdgeLabel>,
        v: String,
        cg: Graph<Void, Void>,
        biasRight: Bool
    ) -> Result {
        // Get movable children (exclude border nodes)
        var movable = g.children(v) ?? []
        let nodeLabel = g.node(v)

        // In layer graphs, borderLeft/borderRight are single node IDs (for this rank)
        let bl = nodeLabel?.borderLeft
        let br = nodeLabel?.borderRight

        if let bl = bl, let br = br {
            movable = movable.filter { $0 != bl && $0 != br }
        }

        // Calculate barycenters for movable nodes (with original indices)
        var entries = calculateLayerBarycenters(g, movable: movable)
        var subgraphs: [String: Result] = [:]

        // Recursively sort child subgraphs
        for i in 0..<entries.count {
            let entryV = entries[i].v
            if let children = g.children(entryV), !children.isEmpty {
                let subgraphResult = sortLayerGraph(g, v: entryV, cg: cg, biasRight: biasRight)
                subgraphs[entryV] = subgraphResult

                if subgraphResult.barycenter != nil {
                    mergeBarycenters(&entries[i], other: subgraphResult)
                }
            }
        }

        // Resolve conflicts using constraint graph
        let resolved = resolveConflicts(entries, cg: cg)

        // Sort entries by barycenter
        let sorted = sortEntries(resolved, biasRight: biasRight)

        // Expand subgraph results
        let expandedVs = sorted.flatMap { v -> [String] in
            if let subResult = subgraphs[v] {
                return subResult.vs
            }
            return [v]
        }

        // Build result with borders
        var result = Result(vs: expandedVs)

        if let bl = bl, let br = br {
            result.vs = [bl] + result.vs + [br]

            // Update barycenter to include border nodes
            if let preds = g.predecessors(bl), !preds.isEmpty,
               let blPred = g.node(preds[0]),
               let brPreds = g.predecessors(br), !brPreds.isEmpty,
               let brPred = g.node(brPreds[0]) {

                if result.barycenter == nil {
                    result.barycenter = 0
                    result.weight = 0
                }

                let bc = result.barycenter ?? 0
                let weight = result.weight
                let blOrder = blPred.order
                let brOrder = brPred.order

                result.barycenter = (bc * Double(weight) + Double(blOrder + brOrder)) / Double(weight + 2)
                result.weight = weight + 2
            }
        }

        // Calculate final barycenter from resolved entries if not set
        if result.barycenter == nil {
            var totalSum: Double = 0
            var totalWeight: Int = 0
            for entry in resolved {
                if let bc = entry.barycenter {
                    totalSum += bc * Double(entry.weight)
                    totalWeight += entry.weight
                }
            }
            if totalWeight > 0 {
                result.barycenter = totalSum / Double(totalWeight)
                result.weight = totalWeight
            }
        }

        return result
    }

    /// `sortLayerGraph` on an indexed layer graph, reading node orders from `order`.
    /// Entries are identified by their position among the subgraph's movable nodes.
    static func sortLayerGraph(
        _ sg: IndexedLayerGraph.Subgraph,
        order: [Int],
        cg: IndexedConstraintGraph,
        biasRight: Bool
    ) -> (vs: [Int], barycenter: Double?, weight: Int) {
        // Calculate barycenters for movable nodes
        var entries: [(v: Int, barycenter: Double?, weight: Int)] = []
        entries.reserveCapacity(sg.movable.count)
        for (i, inEdges) in sg.inEdges.enumerated() {
            var sum: Double = 0
            var weight: Int = 0
            for edge in inEdges {
                sum += Double(edge.weight * order[edge.u])
                weight += edge.weight
            }
            entries.append(weight > 0 ? (i, sum / Double(weight), weight) : (i, nil, 0))
        }

        // Recursively sort child subgraphs
        var subgraphs: [(vs: [Int], barycenter: Double?, weight: Int)?] = Array(repeating: nil, count: entries.count)
        for i in 0..<entries.count {
            if let nested = sg.nested[i] {
                let subgraphResult = sortLayerGraph(nested, order: order, cg: cg, biasRight: biasRight)
                subgraphs[i] = subgraphResult

                if subgraphResult.barycenter != nil {
                    var entry = entries[i]
                    mergeBarycenters(&entry.barycenter, &entry.weight,
                                     otherBarycenter: subgraphResult.barycenter, otherWeight: subgraphResult.weight)
                    entries[i] = entry
                }
            }
        }

        // Resolve conflicts using constraint graph, then sort entries by barycenter
        let resolved = resolveConflicts(entries, constraints: cg.constraints(among: sg.movable))
        let sorted = sortEntries(resolved, biasRight: biasRight)

        // Expand subgraph results
        var vs: [Int] = []
        vs.reserveCapacity(sorted.count)
        for i in sorted {
            if let subResult = subgraphs[i] {
                vs += subResult.vs
            } else {
                vs.append(sg.movable[i])
            }
        }

        var barycenter: Double?
        var weight = 0

        // Add border nodes; their predecessors give the first barycenter (none is set yet)
        if let borders = sg.borders {
            vs = [borders.left] + vs + [borders.right]
            if let preds = sg.borderPredecessors {
                barycenter = Double(order[preds.left] + order[preds.right]) / 2
                weight = 2
            }
        }

        // Calculate final barycenter from resolved entries if not set
        if barycenter == nil {
            var totalSum: Double = 0
            var totalWeight: Int = 0
            for entry in resolved {
                if let bc = entry.barycenter {
                    totalSum += bc * Double(entry.weight)
                    totalWeight += entry.weight
                }
            }
            if totalWeight > 0 {
                barycenter = totalSum / Double(totalWeight)
                weight = totalWeight
            }
        }

        return (vs, barycenter, weight)
    }

    /// Calculates barycenters for nodes in a layer graph
    /// Includes original index (i) for each entry
    private static func calculateLayerBarycenters(
        _ g: Graph<BuildLayerGraph.LayerNodeLabel, BuildLayerGraph.LayerEdgeLabel>,
        movable: [String]
    ) -> [Barycenter.Entry] {
        return movable.enumerated().map { (index, v) in
            guard let inEdges = g.inEdges(v), !inEdges.isEmpty else {
                return Barycenter.Entry(v: v, i: index)
            }

            var sum: Double = 0
            var weight: Int = 0

            for edge in inEdges {
                let neighbor = edge.v
                guard let neighborLabel = g.node(neighbor) else { continue }
                let edgeWeight = g.edge(edge.id)?.weight ?? 1

                sum += Double(edgeWeight * neighborLabel.order)
                weight += edgeWeight
            }

            if weight > 0 {
                return Barycenter.Entry(v: v, barycenter: sum / Double(weight), weight: weight, i: index)
            } else {
                return Barycenter.Entry(v: v, i: index)
            }
        }
    }

    /// Merges barycenter from a subgraph result into an entry
    private static func mergeBarycenters(_ entry: inout Barycenter.Entry, other: Result) {
        mergeBarycenters(&entry.barycenter, &entry.weight, otherBarycenter: other.barycenter, otherWeight: other.weight)
    }

    /// Merges a subgraph's barycenter and weight into an entry's
    static func mergeBarycenters(_ barycenter: inout Double?, _ weight: inout Int, otherBarycenter: Double?, otherWeight: Int) {
        if let entryBC = barycenter, let otherBC = otherBarycenter {
            barycenter = (entryBC * Double(weight) + otherBC * Double(otherWeight)) /
                         Double(weight + otherWeight)
            weight += otherWeight
        } else if let otherBC = otherBarycenter {
            barycenter = otherBC
            weight = otherWeight
        }
    }

    // MARK: - Resolve Conflicts (resolve-conflicts.js)

    /// Resolves conflicts using constraint graph
    /// Matches TypeScript resolve-conflicts.js
    ///
    /// Given a list of entries of the form {v, barycenter, weight} and a constraint graph,
    /// this function resolves any conflicts between the constraint graph and the barycenters.
    /// If the barycenters for an entry would violate a constraint in the constraint graph
    /// then we coalesce the nodes in the conflict into a new node that respects the constraint
    /// and aggregates barycenter and weight information.
    ///
    /// Returns a new list of entries of the form {vs, i, barycenter, weight}. The list
    /// `vs` may either be a singleton or it may be an aggregation of nodes ordered such
    /// that they do not violate constraints from the constraint graph.
    private static func resolveConflicts(_ entries: [Barycenter.Entry], cg: Graph<Void, Void>) -> [ResolvedEntry<String>] {
        var positions: [String: Int] = [:]
        for (i, entry) in entries.enumerated() {
            positions[entry.v] = i
        }
        let constraints = cg.edges(within: positions).map { (v: positions[$0.v]!, w: positions[$0.w]!) }
        return resolveConflicts(entries.map { (v: $0.v, barycenter: $0.barycenter, weight: $0.weight) }, constraints: constraints)
    }

    /// Resolves conflicts between entries and constraints given as pairs of entry positions,
    /// in constraint graph edge order. Sources are taken in entry order, as dagre.js does.
    static func resolveConflicts<V>(
        _ entries: [(v: V, barycenter: Double?, weight: Int)],
        constraints: [(v: Int, w: Int)]
    ) -> [ResolvedEntry<V>] {
        var mappedEntries = entries.enumerated().map { (i, entry) in
            ResolvedEntry(vs: [entry.v], i: i, barycenter: entry.barycenter, weight: entry.weight)
        }

        // Without constraints every entry is a source, taken from the end, and nothing merges
        if constraints.isEmpty {
            return mappedEntries.reversed()
        }

        // Build the constraint graph relationships, by entry position
        var indegree = Array(repeating: 0, count: entries.count)
        var ins = Array(repeating: [Int](), count: entries.count)
        var outs = Array(repeating: [Int](), count: entries.count)
        var merged = Array(repeating: false, count: entries.count)
        for constraint in constraints {
            indegree[constraint.w] += 1
            outs[constraint.v].append(constraint.w)
        }

        // Find sources (entries with no incoming constraints)
        var sourceSet = mappedEntries.indices.filter { indegree[$0] == 0 }

        // Process in topological order
        var result: [Int] = []

        while let v = sourceSet.popLast() {
            result.append(v)

            // Process incoming entries (reversed to match TypeScript)
            for u in ins[v].reversed() where !merged[u] {
                let uEntry = mappedEntries[u]
                let vBC = mappedEntries[v].barycenter

                // Merge if no barycenter or if constraint is violated (uEntry.bc >= vEntry.bc)
                if uEntry.barycenter == nil || vBC == nil || uEntry.barycenter! >= vBC! {
                    mergeEntries(target: &mappedEntries[v], source: uEntry)
                    merged[u] = true
                }
            }

            // Process outgoing entries
            for w in outs[v] {
                ins[w].append(v)
                indegree[w] -= 1
                if indegree[w] == 0 {
                    sourceSet.append(w)
                }
            }
        }

        // Filter out merged entries
        return result.filter { !merged[$0] }.map { mappedEntries[$0] }
    }

    /// Merges source entry into target entry
    /// Matches TypeScript mergeEntries in resolve-conflicts.js
    private static func mergeEntries<V>(target: inout ResolvedEntry<V>, source: ResolvedEntry<V>) {
        var sum: Double = 0
        var weight: Int = 0

        if target.weight > 0, let bc = target.barycenter {
            sum += bc * Double(target.weight)
            weight += target.weight
        }

        if source.weight > 0, let bc = source.barycenter {
            sum += bc * Double(source.weight)
            weight += source.weight
        }

        // source.vs comes first (prepended) - matches TypeScript: target.vs = source.vs.concat(target.vs)
        target.vs = source.vs + target.vs
        target.barycenter = weight > 0 ? sum / Double(weight) : nil
        target.weight = weight
        target.i = min(source.i, target.i)
    }

    // MARK: - Sort (sort.js)

    /// Sorts entries by barycenter with bias for tie-breaking
    /// Matches TypeScript sort.js algorithm with consumeUnsortable pattern
    static func sortEntries<V>(_ entries: [ResolvedEntry<V>], biasRight: Bool) -> [V] {
        // Partition into those with and without barycenters
        var sortable: [ResolvedEntry<V>] = []
        var unsortable: [ResolvedEntry<V>] = []

        for entry in entries {
            if entry.barycenter != nil {
                sortable.append(entry)
            } else {
                unsortable.append(entry)
            }
        }

        // Sort unsortable by descending original index (b.i - a.i)
        unsortable.sort { $0.i > $1.i }

        // Sort sortable by barycenter with bias tie-breaker
        sortable.sort { a, b in
            let aBC = a.barycenter ?? 0
            let bBC = b.barycenter ?? 0

            if aBC < bBC {
                return true
            } else if aBC > bBC {
                return false
            }
            // Tie-breaker: by original index
            // If !biasRight: a.i - b.i (ascending)
            // If biasRight: b.i - a.i (descending)
            return biasRight ? a.i > b.i : a.i < b.i
        }

        // Merge sortable and unsortable using consumeUnsortable pattern
        var vs: [[V]] = []
        var vsIndex = 0

        // Consume unsortable entries that should come before first sortable
        vsIndex = consumeUnsortable(&vs, &unsortable, vsIndex)

        // Process each sortable entry
        for entry in sortable {
            vsIndex += entry.vs.count
            vs.append(entry.vs)
            vsIndex = consumeUnsortable(&vs, &unsortable, vsIndex)
        }

        // Flatten result
        return vs.flatMap { $0 }
    }

    /// Consumes unsortable entries that should be inserted at the current position
    /// Matches TypeScript consumeUnsortable function in sort.js
    private static func consumeUnsortable<V>(_ vs: inout [[V]], _ unsortable: inout [ResolvedEntry<V>], _ index: Int) -> Int {
        var currentIndex = index
        while let last = unsortable.last, last.i <= currentIndex {
            unsortable.removeLast()
            vs.append(last.vs)
            currentIndex += 1
        }
        return currentIndex
    }

    // MARK: - Original DagreGraph version (kept for compatibility)

    /// Sorts a subgraph and its children recursively
    /// Uses barycenter heuristic with bias to break ties
    public static func sort(
        _ g: DagreGraph,
        v: String,
        biasRight: Bool
    ) -> Result {
        // Get movable children (exclude border nodes)
        var movable = g.children(v) ?? []
        let nodeLabel = g.node(v)

        // Get the last (highest rank) border nodes from the dictionaries
        let borderLeftDict = nodeLabel?.borderLeft ?? [:]
        let borderRightDict = nodeLabel?.borderRight ?? [:]
        let maxRank = borderLeftDict.keys.max()
        let bl = maxRank.flatMap { borderLeftDict[$0] }
        let br = maxRank.flatMap { borderRightDict[$0] }

        if let bl = bl, let br = br {
            movable = movable.filter { $0 != bl && $0 != br }
        }

        // Calculate barycenters (with original indices)
        var entries = Barycenter.calculate(g, movable: movable)
        // Add original indices
        for i in 0..<entries.count {
            entries[i].i = i
        }

        var subgraphs: [String: Result] = [:]

        // Recursively sort child subgraphs
        for i in 0..<entries.count {
            let entryV = entries[i].v
            if let children = g.children(entryV), !children.isEmpty {
                let subgraphResult = sort(g, v: entryV, biasRight: biasRight)
                subgraphs[entryV] = subgraphResult

                if let subBC = subgraphResult.barycenter {
                    Barycenter.merge(&entries[i], with: Barycenter.Entry(
                        v: entryV,
                        barycenter: subBC,
                        weight: subgraphResult.weight
                    ))
                }
            }
        }

        // Resolve conflicts (using empty constraint graph since this is the DagreGraph version)
        let cg = Graph<Void, Void>()
        let resolved = resolveConflicts(entries, cg: cg)

        // Sort entries by barycenter
        let sorted = sortEntries(resolved, biasRight: biasRight)

        // Expand subgraph results
        let expandedVs = sorted.flatMap { v -> [String] in
            if let subResult = subgraphs[v] {
                return subResult.vs
            }
            return [v]
        }

        // Build result with borders
        var result = Result(vs: expandedVs)

        if let bl = bl, let br = br {
            result.vs = [bl] + result.vs + [br]

            // Update barycenter to include border nodes
            if let preds = g.predecessors(bl), !preds.isEmpty,
               let blPred = g.node(preds[0]),
               let brPreds = g.predecessors(br), !brPreds.isEmpty,
               let brPred = g.node(brPreds[0]) {

                let bc = result.barycenter ?? 0
                let weight = result.weight
                let blOrder = blPred.order
                let brOrder = brPred.order

                result.barycenter = (bc * Double(weight) + Double(blOrder + brOrder)) / Double(weight + 2)
                result.weight = weight + 2
            }
        }

        // Calculate final barycenter from entries
        if result.barycenter == nil {
            var totalSum: Double = 0
            var totalWeight: Int = 0
            for entry in resolved {
                if let bc = entry.barycenter {
                    totalSum += bc * Double(entry.weight)
                    totalWeight += entry.weight
                }
            }
            if totalWeight > 0 {
                result.barycenter = totalSum / Double(totalWeight)
                result.weight = totalWeight
            }
        }

        return result
    }
}
