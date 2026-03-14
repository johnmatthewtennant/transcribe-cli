// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "jtennant-transcriber",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-testing", from: "0.12.0"),
    ],
    targets: [
        .executableTarget(
            name: "transcribe",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/Transcribe"
        ),
        .testTarget(
            name: "TranscribeTests",
            dependencies: [
                "transcribe",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/TranscribeTests"
        ),
    ]
)
