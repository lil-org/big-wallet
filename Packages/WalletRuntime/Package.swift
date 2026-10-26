// swift-tools-version: 6.2
import PackageDescription

let concurrency: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(nil),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "WalletRuntime",
    platforms: [.macOS(.v15), .iOS(.v26), .visionOS(.v2)],
    products: [
        .library(name: "WalletDomain", targets: ["WalletDomain"]),
        .library(name: "WalletAuthority", targets: ["WalletAuthority"]),
        .library(name: "WalletNetworking", targets: ["WalletNetworking"]),
    ],
    targets: [
        .target(name: "WalletDomain", swiftSettings: concurrency),
        .target(name: "WalletStorageSupport", swiftSettings: concurrency),
        .target(
            name: "CWalletCrypto",
            sources: [
                "big_wallet_secp256k1_shim.c", "big_wallet_scrypt_shim.c",
                "secp256k1/src/secp256k1.c",
                "secp256k1/src/precomputed_ecmult.c",
                "secp256k1/src/precomputed_ecmult_gen.c",
            ],
            publicHeadersPath: "include",
            cSettings: [.define("ENABLE_MODULE_RECOVERY", to: "1"), .unsafeFlags(["-O3"]) ]
        ),
        .target(
            name: "WalletAuthority",
            dependencies: ["WalletDomain", "WalletStorageSupport", "CWalletCrypto"],
            swiftSettings: concurrency,
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("LocalAuthentication")]
        ),
        .target(
            name: "WalletNetworking",
            dependencies: ["WalletDomain", "WalletStorageSupport"],
            swiftSettings: concurrency,
            linkerSettings: [.linkedFramework("Security")]
        ),
        .target(name: "WalletRuntimeTestSupport", dependencies: ["WalletDomain"], path: "Tests/Support",
                resources: [.copy("Fixtures/NetworkCatalog.json"), .copy("Fixtures/wire_protocol_contract.json"), .copy("Fixtures/native_response_contract.json")], swiftSettings: concurrency),
        .testTarget(name: "WalletDomainTests", dependencies: ["WalletDomain", "WalletRuntimeTestSupport"], swiftSettings: concurrency),
        .testTarget(name: "WalletAuthorityTests", dependencies: ["WalletAuthority", "WalletRuntimeTestSupport"], swiftSettings: concurrency),
        .testTarget(name: "WalletNetworkingTests", dependencies: ["WalletNetworking", "WalletStorageSupport", "WalletRuntimeTestSupport"], swiftSettings: concurrency),
    ]
)
