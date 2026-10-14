// SPDX-License-Identifier: MIT
// SwiftDagre Tests - Deep Graph Tests

import XCTest
@testable import SwiftDagre

/// Layouts of graphs whose longest chain is far deeper than a small thread stack could hold
/// in recursive form. Swift-concurrency cooperative threads have a 512 KB stack, so each
/// layout here runs on a thread of that size.
final class DeepGraphTests: XCTestCase {

    // MARK: - Helpers

    private final class Outcome: @unchecked Sendable {
        var error: Error?
    }

    /// Runs `body` on a thread with a 512 KB stack and waits for it to finish.
    private func runOnSmallStack(_ body: @escaping @Sendable () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            do { try body() } catch { outcome.error = error }
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        done.wait()
        XCTAssertNil(outcome.error, file: file, line: line)
    }

    private func makeChain(_ count: Int, closeCycle: Bool = false) throws -> DagreGraph {
        let g = DagreGraph(options: GraphOptions(directed: true, multigraph: true, compound: false))
        for i in 0..<count { g.setNode("n\(i)", label: DagreNodeLabel(width: 50, height: 30)) }
        for i in 1..<count { try g.setEdge("n\(i - 1)", "n\(i)", label: DagreEdgeLabel()) }
        if closeCycle { try g.setEdge("n\(count - 1)", "n0", label: DagreEdgeLabel()) }
        return g
    }

    /// Asserts every node has a finite position and that ranks increase along the chain.
    private func assertChainLaidOut(_ g: DagreGraph, count: Int, file: StaticString = #filePath, line: UInt = #line) {
        var previousY = -Double.infinity
        for i in 0..<count {
            guard let label = g.node("n\(i)") else { return XCTFail("n\(i) missing", file: file, line: line) }
            XCTAssertTrue(label.x.isFinite && label.y.isFinite, "n\(i) not finite", file: file, line: line)
            XCTAssertGreaterThan(label.y, previousY, "n\(i) is not below its predecessor", file: file, line: line)
            previousY = label.y
        }
    }

    // MARK: - Tests

    func testSimpleChain() {
        let count = 5_000
        runOnSmallStack { [self] in
            let g = try makeChain(count)
            try SwiftDagreLayout.layout(g)
            assertChainLaidOut(g, count: count)
        }
    }

    func testChainInsideCluster() {
        let count = 3_000
        runOnSmallStack { [self] in
            let g = DagreGraph(options: GraphOptions(directed: true, multigraph: true, compound: true))
            g.setNode("cluster", label: DagreNodeLabel())
            for i in 0..<count {
                g.setNode("n\(i)", label: DagreNodeLabel(width: 50, height: 30))
                try g.setParent("n\(i)", parent: "cluster")
            }
            for i in 1..<count { try g.setEdge("n\(i - 1)", "n\(i)", label: DagreEdgeLabel()) }
            try SwiftDagreLayout.layout(g)
            assertChainLaidOut(g, count: count)
            let cluster = try XCTUnwrap(g.node("cluster"))
            XCTAssertTrue(cluster.x.isFinite && cluster.y.isFinite && cluster.height > 0)
        }
    }

    func testLongCycleGreedyAcyclicer() {
        runLongCycle(acyclicer: .greedy)
    }

    func testLongCycleDfsAcyclicer() {
        runLongCycle(acyclicer: .dfs)
    }

    private func runLongCycle(acyclicer: LayoutOptions.AcyclicAlgorithm) {
        let count = 3_000
        runOnSmallStack { [self] in
            let g = try makeChain(count, closeCycle: true)
            let options = LayoutOptions()
            options.acyclicer = acyclicer
            try SwiftDagreLayout.layout(g, options: options)
            assertChainLaidOut(g, count: count)
        }
    }

    func testLongestPathRanker() {
        runWithRanker(.longestPath)
    }

    func testTightTreeRanker() {
        runWithRanker(.tightTree)
    }

    private func runWithRanker(_ ranker: LayoutOptions.RankingAlgorithm) {
        let count = 3_000
        runOnSmallStack { [self] in
            let g = try makeChain(count)
            let options = LayoutOptions()
            options.ranker = ranker
            try SwiftDagreLayout.layout(g, options: options)
            assertChainLaidOut(g, count: count)
        }
    }
}
