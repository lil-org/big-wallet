// ∅ 2026 lil org

import Foundation
import XCTest
@testable import Big_Wallet

final class DappRequestProcessorTests: XCTestCase {

    func testEthereumContractCreationTransactionParsingRequiresInitcodeWhenDestinationIsMissingOrEmpty() {
        let initcode = "0x6001600055"

        let omittedDestination = ethereumTransaction(parameters: ["data": initcode])
        let nullDestination = ethereumTransaction(parameters: ["to": NSNull(), "data": initcode])
        let emptyDestination = ethereumTransaction(parameters: ["to": "", "data": initcode])

        XCTAssertEqual(omittedDestination?.to, "")
        XCTAssertEqual(omittedDestination?.data, initcode)
        XCTAssertEqual(nullDestination?.to, "")
        XCTAssertEqual(nullDestination?.data, initcode)
        XCTAssertEqual(emptyDestination?.to, "")
        XCTAssertEqual(emptyDestination?.data, initcode)
        XCTAssertEqual(ethereumTransaction(parameters: ["data": "6001600055"])?.to, "")
        XCTAssertEqual(ethereumTransaction(parameters: ["data": "0xABCD"])?.to, "")
        XCTAssertNil(ethereumTransaction(parameters: [:]))
        XCTAssertNil(ethereumTransaction(parameters: ["data": "0x"]))
        XCTAssertNil(ethereumTransaction(parameters: ["data": "0x1"]))
        XCTAssertNil(ethereumTransaction(parameters: ["data": "0X6001"]))
        XCTAssertNil(ethereumTransaction(parameters: ["data": "not hex"]))
        XCTAssertNil(ethereumTransaction(parameters: ["to": NSNull(), "data": "0x"]))
        XCTAssertNil(ethereumTransaction(parameters: ["to": NSNull(), "data": "0xzz"]))
        XCTAssertNil(ethereumTransaction(parameters: ["to": "", "data": "0x"]))
        XCTAssertNil(ethereumTransaction(parameters: ["to": "", "data": "0x123"]))
        XCTAssertNil(ethereumTransaction(parameters: ["to": 0, "data": initcode]))
    }

    func testEthereumGasEstimateObjectOmitsDestinationForContractCreation() {
        let contractCreation = Transaction(from: "0x0000000000000000000000000000000000000001",
                                           to: "",
                                           nonce: nil,
                                           gasPrice: "0x1",
                                           gas: "0x5208",
                                           value: "0x",
                                           data: "0x6001600055")
        let transfer = Transaction(from: "0x0000000000000000000000000000000000000001",
                                   to: "0x0000000000000000000000000000000000000002",
                                   nonce: nil,
                                   gasPrice: "0x1",
                                   gas: "0x5208",
                                   value: "0x",
                                   data: "0x")

        let contractCreationObject = EthereumRPC.estimateGasTransactionObject(for: contractCreation)
        let transferObject = EthereumRPC.estimateGasTransactionObject(for: transfer)

        XCTAssertEqual(contractCreationObject["from"] as? String, contractCreation.from)
        XCTAssertEqual(contractCreationObject["data"] as? String, contractCreation.data)
        XCTAssertNil(contractCreationObject["to"])
        XCTAssertEqual(contractCreationObject["gasPrice"] as? String, contractCreation.gasPrice)
        XCTAssertEqual(contractCreationObject["gas"] as? String, contractCreation.gas)
        XCTAssertNil(contractCreationObject["value"])
        XCTAssertEqual(transferObject["to"] as? String, transfer.to)
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

    private func ethereumTransaction(parameters: [String: Any]) -> Transaction? {
        let json: [String: Any] = [
            "address": "0x0000000000000000000000000000000000000001",
            "chainId": "0x1",
            "object": parameters,
        ]
        return SafariRequest.Ethereum(name: "signTransaction", json: json)?.transaction
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
