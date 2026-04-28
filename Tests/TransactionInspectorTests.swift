// ∅ 2026 lil org

import Foundation
import WalletCore
import XCTest
@testable import Big_Wallet

final class TransactionInspectorTests: XCTestCase {

    private let solanaSerializedTransactionSignerPublicKey = "4vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi"

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
        let message = solanaWireMessage(version: 0,
                                        accountKeySeeds: [7],
                                        bodyAfterBlockhash: [0, 0])

        guard let parsedMessage = SolanaWireMessageParser.parse(message) else {
            XCTFail("Expected Solana v0 message to parse")
            return
        }

        XCTAssertEqual(parsedMessage.requiredSignaturesCount, 1)
        XCTAssertEqual(parsedMessage.accountKeys.count, 1)
        XCTAssertEqual(parsedMessage.blockhashRange.lowerBound, 37)
        XCTAssertEqual(parsedMessage.blockhashRange.upperBound, 69)
    }

    func testSolanaParserAcceptsLegacyMessagesWithInstructions() {
        let message = solanaWireMessage(readOnlyUnsignedAccounts: 1,
                                        accountKeySeeds: [7, 8],
                                        bodyAfterBlockhash: [1, 1, 1, 0, 0])

        guard let parsedMessage = SolanaWireMessageParser.parse(message) else {
            XCTFail("Expected complete legacy message to parse")
            return
        }

        XCTAssertEqual(parsedMessage.requiredSignaturesCount, 1)
        XCTAssertEqual(parsedMessage.accountKeys.count, 2)
        XCTAssertEqual(parsedMessage.blockhashRange.lowerBound, 68)
        XCTAssertEqual(parsedMessage.blockhashRange.upperBound, 100)
    }

    func testSolanaParserAcceptsVersionZeroMessagesWithAddressLookups() {
        var bodyAfterBlockhash = Data([1, 1, 1, 2, 0])
        bodyAfterBlockhash.append(1)
        bodyAfterBlockhash.append(Data(repeating: 10, count: 32))
        bodyAfterBlockhash.append(contentsOf: [1, 5, 0])

        let message = solanaWireMessage(version: 0,
                                        readOnlyUnsignedAccounts: 1,
                                        accountKeySeeds: [7, 8],
                                        bodyAfterBlockhash: bodyAfterBlockhash)

        guard let parsedMessage = SolanaWireMessageParser.parse(message) else {
            XCTFail("Expected complete v0 message with lookup addresses to parse")
            return
        }

        XCTAssertEqual(parsedMessage.requiredSignaturesCount, 1)
        XCTAssertEqual(parsedMessage.accountKeys.count, 2)
        XCTAssertEqual(parsedMessage.blockhashRange.lowerBound, 69)
        XCTAssertEqual(parsedMessage.blockhashRange.upperBound, 101)
    }

    func testSolanaParserRejectsIncompleteVersionZeroMessages() {
        let message = solanaWireMessage(version: 0,
                                        accountKeySeeds: [7],
                                        bodyAfterBlockhash: [])

        XCTAssertNil(SolanaWireMessageParser.parse(message))
    }

    func testSolanaParserRejectsTruncatedLegacyInstructionData() {
        let message = solanaWireMessage(readOnlyUnsignedAccounts: 1,
                                        accountKeySeeds: [7, 8],
                                        bodyAfterBlockhash: [1, 1, 1, 0, 1])

        XCTAssertNil(SolanaWireMessageParser.parse(message))
    }

    func testSolanaParserRejectsReadOnlyFeePayer() {
        let message = solanaWireMessage(readOnlySignedAccounts: 1,
                                        accountKeySeeds: [7],
                                        bodyAfterBlockhash: [0])

        XCTAssertNil(SolanaWireMessageParser.parse(message))
    }

    func testSolanaParserRejectsTrailingBytesAfterLegacyInstructions() {
        let message = solanaWireMessage(accountKeySeeds: [7],
                                        bodyAfterBlockhash: [0, 0])

        XCTAssertNil(SolanaWireMessageParser.parse(message))
    }

    func testSolanaParserRejectsLegacyInstructionIndexOutsideAccountKeys() {
        let message = solanaWireMessage(accountKeySeeds: [7],
                                        bodyAfterBlockhash: [1, 1, 0, 0])

        XCTAssertNil(SolanaWireMessageParser.parse(message))
    }

    func testSolanaParserRejectsInstructionProgramIndexAtFeePayer() {
        let message = solanaWireMessage(readOnlyUnsignedAccounts: 1,
                                        accountKeySeeds: [7, 8],
                                        bodyAfterBlockhash: [1, 0, 0, 0])

        XCTAssertNil(SolanaWireMessageParser.parse(message))
    }

    func testSolanaParserRejectsVersionZeroProgramIndexFromAddressLookup() {
        var bodyAfterBlockhash = Data([1, 2, 0, 0])
        bodyAfterBlockhash.append(1)
        bodyAfterBlockhash.append(Data(repeating: 10, count: 32))
        bodyAfterBlockhash.append(contentsOf: [1, 5, 0])

        let message = solanaWireMessage(version: 0,
                                        readOnlyUnsignedAccounts: 1,
                                        accountKeySeeds: [7, 8],
                                        bodyAfterBlockhash: bodyAfterBlockhash)

        XCTAssertNil(SolanaWireMessageParser.parse(message))
    }

    func testSolanaParserRejectsVersionZeroAccountIndexOutsideReferencedAccounts() {
        var bodyAfterBlockhash = Data([1, 1, 1, 3, 0])
        bodyAfterBlockhash.append(1)
        bodyAfterBlockhash.append(Data(repeating: 10, count: 32))
        bodyAfterBlockhash.append(contentsOf: [1, 5, 0])

        let message = solanaWireMessage(version: 0,
                                        readOnlyUnsignedAccounts: 1,
                                        accountKeySeeds: [7, 8],
                                        bodyAfterBlockhash: bodyAfterBlockhash)

        XCTAssertNil(SolanaWireMessageParser.parse(message))
    }

    func testSolanaParserRejectsEmptyAddressLookupTableEntries() {
        var bodyAfterBlockhash = Data([0, 1])
        bodyAfterBlockhash.append(Data(repeating: 10, count: 32))
        bodyAfterBlockhash.append(contentsOf: [0, 0])

        let message = solanaWireMessage(version: 0,
                                        accountKeySeeds: [7],
                                        bodyAfterBlockhash: bodyAfterBlockhash)

        XCTAssertNil(SolanaWireMessageParser.parse(message))
    }

    func testSolanaParserRejectsTooManyReferencedAccounts() {
        var bodyAfterBlockhash = Data([0, 1])
        bodyAfterBlockhash.append(Data(repeating: 10, count: 32))
        bodyAfterBlockhash.append(Data.encodeLength(Int(UInt8.max)))
        bodyAfterBlockhash.append(Data((0..<Int(UInt8.max)).map { UInt8($0) }))
        bodyAfterBlockhash.append(0)

        let message = solanaWireMessage(version: 0,
                                        readOnlyUnsignedAccounts: 1,
                                        accountKeySeeds: [7, 8],
                                        bodyAfterBlockhash: bodyAfterBlockhash)

        XCTAssertNil(SolanaWireMessageParser.parse(message))
    }

    func testSolanaParserRejectsUnsupportedVersionedMessages() {
        let message = solanaWireMessage(version: 1,
                                        accountKeySeeds: [7],
                                        bodyAfterBlockhash: [])

        XCTAssertNil(SolanaWireMessageParser.parse(message))
    }

    func testSerializedSolanaSignAndSendRejectsMissingCosignerSignature() {
        let publicKey = solanaSerializedTransactionSignerPublicKey
        let serializedTransaction = "6t24vfGqc3gdHL1msMPmHDkE7aRCWD9nwgMFGiSsLMEkN3z3fK6hCk41Y9kYxHKYM4SfgppbThLWmvfrjdSwfB2eRFgvxsb26BrJZFGYm8EHNbjnzRQ3m2pjkiXd5xTBdgFFNviEF8hrVsLS9cqtGd3ktVSthWL1wbj4nkCVPGjkkCcTay1bWoVCLEZvzcLFbn1BDCMYMAhThjbQKYGpDR1TVEB6x4VR8Ha6umVUxGDQXMRcVrHdGZKT8xtf7YWn5JNNZGE3aeTMGBE75PdC3BsX8TfJbgzomc1DZnceVKN2WtWgarT3uXCf47jRCYrHj5WVAMBRagqYMBYV5Aw74iTkmUbTA1vpU1BScs7ozyW7"

        switch Solana.shared.preparedSerializedTransactionForSignAndSend(serializedTransaction: serializedTransaction,
                                                                         publicKey: publicKey) {
        case .failure(.unsupportedMultiSignature):
            break
        case .failure(let error):
            XCTFail("Expected unsupportedMultiSignature, got \(error)")
        case .success:
            XCTFail("Expected missing cosigner signature to be rejected")
        }
    }

    func testSerializedSolanaSignAndSendAcceptsPresentCosignerSignature() {
        let publicKey = solanaSerializedTransactionSignerPublicKey
        let serializedTransaction = "6t24vfGqc3gdHL1msMPmHDkE7aRCWD9nwgMFGiSsLMEkN3z3fK6hCk41Y9kYxHKYM4SfgppbThLWmvfrjdSwfB2eRPFZ3pbJhMNrBA2Gzbg3GUEMMvEPu3aukDxNtYzVDC8jNnyhAvC41eDA5aFCXdxba7TDo8qxrw7AmHXyPTVymxmJinebHHcukjJK8GHcqGJaknfeBUQyspxamAFcw8MqKtNNR18bBbqyzNrwr2MmA3bkbV9Vyko39uuVn3iz1vWXRVmoS8v4t5qXXFiMiKHyfuTwdpS5pHA7p9TeNFrqgC2TatFggbDWNogbGnV8gN52qc9Mjgs7S7ZDoWhPzhb4cPRH9Mj2RemE5ay7SmUj"

        switch Solana.shared.preparedSerializedTransactionForSignAndSend(serializedTransaction: serializedTransaction,
                                                                         publicKey: publicKey) {
        case .success:
            break
        case .failure(let error):
            XCTFail("Expected prepared transaction, got \(error)")
        }
    }

    func testSolanaSignMessageDecodingUsesWireEncodingNotDisplayEncoding() {
        let encodedHello = "0x68656c6c6f"
        XCTAssertEqual(DappRequestProcessor.decodedSolanaSignMessage(encodedHello,
                                                                     messageEncoding: .hex),
                       Data("hello".utf8))
        XCTAssertEqual(DappRequestProcessor.decodedSolanaSignMessage("hello",
                                                                     messageEncoding: .utf8),
                       Data("hello".utf8))
        XCTAssertEqual(DappRequestProcessor.decodedSolanaSignMessage("dead",
                                                                     messageEncoding: .utf8),
                       Data("dead".utf8))
        XCTAssertNil(DappRequestProcessor.decodedSolanaSignMessage("hello",
                                                                   messageEncoding: .hex))
        XCTAssertEqual(solanaSignMessageEncoding(display: "utf8", messageEncoding: "hex"), .hex)
        XCTAssertEqual(solanaSignMessageEncoding(display: "utf8", messageEncoding: nil), .utf8)
        XCTAssertNil(solanaSignMessageEncoding(display: "utf8", messageEncoding: "base58"))
    }

    private func solanaSignMessageEncoding(display: String?,
                                           messageEncoding: String?) -> SafariRequest.Solana.MessageEncoding? {
        var params: [String: Any] = [:]
        if let display {
            params["display"] = display
        }
        if let messageEncoding {
            params["messageEncoding"] = messageEncoding
        }

        let json: [String: Any] = [
            "publicKey": "4vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi",
            "object": [
                "params": params,
            ],
        ]
        return SafariRequest.Solana(name: "signMessage", json: json)?.signMessageEncoding
    }

    private func solanaWireMessage(version: UInt8? = nil,
                                   requiredSignatures: UInt8 = 1,
                                   readOnlySignedAccounts: UInt8 = 0,
                                   readOnlyUnsignedAccounts: UInt8 = 0,
                                   accountKeySeeds: [UInt8],
                                   blockhashSeed: UInt8 = 9,
                                   bodyAfterBlockhash: Data) -> Data {
        var message = Data()
        if let version {
            message.append(UInt8(0x80) | version)
            message.append(requiredSignatures)
        } else {
            message.append(requiredSignatures)
        }

        message.append(readOnlySignedAccounts)
        message.append(readOnlyUnsignedAccounts)
        message += Data.encodeLength(accountKeySeeds.count)

        for seed in accountKeySeeds {
            message.append(Data(repeating: seed, count: 32))
        }
        message.append(Data(repeating: blockhashSeed, count: 32))
        message.append(bodyAfterBlockhash)

        return message
    }

    private func solanaWireMessage(version: UInt8? = nil,
                                   requiredSignatures: UInt8 = 1,
                                   readOnlySignedAccounts: UInt8 = 0,
                                   readOnlyUnsignedAccounts: UInt8 = 0,
                                   accountKeySeeds: [UInt8],
                                   blockhashSeed: UInt8 = 9,
                                   bodyAfterBlockhash: [UInt8]) -> Data {
        return solanaWireMessage(version: version,
                                 requiredSignatures: requiredSignatures,
                                 readOnlySignedAccounts: readOnlySignedAccounts,
                                 readOnlyUnsignedAccounts: readOnlyUnsignedAccounts,
                                 accountKeySeeds: accountKeySeeds,
                                 blockhashSeed: blockhashSeed,
                                 bodyAfterBlockhash: Data(bodyAfterBlockhash))
    }

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

