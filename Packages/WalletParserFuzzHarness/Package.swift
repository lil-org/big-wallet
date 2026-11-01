// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WalletParserFuzzHarness",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "WalletParserFuzzWorker", targets: ["WalletParserFuzzWorker"])],
    dependencies: [.package(path: "../WalletRuntime")],
    targets: [
        .target(name: "ParserFuzzCanaries", publicHeadersPath: "include"),
        .executableTarget(
            name: "WalletParserFuzzWorker",
            dependencies: [
                .product(name: "WalletDomain", package: "walletruntime"),
                .product(name: "WalletAuthority", package: "walletruntime"),
                "ParserFuzzCanaries",
            ],
            resources: [.copy("Resources/fixtures.json")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
    ]
)
