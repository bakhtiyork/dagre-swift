// SPDX-License-Identifier: MIT
// Times SwiftDagreLayout.layout on seeded random graphs.
// Usage: DagreBench [sizes=250,500,1000] [clusters=0] [reps=3]

import SwiftDagre

struct RNG {
    var state: UInt64
    mutating func next(_ n: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(n))
    }
}

/// Mostly-forward graph with edges spanning a few ranks, ~5% back edges and labels on ~10% of
/// edges. With clusters, every third node joins one of `clusters` subgraphs.
func makeGraph(nodes n: Int, edges e: Int, clusters: Int, seed: UInt64) throws -> DagreGraph {
    var rng = RNG(state: seed)
    let g = DagreGraph(options: GraphOptions(directed: true, multigraph: true, compound: clusters > 0))
    for i in 0..<n { g.setNode("n\(i)", label: DagreNodeLabel(width: 80, height: 40)) }
    for c in 0..<clusters { g.setNode("c\(c)", label: DagreNodeLabel()) }
    if clusters > 0 {
        for i in stride(from: 0, to: n, by: 3) { try g.setParent("n\(i)", parent: "c\((i / 3) % clusters)") }
    }
    for k in 0..<e {
        let a = rng.next(n)
        var b = a + 1 + rng.next(max(1, n / 25))
        if b >= n { b = rng.next(n) }
        let back = rng.next(20) == 0
        let label = DagreEdgeLabel()
        if rng.next(10) == 0 { label.width = 40; label.height = 14 }
        try g.setEdge(back ? "n\(b)" : "n\(a)", back ? "n\(a)" : "n\(b)", label: label, name: "e\(k)")
    }
    return g
}

let args = CommandLine.arguments
let sizes = args.count > 1 ? args[1].split(separator: ",").map { Int($0)! } : [250, 500, 1000]
let clusters = args.count > 2 ? Int(args[2])! : 0
let reps = args.count > 3 ? Int(args[3])! : 3

for n in sizes {
    var best = Duration.seconds(Int64.max)
    for rep in 0..<reps {
        let g = try makeGraph(nodes: n, edges: n * 9 / 5, clusters: clusters, seed: 42 + UInt64(rep))
        best = min(best, try ContinuousClock().measure { try SwiftDagreLayout.layout(g) })
    }
    let ms = Double(best.components.seconds) * 1000 + Double(best.components.attoseconds) / 1e15
    print("nodes=\(n) edges=\(n * 9 / 5) clusters=\(clusters) best=\((ms * 10).rounded() / 10) ms")
}
