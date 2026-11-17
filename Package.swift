// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BookmarkBridge",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SyncCore"),
        .target(name: "SafariAdapter", dependencies: ["SyncCore"]),
        .target(name: "ChromeAdapter", dependencies: ["SyncCore"]),
        .executableTarget(name: "bookmarkbridge-host", dependencies: ["ChromeAdapter"]),
        .executableTarget(name: "BookmarkBridge", dependencies: ["SyncCore", "SafariAdapter", "ChromeAdapter"]),
        .testTarget(name: "SyncCoreTests", dependencies: ["SyncCore", "SafariAdapter", "ChromeAdapter"]),
    ],
    swiftLanguageModes: [.v5]
)
