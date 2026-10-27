// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WalletUpgradeHarness",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "WalletUpgradeConsumer", targets: ["WalletUpgradeConsumer"])],
    dependencies: [.package(path: "../WalletRuntime")],
    targets: [
        .executableTarget(
            name: "WalletUpgradeConsumer",
            dependencies: [
                .product(name: "WalletDomain", package: "walletruntime"),
                .product(name: "WalletAuthority", package: "walletruntime"),
                .product(name: "WalletFlows", package: "walletruntime"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
    ]
)
