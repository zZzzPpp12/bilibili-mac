// swift-tools-version: 6.2
import PackageDescription

// Bridge-only distribution: no AVPlayerEngine or macOS 27 loudness processing.
let package = Package(name: "BiliKitCore", platforms: [.macOS(.v26)],
    products: ["BiliModels", "BiliNetworking", "BiliPlayback"].map { .library(name: $0, targets: [$0]) },
    targets: [
        .target(name: "BiliModels"),
        .target(name: "BiliNetworking"),
        .target(name: "BiliApplication", dependencies: ["BiliModels"]),
        .target(name: "BiliPlayback", dependencies: ["BiliModels", "BiliNetworking", "BiliApplication"])
    ])
