// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FlyCommander",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TCCore", targets: ["TCCore"]),
        .executable(name: "FlyCommander", targets: ["FlyCommander"]),
    ],
    targets: [
        .target(name: "TCCore"),
        .executableTarget(name: "FlyCommander",
                          dependencies: ["TCCore"]),
        .testTarget(name: "TCCoreTests",
                    dependencies: ["TCCore"]),
        .testTarget(name: "FlyCommanderTests",
                    dependencies: ["FlyCommander"]),
    ]
)
