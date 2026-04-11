// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PriestSwift",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "Priest", targets: ["Priest"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Priest",
            dependencies: [],
            path: "Sources/Priest",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "PriestTests",
            dependencies: ["Priest"],
            path: "Tests/PriestTests"
        ),
    ]
)
