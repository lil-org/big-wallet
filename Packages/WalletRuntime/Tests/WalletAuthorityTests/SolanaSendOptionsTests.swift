import Foundation
import XCTest
import WalletDomain
@testable import WalletAuthority

@MainActor
final class SolanaSendOptionsTests: XCTestCase {
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
            switch SolanaSigner.preparedSendOptions(from: ["cluster": alias]) {
            case .success(let options):
                XCTAssertEqual(options.clusterHint, expectedCluster)
            case .failure(let error):
                XCTFail("Expected \(alias) to parse, got \(error)")
            }
        }
    }

    func testSolanaSendOptionsRejectInvalidAndConflictingClusterHints() {
        switch SolanaSigner.preparedSendOptions(from: ["cluster": "localnet"]) {
        case .failure(.invalidSendOptions):
            break
        default:
            XCTFail("Expected invalid cluster hint to fail")
        }

        switch SolanaSigner.preparedSendOptions(from: ["cluster": "mainnet", "bigWalletCluster": "devnet"]) {
        case .failure(.invalidSendOptions):
            break
        default:
            XCTFail("Expected conflicting cluster hints to fail")
        }
    }

    func testSolanaSendOptionsSanitizeRPCOptions() {
        switch SolanaSigner.preparedSendOptions(from: [
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
            XCTAssertEqual(options.preflightCommitment, .confirmed)
            XCTAssertEqual(options.maxRetries, 2)
            XCTAssertEqual(options.minContextSlot, 123)
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
            switch SolanaSigner.preparedSendOptions(from: options) {
            case .failure(.invalidSendOptions):
                break
            default:
                XCTFail("Expected invalid options to fail: \(options)")
            }
        }
    }
}
