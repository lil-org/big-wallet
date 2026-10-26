import CryptoKit
import Foundation
import WalletDomain
import XCTest

public extension RuntimeTestCatalog {
    static func sha256(rows: [String]) -> String {
        let canonicalText = rows.joined(separator: "\n") + "\n"
        return SHA256.hash(data: Data(canonicalText.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func record(chainId: Int,
                        name: String = "Test Network",
                        nativeCurrency: NetworkCatalogNativeCurrency = NetworkCatalogNativeCurrency(
                            name: "Ether",
                            symbol: "ETH",
                            decimals: 18
                        ),
                        explorerURL: String? = nil,
                        alchemyNetwork: String? = nil,
                        fallbackRPCURL: String? = nil,
                        accountDisabledAlchemyNetwork: String? = nil,
                        feeMarketSupport: EthereumFeeMarketSupport = .unknown,
                        feeMarketCheckedAt: String = "2026-07-23T00:00:00Z",
                        feeMarketObservedEndpoint: String? = nil) -> NetworkCatalogRecord {
        let derivedEndpoint = alchemyNetwork.flatMap(AlchemyRPC.url(network:))?
            .absoluteString ?? fallbackRPCURL ?? "https://invalid.example"
        return NetworkCatalogRecord(
            chainId: chainId,
            name: name,
            nativeCurrency: nativeCurrency,
            explorerURL: explorerURL,
            isTestnet: false,
            displayPrice: false,
            alchemyNetwork: alchemyNetwork,
            fallbackRPCURL: fallbackRPCURL,
            accountDisabledAlchemyNetwork: accountDisabledAlchemyNetwork,
            feeMarketHint: EthereumFeeMarketHint(
                support: feeMarketSupport,
                checkedAt: feeMarketCheckedAt,
                observedEndpoint: feeMarketObservedEndpoint ?? derivedEndpoint
            )
        )
    }

    static func customRecord(chainId: Int,
                              name: String,
                              rpcURL: String) -> EthereumNetworkFromDapp {
        return EthereumNetworkFromDapp(
            chainId: String.hex(chainId, withPrefix: true),
            rpcUrls: [rpcURL],
            blockExplorerUrls: [],
            nativeCurrency: EthereumNetworkFromDapp.Currency(
                decimals: 18,
                name: "\(name) Coin",
                symbol: "CUSTOM"
            ),
            chainName: name
        )
    }

    static func withFixtureBundle(catalogData: Data? = nil,
                                   body: (Bundle) throws -> Void) throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bundle")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let infoDictionary: [String: Any] = [
            "CFBundleIdentifier": "org.lil.wallet.tests.\(UUID().uuidString)",
            "CFBundleName": "Alchemy API Key Fixture",
            "CFBundlePackageType": "BNDL",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: infoDictionary,
            format: .xml,
            options: 0
        )
        try infoData.write(to: bundleURL.appendingPathComponent("Info.plist"))
        if let catalogData {
            try catalogData.write(
                to: bundleURL
                    .appendingPathComponent(NetworkCatalog.resourceName)
                    .appendingPathExtension("json")
            )
        }

        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        try body(bundle)
    }

}
