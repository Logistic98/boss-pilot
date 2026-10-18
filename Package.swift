// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "BossPilot",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "BossPilot", targets: ["BossPilot"])
    ],
    targets: [
        .executableTarget(
            name: "BossPilot",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("PDFKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("WebKit")
            ]
        )
    ]
)
