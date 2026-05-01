// ∅ 2026 lil org

import XCTest
@testable import Big_Wallet

final class SolanaOptionsTests: XCTestCase {

    func testSolanaSendOptionsAcceptClusterHintAliases() {
        let aliases: [(String, Solana.Cluster)] = [
            ("mainnet", .mainnetBeta),
            ("mainnet-beta", .mainnetBeta),
            ("mainnetBeta", .mainnetBeta),
            ("solana:mainnet", .mainnetBeta),
            ("devnet", .devnet),
            ("solana:devnet", .devnet),
            ("testnet", .testnet),
            ("solana:testnet", .testnet),
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
        switch Solana.preparedSendOptions(from: ["cluster": "localnet"]) {
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
            "commitment": "finalized",
            "preflightCommitment": "confirmed",
            "mode": "serial",
            "maxRetries": 2,
            "minContextSlot": 123,
            "rpcURL": "https://example.com",
        ]) {
        case .success(let options):
            XCTAssertEqual(options.clusterHint, .devnet)
            XCTAssertEqual(options.confirmationCommitment, .finalized)
            XCTAssertEqual(options.rpcOptions["encoding"] as? String, "base64")
            XCTAssertEqual(options.rpcOptions["skipPreflight"] as? Bool, false)
            XCTAssertEqual(options.rpcOptions["preflightCommitment"] as? String, "confirmed")
            XCTAssertEqual(options.rpcOptions["maxRetries"] as? Int, 2)
            XCTAssertEqual(options.rpcOptions["minContextSlot"] as? Int, 123)
            XCTAssertNil(options.rpcOptions["commitment"])
            XCTAssertNil(options.rpcOptions["mode"])
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
            ["commitment": "unsafe"],
            ["mode": "parallel"],
            ["mode": "unsafe"],
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
            "SolanaTestnetRPCURL": "https://testnet.example.com",
        ])

        let mainnetEndpoint = configuration.endpoint(for: .mainnetBeta)
        XCTAssertEqual(mainnetEndpoint.url.absoluteString, "https://mainnet.example.com")
        XCTAssertEqual(mainnetEndpoint.source, .configured)

        let devnetEndpoint = configuration.endpoint(for: .devnet)
        XCTAssertEqual(devnetEndpoint.url.absoluteString, "https://devnet.example.com")
        XCTAssertEqual(devnetEndpoint.source, .configured)

        let testnetEndpoint = configuration.endpoint(for: .testnet)
        XCTAssertEqual(testnetEndpoint.url.absoluteString, "https://testnet.example.com")
        XCTAssertEqual(testnetEndpoint.source, .configured)
    }

    func testSolanaRPCConfigurationFallsBackToPublicEndpoints() {
        let configuration = Solana.RPCConfiguration(infoDictionary: [:])

        let mainnetEndpoint = configuration.endpoint(for: .mainnetBeta)
        XCTAssertEqual(mainnetEndpoint.url.absoluteString, "https://api.mainnet.solana.com")
        XCTAssertEqual(mainnetEndpoint.source, .publicFallback)

        let devnetEndpoint = configuration.endpoint(for: .devnet)
        XCTAssertEqual(devnetEndpoint.url.absoluteString, "https://api.devnet.solana.com")
        XCTAssertEqual(devnetEndpoint.source, .publicFallback)

        let testnetEndpoint = configuration.endpoint(for: .testnet)
        XCTAssertEqual(testnetEndpoint.url.absoluteString, "https://api.testnet.solana.com")
        XCTAssertEqual(testnetEndpoint.source, .publicFallback)
    }

}
