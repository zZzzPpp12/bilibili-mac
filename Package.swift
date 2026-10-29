// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BiliMac", platforms: [.macOS(.v26)],
    products: [.executable(name: "BiliMac", targets: ["BiliMac"])],
    dependencies: [],
    targets: [
        .target(name: "BiliMacMedia", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "BiliMacCore", dependencies: ["BiliMacMedia"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "BiliMac", dependencies: ["BiliMacCore", "BiliMacMedia"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "BiliMacTests", dependencies: ["BiliMacCore", "BiliMac", "BiliMacMedia"], resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
