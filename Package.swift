// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "touchdriver",
    platforms: [
        .macOS(.v11)
    ],
    targets: [
        .executableTarget(
            name: "touchdriver",
            path: "Sources/touchdriver"
        )
    ]
)
