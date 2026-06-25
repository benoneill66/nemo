// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Nemo",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Nemo",
            path: "Sources/Nemo"
        ),
        .executableTarget(
            name: "NemoMCP",
            path: "Sources/NemoMCP"
        ),
        .testTarget(
            name: "NemoTests",
            dependencies: ["Nemo"],
            path: "Tests/NemoTests"
        )
    ]
)
