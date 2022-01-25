// swift-tools-version: 5.4

import PackageDescription

let package = Package(
    name: "ExtensionImport",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v13),
    ],
    products: [
        .library(
            name: "ExtensionImport", targets: ["ExtensionImport"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ExtensionImport"
        )
    ]
)
