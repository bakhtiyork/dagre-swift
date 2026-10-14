// swift-tools-version: 5.9
// Layout benchmark, kept out of the main package so consumers never build it.
// Run: xcrun swift run -c release --package-path Benchmarks DagreBench 250,500,1000 [clusters] [reps]
import PackageDescription

let package = Package(
    name: "DagreBench",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "..")],
    targets: [
        .executableTarget(name: "DagreBench", dependencies: [.product(name: "SwiftDagre", package: "dagre-swift")]),
    ]
)