final class WalletsManagerPreviewTests: XCTestCase {

    private enum PreviewTestError: Error {
        case failed
    }

    private let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    func testEthereumPreviewReturnsPageOfAccounts() throws {
        let accounts = try WalletsManager.shared.previewAccounts(hdWallet: testHDWallet(), page: 0, coin: .ethereum)

        XCTAssertEqual(accounts.count, 11)
        XCTAssertTrue(accounts.allSatisfy { $0.coin == .ethereum })
    }

    func testSolanaPreviewReturnsPageOfAccounts() throws {
        let accounts = try WalletsManager.shared.previewAccounts(hdWallet: testHDWallet(), page: 0, coin: .solana)

        XCTAssertEqual(accounts.count, 11)
        XCTAssertTrue(accounts.allSatisfy { $0.coin == .solana })
        XCTAssertEqual(accounts[0].derivation, .solanaSolana)
        XCTAssertEqual(accounts[0].derivationPath, "m/44'/501'/0'/0'")
        XCTAssertEqual(accounts[1].derivation, .custom)
        XCTAssertEqual(accounts[1].derivationPath, "m/44'/501'/1'/0'")
        XCTAssertFalse(accounts[0].address.isEmpty)
        XCTAssertNotEqual(accounts[0].address, accounts[1].address)
    }

