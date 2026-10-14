// SPDX-License-Identifier: MIT
// SwiftDagre Tests - Golden Layout Tests

import XCTest
@testable import SwiftDagre

/// Compares complete layout output (every node coordinate, edge point and graph size)
/// against golden files recorded from SwiftDagre 0.1.0. Performance work must keep the
/// output identical. Set `DAGRE_RECORD_GOLDEN=1` to re-record after an intentional change.
final class GoldenLayoutTests: XCTestCase {

    // MARK: - Cases

    func testSmallShapes() throws {
        let g = makeGraph()
        for (v, w) in [("a", "b"), ("a", "c"), ("b", "d"), ("c", "d"), ("d", "e"), ("a", "e"), ("x", "y")] {
            try addEdge(g, v, w)
        }
        g.setNode("lonely", label: DagreNodeLabel(width: 30, height: 30))
        try assertGolden("small-shapes", g)
    }

    func testRandomGreedy() throws {
        try assertGolden("random-200-greedy", try randomGraph(nodes: 200, edges: 360, seed: 1))
    }

    func testRandomDFSAcyclic() throws {
        let opts = LayoutOptions()
        opts.acyclicer = .dfs
        try assertGolden("random-150-dfs", try randomGraph(nodes: 150, edges: 270, seed: 2), options: opts)
    }

    func testRankDirections() throws {
        for dir in [LayoutOptions.RankDirection.leftRight, .bottomTop, .rightLeft] {
            let opts = LayoutOptions()
            opts.rankdir = dir
            try assertGolden("random-80-\(dir.rawValue)", try randomGraph(nodes: 80, edges: 140, seed: 3), options: opts)
        }
    }

    func testRankers() throws {
        for ranker in [LayoutOptions.RankingAlgorithm.tightTree, .longestPath] {
            let opts = LayoutOptions()
            opts.ranker = ranker
            try assertGolden("random-100-\(ranker.rawValue)", try randomGraph(nodes: 100, edges: 180, seed: 4), options: opts)
        }
    }

    func testAlignments() throws {
        for align in [LayoutOptions.Alignment.upLeft, .downRight] {
            let opts = LayoutOptions()
            opts.align = align
            try assertGolden("random-80-align-\(align.rawValue)", try randomGraph(nodes: 80, edges: 140, seed: 5), options: opts)
        }
    }

    func testEdgeLabelsAndWeights() throws {
        let opts = LayoutOptions()
        opts.nodesep = 30
        opts.edgesep = 10
        opts.ranksep = 70
        opts.marginx = 12
        opts.marginy = 8
        try assertGolden("labels-120", try randomGraph(nodes: 120, edges: 220, seed: 6, labelEvery: 3, varyMinlenWeight: true), options: opts)
    }

    func testSelfLoopsAndMultiEdges() throws {
        let g = try randomGraph(nodes: 60, edges: 100, seed: 7)
        for i in stride(from: 0, to: 60, by: 7) {
            try addEdge(g, "n\(i)", "n\(i)", name: "self\(i)")
            try addEdge(g, "n\(i)", "n\((i + 1) % 60)", name: "multi\(i)a")
            try addEdge(g, "n\(i)", "n\((i + 1) % 60)", name: "multi\(i)b")
        }
        try assertGolden("selfloops-multiedges-60", g)
    }

    func testClusters() throws {
        try assertGolden("clusters-120-12", try randomGraph(nodes: 120, edges: 210, seed: 8, clusters: 12))
    }

    func testNestedClustersLR() throws {
        let g = try randomGraph(nodes: 90, edges: 160, seed: 9, clusters: 9, labelEvery: 5)
        // Nest clusters c1..c8 three to a parent: c0 <- c1, c2; c3 <- c4, c5; c6 <- c7, c8.
        for c in 0..<9 where c % 3 != 0 {
            try g.setParent("c\(c)", parent: "c\(c - c % 3)")
        }
        let opts = LayoutOptions()
        opts.rankdir = .leftRight
        try assertGolden("nested-clusters-90-LR", g, options: opts)
    }

    func testDisconnectedComponents() throws {
        let g = makeGraph()
        for k in 0..<6 {
            let sub = try randomGraph(nodes: 15, edges: 22, seed: 100 + UInt64(k))
            for e in sub.edges() {
                try addEdge(g, "k\(k)\(e.v)", "k\(k)\(e.w)", name: e.name)
            }
        }
        try assertGolden("components-6x15", g)
    }

    // MARK: - Graph builders

