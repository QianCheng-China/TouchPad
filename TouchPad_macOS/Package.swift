// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "TouchPad",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .executable(name: "TouchPad", targets: ["TouchPad"])
    ],
    targets: [
        .executableTarget(
            name: "TouchPad",
            path: "Sources/macOSApp"
        )
    ]
)
