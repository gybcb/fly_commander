// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FlyCommander",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TCCore", targets: ["TCCore"]),
        .executable(name: "FlyCommander", targets: ["FlyCommander"]),
    ],
    dependencies: [
        .package(url: "https://github.com/GitSwiftHQ/Traversio.git", from: "1.0.7"),
    ],
    targets: [
        .target(name: "TCCore"),
        .executableTarget(name: "FlyCommander",
                          dependencies: ["TCCore",
                                         .product(name: "Traversio", package: "Traversio")]),
        .testTarget(name: "TCCoreTests",
                    dependencies: ["TCCore"]),
        .testTarget(name: "FlyCommanderTests",
                    dependencies: ["FlyCommander",
                                   .product(name: "Traversio", package: "Traversio")]),
    ]
)
