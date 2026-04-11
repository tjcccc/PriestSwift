// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "priest-swift",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "PriestCore", targets: ["PriestCore"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "PriestCore",
            dependencies: [],
            path: "Sources/PriestCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "PriestCoreTests",
            dependencies: ["PriestCore"],
            path: "Tests/PriestCoreTests"
        ),
    ]
)
