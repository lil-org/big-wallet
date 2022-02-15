// swift-tools-version: 5.4

import PackageDescription

let package = Package(
    name: "AppImport",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v13),
    ],
    products: [
        .library(
            name: "AppImport", targets: ["AppImport"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt", .upToNextMajor(from: "5.3.0")),
        .package(url: "https://github.com/Alamofire/Alamofire.git", .upToNextMajor(from: "5.4.0")),
        .package(url: "https://github.com/SwiftyJSON/SwiftyJSON.git", from: "5.0.0"),
        .package(url: "https://github.com/ivanvorobei/SparrowKit", .upToNextMajor(from: "3.5.2")),
        .package(url: "https://github.com/ivanvorobei/NativeUIKit", .upToNextMajor(from: "1.3.8")),
        .package(url: "https://github.com/ivanvorobei/SPDiffable", .upToNextMajor(from: "4.0.0")),
        .package(url: "https://github.com/ivanvorobei/SPIndicator", .upToNextMajor(from: "1.6.0")),
        .package(url: "https://github.com/ivanvorobei/SPAlert", .upToNextMajor(from: "4.2.0")),
        .package(url: "https://github.com/ivanvorobei/SPPageController", .upToNextMajor(from: "1.3.2")),
        .package(url: "https://github.com/kean/Nuke", .upToNextMajor(from: "10.4.1")),
        .package(url: "https://github.com/sparrowcode/SPSafeSymbols", .upToNextMajor(from: "1.0.5")),
        .package(url: "https://github.com/sparrowcode/SPSettingsIcons", .upToNextMajor(from: "1.0.0")),
        .package(url: "https://github.com/ivanvorobei/SPPermissions", .upToNextMajor(from: "7.1.5")),
        .package(name: "Intercom", url: "https://github.com/intercom/intercom-ios", .upToNextMajor(from: "11.1.2")),
        .package(path: "Constants")
    ],
    targets: [
        .target(
            name: "AppImport",
            dependencies: [
                .product(name: "Intercom", package: "Intercom"),
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "Alamofire", package: "Alamofire"),
                .product(name: "SwiftyJSON", package: "SwiftyJSON"),
                .product(name: "NativeUIKit", package: "NativeUIKit"),
                .product(name: "SparrowKit", package: "SparrowKit"),
                .product(name: "SPDiffable", package: "SPDiffable"),
                .product(name: "SPAlert", package: "SPAlert"),
                .product(name: "SPPageController", package: "SPPageController"),
                .product(name: "SPIndicator", package: "SPIndicator"),
                .product(name: "SPSafeSymbols", package: "SPSafeSymbols"),
                .product(name: "SPSettingsIcons", package: "SPSettingsIcons"),
                .product(name: "SPPermissionsNotification", package: "SPPermissions"),
                .product(name: "SPPermissionsFaceID", package: "SPPermissions"),
                .product(name: "Nuke", package: "Nuke"),
                .product(name: "Constants", package: "Constants")
            ]
        )
    ]
)