    private struct RNG {
        var state: UInt64
        mutating func next(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(n))
        }
    }

    private func makeGraph(compound: Bool = false) -> DagreGraph {
        DagreGraph(options: GraphOptions(directed: true, multigraph: true, compound: compound))
    }

    private func addEdge(_ g: DagreGraph, _ v: String, _ w: String, name: String? = nil, label: DagreEdgeLabel = DagreEdgeLabel()) throws {
        for n in [v, w] where !g.hasNode(n) {
            g.setNode(n, label: DagreNodeLabel(width: 60 + Double(n.count * 4), height: 36))
        }
        try g.setEdge(v, w, label: label, name: name)
    }

    /// Mostly-forward random graph spanning a few ranks per edge, with ~5% back edges.
    private func randomGraph(
        nodes n: Int, edges e: Int, seed: UInt64,
        clusters: Int = 0, labelEvery: Int = 0, varyMinlenWeight: Bool = false
    ) throws -> DagreGraph {
        var rng = RNG(state: seed)
        let g = makeGraph(compound: clusters > 0)
        for i in 0..<n {
            g.setNode("n\(i)", label: DagreNodeLabel(width: Double(40 + rng.next(80)), height: Double(20 + rng.next(30))))
        }
        for c in 0..<clusters {
            g.setNode("c\(c)", label: DagreNodeLabel())
        }
        if clusters > 0 {
            // Contiguous blocks so clusters hold related nodes; every third block stays top-level.
            let block = max(1, n / (clusters * 3 / 2))
            for i in 0..<n where (i / block) % 3 != 2 {
                try g.setParent("n\(i)", parent: "c\((i / block) % clusters)")
            }
        }
        for k in 0..<e {
            let a = rng.next(n)
            var b = a + 1 + rng.next(max(1, n / 20))
            if b >= n { b = rng.next(n) }
            let back = rng.next(20) == 0
            let label = DagreEdgeLabel(
                minlen: varyMinlenWeight ? 1 + rng.next(2) : 1,
                weight: varyMinlenWeight ? 1 + rng.next(3) : 1
            )
            if labelEvery > 0, k % labelEvery == 0 {
                label.width = Double(20 + rng.next(40))
                label.height = 14
                label.labelpos = [.left, .center, .right][rng.next(3)]
            }
            try g.setEdge(back ? "n\(b)" : "n\(a)", back ? "n\(a)" : "n\(b)", label: label, name: "e\(k)")
        }
        return g
    }

    // MARK: - Golden comparison

    private static let goldenDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Golden")

    private func serialize(_ g: DagreGraph) -> String {
        var out = ""
        if let opts = g.graph() as? LayoutOptions {
            out += "graph \(opts.width) \(opts.height)\n"
        }
        for v in g.nodes() {
            guard let n = g.node(v) else { out += "node \(v) nil\n"; continue }
            out += "node \(v) \(n.x) \(n.y) \(n.width) \(n.height)\n"
        }
        for e in g.edges() {
            guard let l = g.edge(e.id) else { out += "edge \(e.v) \(e.w) \(e.name ?? "-") nil\n"; continue }
            let points = l.points.map { "\($0.x),\($0.y)" }.joined(separator: " ")
            out += "edge \(e.v) \(e.w) \(e.name ?? "-") \(l.x) \(l.y) [\(points)]\n"
        }
        return out
    }

    private func assertGolden(
        _ name: String, _ g: DagreGraph, options: LayoutOptions? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try SwiftDagreLayout.layout(g, options: options)
        let actual = serialize(g)
        let url = Self.goldenDir.appendingPathComponent("\(name).txt")

        if ProcessInfo.processInfo.environment["DAGRE_RECORD_GOLDEN"] == "1" {
            try FileManager.default.createDirectory(at: Self.goldenDir, withIntermediateDirectories: true)
            try actual.write(to: url, atomically: true, encoding: .utf8)
            return
        }

        let expected = try String(contentsOf: url, encoding: .utf8)
        guard actual != expected else { return }
        let a = actual.split(separator: "\n", omittingEmptySubsequences: false)
        let b = expected.split(separator: "\n", omittingEmptySubsequences: false)
        let firstDiff = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }
        if let (i, pair) = firstDiff {
            XCTFail("\(name): line \(i + 1) differs\n  expected: \(pair.1)\n  actual:   \(pair.0)", file: file, line: line)
        } else {
            XCTFail("\(name): line count differs (expected \(b.count), actual \(a.count))", file: file, line: line)
        }
    }
}
