// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DKBSourceControlCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DKBSourceControlCore", targets: ["DKBSourceControlCore"])
    ],
    dependencies: [
        // The only third-party dependency (plan §3.2 D11), same major version
        // as DKB Secret and DKB Downloader. Package.resolved is committed so
        // the reviewed revision is the one every build uses.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(name: "DKBSourceControlCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "DKBSourceControlCoreTests", dependencies: ["DKBSourceControlCore"]),
    ]
)