    func testSolanaPreviewReturnsNextPageOfAccounts() throws {
        let accounts = try WalletsManager.shared.previewAccounts(hdWallet: testHDWallet(), page: 1, coin: .solana)

        XCTAssertEqual(accounts.count, 11)
        XCTAssertTrue(accounts.allSatisfy { $0.coin == .solana })
        XCTAssertEqual(accounts.first?.derivation, .custom)
        XCTAssertEqual(accounts.first?.derivationPath, "m/44'/501'/11'/0'")
        XCTAssertEqual(accounts.first?.address.isEmpty, false)
    }

    func testMulticoinPreviewReturnsInterleavedPageOfAccounts() throws {
        let accounts = try WalletsManager.shared.previewAccounts(hdWallet: testHDWallet(), page: 0, coin: nil)

        XCTAssertEqual(accounts.count, 22)
        XCTAssertEqual(accounts.filter { $0.coin == .ethereum }.count, 11)
        XCTAssertEqual(accounts.filter { $0.coin == .solana }.count, 11)
        XCTAssertEqual(accounts[0].coin, .ethereum)
        XCTAssertEqual(accounts[0].derivationPath, DerivationPath(purpose: .bip44, coin: CoinType.ethereum.slip44Id, account: 0, change: 0, address: 0).description)
        XCTAssertEqual(accounts[1].coin, .solana)
        XCTAssertEqual(accounts[1].derivationPath, "m/44'/501'/0'/0'")
        XCTAssertEqual(accounts[2].coin, .ethereum)
        XCTAssertEqual(accounts[2].derivationPath, DerivationPath(purpose: .bip44, coin: CoinType.ethereum.slip44Id, account: 0, change: 0, address: 1).description)
        XCTAssertEqual(accounts[3].coin, .solana)
        XCTAssertEqual(accounts[3].derivationPath, "m/44'/501'/1'/0'")
        XCTAssertEqual(accounts.prefix(6).map { $0.previewDerivationIndex }, [0, 0, 1, 1, 2, 2])
    }

