// swift-tools-version: 5.4

import PackageDescription

let package = Package(
    name: "Constants",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v13),
    ],
    products: [
        .library(
            name: "Constants", targets: ["Constants"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Constants"
        )
    ]
)
