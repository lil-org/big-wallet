// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WalletRuntimeHarness",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "ApprovalCrashWorker", targets: ["ApprovalCrashWorker"])],
    dependencies: [.package(path: "../WalletRuntime")],
    targets: [
        .executableTarget(
            name: "ApprovalCrashWorker",
            dependencies: [
                .product(name: "WalletDomain", package: "walletruntime"),
                .product(name: "WalletAuthority", package: "walletruntime"),
                .product(name: "WalletNetworking", package: "walletruntime"),
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
