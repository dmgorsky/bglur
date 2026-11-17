// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "bglur",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "bglur", targets: ["bglur"])
    ],
    targets: [
        .executableTarget(
            name: "bglur",
            path: "Sources/bglur"
        )
    ]
)
