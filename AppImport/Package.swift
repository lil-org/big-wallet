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
        .package(
            name: "Alamofire",
            url: "https://github.com/Alamofire/Alamofire.git", .upToNextMajor(from: "5.4.0")
        ),
        .package(
            name: "SwiftyJSON",
            url: "https://github.com/SwiftyJSON/SwiftyJSON.git", from: "5.0.0"
        ),
        .package(
            name: "SparrowKit",
            url: "https://github.com/ivanvorobei/SparrowKit", .upToNextMajor(from: "3.5.1")
        ),
        .package(
            name: "NativeUIKit",
            url: "https://github.com/ivanvorobei/NativeUIKit", .upToNextMajor(from: "1.2.9")
        ),
        .package(
            name: "SPDiffable",
            url: "https://github.com/ivanvorobei/SPDiffable", .upToNextMajor(from: "4.0.0")
        ),
        .package(
            name: "SPIndicator",
            url: "https://github.com/ivanvorobei/SPIndicator", .upToNextMajor(from: "1.6.0")
        ),
        .package(
            name: "SPAlert",
            url: "https://github.com/ivanvorobei/SPAlert", .upToNextMajor(from: "4.2.0")
        ),
        .package(
            name: "SPPageController",
            url: "https://github.com/ivanvorobei/SPPageController", .upToNextMajor(from: "1.3.2")
        ),
        .package(
            name: "Nuke",
            url: "https://github.com/kean/Nuke", .upToNextMajor(from: "10.4.1")
        ),
        .package(
            name: "SFSymbols",
            url: "https://github.com/ivanvorobei/SFSymbols", .upToNextMajor(from: "1.0.3")
        ),
        .package(
            name: "SPPermissions",
            url: "https://github.com/ivanvorobei/SPPermissions",
            .upToNextMajor(from: "7.1.1")
        ),
        .package(name: "Constants", path: "Constants")
    ],
    targets: [
        .target(
            name: "AppImport",
            dependencies: [
                .product(name: "Alamofire", package: "Alamofire"),
                .product(name: "SwiftyJSON", package: "SwiftyJSON"),
                .product(name: "NativeUIKit", package: "NativeUIKit"),
                .product(name: "SparrowKit", package: "SparrowKit"),
                .product(name: "SPDiffable", package: "SPDiffable"),
                .product(name: "SPAlert", package: "SPAlert"),
                .product(name: "SPPageController", package: "SPPageController"),
                .product(name: "SPIndicator", package: "SPIndicator"),
                .product(name: "SFSymbols", package: "SFSymbols"),
                .product(name: "SPPermissionsNotification", package: "SPPermissions"),
                .product(name: "SPPermissionsFaceID", package: "SPPermissions"),
                .product(name: "Nuke", package: "Nuke"),
                .product(name: "Constants", package: "Constants")
            ]
        )
    ]
)
