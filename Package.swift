// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "trolley",
    platforms: [.macOS(.v13)],
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
        .executableTarget(
            name: "trolley",
            dependencies: [
                "TrolleyKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TrolleyKitTests",
            dependencies: ["TrolleyKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
