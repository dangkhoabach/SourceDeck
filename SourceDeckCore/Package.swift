// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SourceDeckCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SourceDeckCore", targets: ["SourceDeckCore"])
    ],
    dependencies: [
        // The only third-party dependency, same major version
        // as KeyCellar and MediaCatch. Package.resolved is committed so
        // the reviewed revision is the one every build uses.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(name: "SourceDeckCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "SourceDeckCoreTests", dependencies: ["SourceDeckCore"]),
    ]
)
