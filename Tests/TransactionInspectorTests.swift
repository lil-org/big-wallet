// ∅ 2026 lil org

import Foundation
import XCTest
@testable import Big_Wallet

final class TransactionInspectorTests: XCTestCase {

    func testMint() {
        let a = TransactionInspector.shared.decode(data: "0x94bf804d0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000e26067c76fdbe877f48b0a8400cf5db8b47af0fe0021fb3f", nameHex: "94bf804d", signature: "mint(uint256,address)")
        XCTAssert(a?.lowercased() == "mint(uint256,address)\n\n1\n\n0xe26067c76fdbe877f48b0a8400cf5db8b47af0fe")
    }
    
    func testClaim() {
        let b = TransactionInspector.shared.decode(data: "0x84bb1e42000000000000000000000000e26067c76fdbe877f48b0a8400cf5db8b47af0fe0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee000000000000000000000000000000000000000000000000000009184e72a00000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000001800000000000000000000000000000000000000000000000000000000000000080ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff000000000000000000000000000000000000000000000000000009184e72a000000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000021fb3f", nameHex: "84bb1e42", signature: "claim(address,uint256,address,uint256,(bytes32[],uint256,uint256,address),bytes)")
        XCTAssert(b?.lowercased() == "claim(address,uint256,address,uint256,(bytes32[],uint256,uint256,address),bytes)\n\n0xe26067c76fdbe877f48b0a8400cf5db8b47af0fe\n\n1\n\n0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\n\n10000000000000\n\n(115792089237316195423570985008687907853269984665640564039457584007913129639935, 10000000000000, 0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee)\n\n0x")
    }
    
    func testMintPublic() {
        let c = TransactionInspector.shared.decode(data: "0x161ac21f0000000000000000000000003539ac68bc96fc1f470d7739a49bbbf3d321fd5d0000000000000000000000000000a26b00c1f0df003000390027140000faa719000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010021fb3f", nameHex: "161ac21f", signature: "mintPublic(address,address,address,uint256)")
        XCTAssert(c?.lowercased() == "mintpublic(address,address,address,uint256)\n\n0x3539ac68bc96fc1f470d7739a49bbbf3d321fd5d\n\n0x0000a26b00c1f0df003000390027140000faa719\n\n0x0000000000000000000000000000000000000000\n\n1")
        
    }
    
    func testEmptyData() {
        let d = TransactionInspector.shared.decode(data: "0x", nameHex: "", signature: "mint(uint256,address)")
        XCTAssert(d == nil)
    }

    func testSolanaParserAcceptsVersionZeroMessages() {
        var message = Data([0x80, 1, 0, 0, 1])
        message.append(Data(repeating: 7, count: 32))
        message.append(Data(repeating: 9, count: 32))

        guard let parsedMessage = SolanaWireMessageParser.parse(message) else {
            XCTFail("Expected Solana v0 message to parse")
            return
        }

        XCTAssertEqual(parsedMessage.requiredSignaturesCount, 1)
        XCTAssertEqual(parsedMessage.accountKeys.count, 1)
        XCTAssertEqual(parsedMessage.blockhashRange.lowerBound, 37)
        XCTAssertEqual(parsedMessage.blockhashRange.upperBound, 69)
    }

    func testSolanaParserRejectsUnsupportedVersionedMessages() {
        var message = Data([0x81, 1, 0, 0, 1])
        message.append(Data(repeating: 7, count: 32))
        message.append(Data(repeating: 9, count: 32))

        XCTAssertNil(SolanaWireMessageParser.parse(message))
    }

    func testSolanaSendOptionsAcceptClusterHintAliases() {
        let aliases: [(String, Solana.Cluster)] = [
            ("mainnet", .mainnetBeta),
            ("mainnet-beta", .mainnetBeta),
            ("mainnetBeta", .mainnetBeta),
            ("solana:mainnet", .mainnetBeta),
            ("devnet", .devnet),
            ("solana:devnet", .devnet),
        ]

        for (alias, expectedCluster) in aliases {
            switch Solana.preparedSendOptions(from: ["cluster": alias]) {
            case .success(let options):
                XCTAssertEqual(options.clusterHint, expectedCluster)
            case .failure(let error):
                XCTFail("Expected \(alias) to parse, got \(error)")
            }
        }
    }

    func testSolanaSendOptionsRejectInvalidAndConflictingClusterHints() {
        switch Solana.preparedSendOptions(from: ["cluster": "testnet"]) {
        case .failure(.invalidSendOptions):
            break
        default:
            XCTFail("Expected invalid cluster hint to fail")
        }

        switch Solana.preparedSendOptions(from: ["cluster": "mainnet", "bigWalletCluster": "devnet"]) {
        case .failure(.invalidSendOptions):
            break
        default:
            XCTFail("Expected conflicting cluster hints to fail")
        }
    }

