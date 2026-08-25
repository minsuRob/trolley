// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "trolley",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "trolley", targets: ["trolley"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2")
    ],
    targets: [
        .target(
            name: "TrolleyKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "TrolleyMCP",
            dependencies: ["TrolleyKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "trolley",
            dependencies: [
                "TrolleyKit",
                "TrolleyMCP",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TrolleyKitTests",
            dependencies: ["TrolleyKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TrolleyMCPTests",
            dependencies: ["TrolleyMCP", "TrolleyKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
