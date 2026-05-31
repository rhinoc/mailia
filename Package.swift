// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Mailia",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "MailiaCore",
            targets: ["MailiaCore"]
        ),
        .executable(
            name: "Mailia",
            targets: ["MailiaApp"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.8.0"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0")
    ],
    targets: [
        .target(
            name: "MailiaCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "SwiftSoup",
                .product(name: "TOMLKit", package: "TOMLKit")
            ]
        ),
        .executableTarget(
            name: "MailiaApp",
            dependencies: [
                "MailiaCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            exclude: [
                "Info.plist"
            ],
            resources: [
                .process("Resources/AppIcon.icns"),
                .copy("Resources/TimelineWeb")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/MailiaApp/Info.plist",
                ], .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(
            name: "MailiaCoreTests",
            dependencies: ["MailiaCore"]
        ),
        .testTarget(
            name: "MailiaAppTests",
            dependencies: ["MailiaApp"]
        )
    ]
)
