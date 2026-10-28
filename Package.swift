// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BiliMac", platforms: [.macOS(.v26)],
    products: [.executable(name: "BiliMac", targets: ["BiliMac"])],
    dependencies: [.package(path: "Vendor/BiliKitCore")],
    targets: [
        .target(name: "BiliMacCore", dependencies: [.product(name: "BiliModels", package: "BiliKitCore"), .product(name: "BiliNetworking", package: "BiliKitCore")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "BiliMac", dependencies: ["BiliMacCore", .product(name: "BiliPlayback", package: "BiliKitCore")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "BiliMacTests", dependencies: ["BiliMacCore", "BiliMac", .product(name: "BiliPlayback", package: "BiliKitCore")], resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
