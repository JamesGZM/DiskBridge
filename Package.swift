// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DiskBridge",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DiskBridge", targets: ["DiskBridge"])],
    targets: [
        .executableTarget(name: "DiskBridge"),
        .testTarget(name: "DiskBridgeTests", dependencies: ["DiskBridge"])
    ],
    swiftLanguageVersions: [.v5]
)
