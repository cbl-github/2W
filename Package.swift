// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BiFeed",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "6.29.0")),
        .package(url: "https://github.com/nmdias/FeedKit.git", exact: "9.1.2"),
    ],
    targets: [
        .executableTarget(
            name: "BiFeed",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "FeedKit",
            ],
            path: "Sources/BiFeed",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableUpcomingFeature("BareSlashRegexLiterals"),
            ]
        ),
        .testTarget(
            name: "BiFeedTests",
            dependencies: ["BiFeed"],
            path: "Tests/BiFeedTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableUpcomingFeature("BareSlashRegexLiterals"),
            ]
        ),
    ]
)
