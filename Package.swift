// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RocketChatSDK",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "RocketChatSDK", targets: ["RocketChatSDK"]),
        .executable(name: "rc-cli", targets: ["rc-cli"]),
        .executable(name: "RocketNative", targets: ["RocketNative"]),
    ],
    targets: [
        .target(
            name: "RocketChatSDK",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "rc-cli",
            dependencies: ["RocketChatSDK"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "RocketNative",
            dependencies: ["RocketChatSDK"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RocketChatSDKTests",
            dependencies: ["RocketChatSDK"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RocketNativeTests",
            dependencies: ["RocketNative"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