    func testSolanaSendOptionsSanitizeRPCOptions() {
        switch Solana.preparedSendOptions(from: [
            "cluster": "devnet",
            "bigWalletCluster": "solana:devnet",
            "encoding": "base58",
            "skipPreflight": false,
            "preflightCommitment": "confirmed",
            "maxRetries": 2,
            "minContextSlot": 123,
            "rpcURL": "https://example.com",
        ]) {
        case .success(let options):
            XCTAssertEqual(options.clusterHint, .devnet)
            XCTAssertEqual(options.rpcOptions["encoding"] as? String, "base64")
            XCTAssertEqual(options.rpcOptions["skipPreflight"] as? Bool, false)
            XCTAssertEqual(options.rpcOptions["preflightCommitment"] as? String, "confirmed")
            XCTAssertEqual(options.rpcOptions["maxRetries"] as? Int, 2)
            XCTAssertEqual(options.rpcOptions["minContextSlot"] as? Int, 123)
            XCTAssertNil(options.rpcOptions["rpcURL"])
            XCTAssertNil(options.rpcOptions["cluster"])
            XCTAssertNil(options.rpcOptions["bigWalletCluster"])
        case .failure(let error):
            XCTFail("Expected sanitized options, got \(error)")
        }
    }

    func testSolanaSendOptionsRejectUnsafeValues() {
        let invalidOptions: [[String: Any]] = [
            ["skipPreflight": true],
            ["preflightCommitment": "unsafe"],
            ["maxRetries": -1],
            ["minContextSlot": 1.5],
        ]

        for options in invalidOptions {
            switch Solana.preparedSendOptions(from: options) {
            case .failure(.invalidSendOptions):
                break
            default:
                XCTFail("Expected invalid options to fail: \(options)")
            }
        }
    }

    func testSolanaRPCConfigurationUsesConfiguredURL() {
        let configuration = Solana.RPCConfiguration(infoDictionary: [
            "SolanaMainnetRPCURL": "https://mainnet.example.com",
            "SolanaDevnetRPCURL": "https://devnet.example.com",
        ])

        let mainnetEndpoint = configuration.endpoint(for: .mainnetBeta)
        XCTAssertEqual(mainnetEndpoint.url.absoluteString, "https://mainnet.example.com")
        XCTAssertEqual(mainnetEndpoint.source, .configured)

        let devnetEndpoint = configuration.endpoint(for: .devnet)
        XCTAssertEqual(devnetEndpoint.url.absoluteString, "https://devnet.example.com")
        XCTAssertEqual(devnetEndpoint.source, .configured)
    }

    func testSolanaRPCConfigurationFallsBackToPublicEndpoints() {
        let configuration = Solana.RPCConfiguration(infoDictionary: [:])

        let mainnetEndpoint = configuration.endpoint(for: .mainnetBeta)
        XCTAssertEqual(mainnetEndpoint.url.absoluteString, "https://api.mainnet.solana.com")
        XCTAssertEqual(mainnetEndpoint.source, .publicFallback)

        let devnetEndpoint = configuration.endpoint(for: .devnet)
        XCTAssertEqual(devnetEndpoint.url.absoluteString, "https://api.devnet.solana.com")
        XCTAssertEqual(devnetEndpoint.source, .publicFallback)
    }

    func testSwitchAccountPreselectionPreservesResolvedAccountsAndFillsStaleProviders() {
        let ethereumAccount = "ethereum-account"
        let solanaAccount = "solana-account"
        let providerConfigurations: [SafariRequest.Unknown.ProviderConfiguration] = [
            .init(provider: .ethereum, address: "0x0000000000000000000000000000000000000abc", chainId: "0x1"),
            .init(provider: .solana, address: "stale-solana-public-key", chainId: nil),
        ]

        let preselectedAccounts: [String] = DappRequestProcessor.preselectedAccounts(for: providerConfigurations,
                                                                                      accountForConfiguration: { configuration in
            guard configuration.provider == .ethereum else { return nil }
            return ethereumAccount
        }, suggestedValuesForProviders: { providers in
            XCTAssertEqual(providers, [.solana])
            return [solanaAccount]
        }, defaultSuggestedValues: {
            XCTFail("Expected stale provider fallback, not empty-configuration fallback")
            return []
        })

        XCTAssertEqual(preselectedAccounts, [ethereumAccount, solanaAccount])
    }

    func testSwitchAccountPreselectionUsesMalformedProviderEntriesForSuggestions() {
        let solanaAccount = "solana-account"
        let providerConfigurations: [SafariRequest.Unknown.ProviderConfiguration] = [
            .init(provider: .solana, address: nil, chainId: nil),
        ]

        let preselectedAccounts: [String] = DappRequestProcessor.preselectedAccounts(for: providerConfigurations,
                                                                                      accountForConfiguration: { _ in nil },
                                                                                      suggestedValuesForProviders: { providers in
            XCTAssertEqual(providers, [.solana])
            return [solanaAccount]
        }, defaultSuggestedValues: {
            XCTFail("Expected malformed provider fallback, not empty-configuration fallback")
            return []
        })

        XCTAssertEqual(preselectedAccounts, [solanaAccount])
    }

    func testSwitchAccountPreselectionUsesExplicitDefaultForEmptyConfigurations() {
        let ethereumAccount = "ethereum-account"

        let preselectedAccounts: [String] = DappRequestProcessor.preselectedAccounts(for: [],
                                                                                      accountForConfiguration: { _ in
            XCTFail("Empty configuration should not resolve stored accounts")
            return nil
        }, suggestedValuesForProviders: { _ in
            XCTFail("Empty configuration should use explicit default suggestions")
            return []
        }, defaultSuggestedValues: {
            [ethereumAccount]
        })

        XCTAssertEqual(preselectedAccounts, [ethereumAccount])
    }

}
