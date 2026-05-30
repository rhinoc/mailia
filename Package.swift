// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Mailia",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "MailiaCore",
            targets: ["MailiaCore"]
        ),
        .executable(
            name: "MailiaApp",
            targets: ["MailiaApp"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.8.0")
    ],
    targets: [
        .target(
            name: "MailiaCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "SwiftSoup"
            ]
        ),
        .executableTarget(
            name: "MailiaApp",
            dependencies: ["MailiaCore"]
        ),
        .testTarget(
            name: "MailiaCoreTests",
            dependencies: ["MailiaCore"]
        )
    ]
)