    func testMulticoinPreviewCollectorInterleavesSuccessfulCoins() throws {
        let hdWallet = try testHDWallet()
        let ethereumAccounts = Array(try WalletsManager.shared.previewAccounts(hdWallet: hdWallet, page: 0, coin: .ethereum).prefix(2))
        let solanaAccounts = Array(try WalletsManager.shared.previewAccounts(hdWallet: hdWallet, page: 0, coin: .solana).prefix(2))

        let accounts = try WalletsManager.collectPreviewAccounts(coins: [.ethereum, .solana]) { coin in
            switch coin {
            case .ethereum:
                return ethereumAccounts
            case .solana:
                return solanaAccounts
            default:
                return []
            }
        }

        XCTAssertEqual(accounts.map { $0.previewAccountKey }, [
            ethereumAccounts[0].previewAccountKey,
            solanaAccounts[0].previewAccountKey,
            ethereumAccounts[1].previewAccountKey,
            solanaAccounts[1].previewAccountKey,
        ])
    }

    func testMulticoinPreviewPreservesSuccessfulCoinsWhenOneFails() throws {
        let ethereumAccount = Account(address: "0x0000000000000000000000000000000000000001",
                                      coin: .ethereum,
                                      derivation: .custom,
                                      derivationPath: "m/44'/60'/0'/0/0",
                                      publicKey: "public-key",
                                      extendedPublicKey: "extended-public-key")

        let accounts = try WalletsManager.collectPreviewAccounts(coins: [.solana, .ethereum]) { coin in
            if coin == .solana {
                throw PreviewTestError.failed
            }

            return [ethereumAccount]
        }

        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.address, ethereumAccount.address)
    }

    func testMulticoinPreviewRethrowsWhenAllCoinsFail() {
        XCTAssertThrowsError(try WalletsManager.collectPreviewAccounts(coins: [.solana]) { _ in
            throw PreviewTestError.failed
        })
    }

    private func testHDWallet(file: StaticString = #filePath, line: UInt = #line) throws -> HDWallet {
        guard let wallet = HDWallet(mnemonic: mnemonic, passphrase: "") else {
            XCTFail("Expected test mnemonic to create HD wallet", file: file, line: line)
            throw PreviewTestError.failed
        }

        return wallet
    }

}
