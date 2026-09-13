// ∅ 2026 lil org

import Foundation
import CryptoKit
import XCTest
@testable import Big_Wallet

private let dappRequestAdmissionDeadline = 2_000_000_900_000

private final class CancellableCallbackProbe<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Value) -> Void)?

    func install(_ callback: @escaping @Sendable (Value) -> Void) {
        lock.lock()
        self.callback = callback
        lock.unlock()
    }

    func wait() async -> @Sendable (Value) -> Void {
        while true {
            if let callback = current() {
                return callback
            }
            await Task.yield()
        }
    }

    private func current() -> (@Sendable (Value) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return callback
    }
}

final class DappRequestProcessorTests: XCTestCase {

    func testPreparedMessageKeepsReviewedPayloadAndUsesExplicitExecutionAccess() async throws {
        let privateKey = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        let account = processorAccount(privateKey: privateKey, coin: .ethereum)
        let request = try ethereumRequest(
            method: "signPersonalMessage",
            address: account.address,
            parameters: ["data": "0x7265766965776564"]
        )
        var reviewAccess: ProcessorWalletAccess? = ProcessorWalletAccess(accounts: [account])
        let retainedReviewAccess = ProcessorWeakWalletAccess(value: reviewAccess)
        let preparation = DappRequestProcessor.prepare(
            request,
            walletAccess: try XCTUnwrap(reviewAccess)
        )
        guard case .approval(.approveMessage(let action)) = preparation,
              case .ethereumPersonalMessage(let data) = action.payload else {
            return XCTFail("Expected prepared personal-message bytes")
        }
        XCTAssertEqual(data, Data("reviewed".utf8))
        XCTAssertEqual(action.meta, "reviewed")
        XCTAssertEqual(reviewAccess?.privateKeyReads, 0)
        reviewAccess = nil
        XCTAssertNil(retainedReviewAccess.value)

        let executionAccess = ProcessorWalletAccess(accounts: [account], key: privateKey)
        let result = await DappRequestProcessor.execute(
            request: request,
            action: .approveMessage(action),
            decision: .message(.init(solanaCluster: nil)),
            walletAccess: executionAccess
        )
        guard case .response(let response) = result else {
            return XCTFail("Message signing must not broadcast")
        }
        XCTAssertEqual(
            response.json["result"] as? String,
            try Ethereum.signPersonalMessage(data: Data("reviewed".utf8), privateKey: privateKey)
        )
        XCTAssertEqual(executionAccess.privateKeyReads, 1)
    }

    func testAccountSelectionExecutionUsesExactPersistedDerivationPath() async throws {
        let privateKey = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        let account = processorAccount(privateKey: privateKey, coin: .ethereum)
        let access = ProcessorWalletAccess(accounts: [account])
        let request = try ethereumRequest(method: "requestAccounts", address: account.address)
        guard case .approval(let action) = DappRequestProcessor.prepare(request, walletAccess: access)
        else { return XCTFail("Expected account selection") }
        for path in [account.derivationPath, "m/44'/60'/0'/0/9"] {
            let decision = DappApprovalDecision.accountSelection(.init(
                accounts: [.init(
                    walletID: "wallet",
                    address: account.address,
                    provider: .ethereum,
                    derivationPath: path
                )],
                ethereumChainID: "0x1"
            ))
            let encoded = try XCTUnwrap(decision.boundedData)
            let decoded = try XCTUnwrap(DappApprovalDecision.decodeBounded(encoded))
            XCTAssertEqual(decoded, decision)
            let result = await DappRequestProcessor.execute(
                request: request,
                action: action,
                decision: decoded,
                walletAccess: access
            )
            guard case .response(let response) = result else {
                return XCTFail("Account selection must not broadcast")
            }
            if path == account.derivationPath {
                XCTAssertEqual(response.json["results"] as? [String], [account.address])
                XCTAssertNotNil(response.json["configurationToStore"])
            } else {
                XCTAssertEqual(response.json["errorCode"] as? Int, ProviderResponseError.internalErrorCode)
                XCTAssertNil(response.json["configurationToStore"])
            }
        }
        XCTAssertEqual(access.privateKeyReads, 0)
    }

    func testSolanaPreparedBroadcastRequiresExplicitClusterAndDoesNotSend() async throws {
        let privateKey = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 2, count: 32)))
        let account = processorAccount(privateKey: privateKey, coin: .solana)
        let access = ProcessorWalletAccess(accounts: [account], key: privateKey)
        let message = SolanaMessageFixture.wireMessage(
            accountKeys: [privateKey.publicKeyData(coin: .solana)],
            bodyAfterBlockhash: Data([0])
        )
        let request = try solanaRequest(
            method: "signAndSendTransaction",
            publicKey: account.address,
            parameters: [
                "message": WalletCrypto.base58Encode(data: message),
                "options": ["cluster": "devnet"],
            ]
        )
        guard case .approval(.approveMessage(let action)) =
                DappRequestProcessor.prepare(request, walletAccess: access) else {
            return XCTFail("Expected prepared Solana broadcast")
        }
        XCTAssertEqual(action.solanaClusterOptions?.suggestedCluster, .devnet)
        let missingCluster = await DappRequestProcessor.execute(
            request: request,
            action: .approveMessage(action),
            decision: .message(.init(solanaCluster: nil)),
            walletAccess: access
        )
        guard case .response(let failure) = missingCluster else {
            return XCTFail("A missing cluster must not prepare a broadcast")
        }
        XCTAssertNotNil(failure.json["error"])
        XCTAssertEqual(access.privateKeyReads, 0)

        let result = await DappRequestProcessor.execute(
            request: request,
            action: .approveMessage(action),
            decision: .message(.init(solanaCluster: .testnet)),
            walletAccess: access
        )
        guard case .broadcast(let broadcast) = result else {
            return XCTFail("Execution must return a broadcast for the durable executor")
        }
        let signature = try XCTUnwrap(
            broadcast.recoveryResponse.json["errorSignature"] as? String
        )
        let signatureData = try XCTUnwrap(WalletCrypto.base58Decode(string: signature))
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: privateKey.publicKeyData(coin: .solana)
        )
        XCTAssertTrue(publicKey.isValidSignature(signatureData, for: message))
        XCTAssertEqual(action.solanaClusterOptions?.suggestedCluster, .devnet)
        XCTAssertEqual(access.privateKeyReads, 1)
    }

    func testApprovalSelectionNormalizesEthereumButPreservesSolanaCase() throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        for coin in [WalletCoin.ethereum, .solana] {
            let account = processorAccount(privateKey: key, coin: coin)
            let catalog = [SpecificWalletAccount(walletId: "wallet", account: account)]
            let action = SelectAccountAction(
                coinType: coin,
                selectedAccounts: [],
                initiallyConnectedProviders: [],
                network: Networks.ethereum
            )
            for address in [account.address, account.address.uppercased()] {
                let result = DappApprovalValidator.resolveSelection(
                    action: action,
                    selection: .init(accounts: [.init(
                        walletID: "wallet",
                        address: address,
                        provider: coin.correspondingInpageProvider,
                        derivationPath: account.derivationPath
                    )], ethereumChainID: nil),
                    accounts: catalog,
                    networkResolver: Networks.withChainIdHex
                )
                if coin == .ethereum || address == account.address {
                    XCTAssertEqual(result?.accounts, catalog)
                } else {
                    XCTAssertNil(result)
                }
            }
        }
    }

    func testApprovalSelectionRejectsAmbiguousOrMismatchedIdentityWithoutKeys() async throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        let account = processorAccount(privateKey: key, coin: .ethereum)
        let action = SelectAccountAction(
            coinType: .ethereum,
            selectedAccounts: [],
            initiallyConnectedProviders: [],
            network: Networks.ethereum
        )
        let identity = DappApprovalDecision.AccountIdentity(
            walletID: "wallet", address: account.address, provider: .ethereum,
            derivationPath: account.derivationPath
        )
        let invalidIdentities: [DappApprovalDecision.AccountIdentity] = [
            .init(walletID: "other", address: account.address, provider: .ethereum,
                  derivationPath: account.derivationPath),
            .init(walletID: "wallet", address: "0x0000000000000000000000000000000000000000",
                  provider: .ethereum, derivationPath: account.derivationPath),
            .init(walletID: "wallet", address: account.address, provider: .solana,
                  derivationPath: account.derivationPath),
            .init(walletID: "wallet", address: account.address, provider: .ethereum,
                  derivationPath: "m/44'/60'/0'/0/9"),
        ]
        let cases = invalidIdentities.map { ([$0], [account]) } + [
            ([identity, identity], [account]),
            ([identity], [account, account]),
            ([identity], []),
        ]
        let request = try ethereumRequest(method: "requestAccounts", address: account.address)
        for (identities, accounts) in cases {
            let access = ProcessorWalletAccess(accounts: accounts, key: key)
            let result = await DappRequestProcessor.execute(
                request: request,
                action: .selectAccount(action),
                decision: .accountSelection(.init(accounts: identities, ethereumChainID: nil)),
                walletAccess: access
            )
            guard case .response(let response) = result else {
                return XCTFail("Invalid selections must not broadcast")
            }
            XCTAssertEqual(response.json["errorCode"] as? Int, ProviderResponseError.internalErrorCode)
            XCTAssertNil(response.json["configurationToStore"])
            XCTAssertEqual(access.privateKeyReads, 0)
        }
    }

    func testApprovalSelectionRequiresResolvedNetworksOnlyForNonemptySelection() throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        for coin in [WalletCoin.ethereum, .solana] {
            let account = processorAccount(privateKey: key, coin: coin)
            let catalog = [SpecificWalletAccount(walletId: "wallet", account: account)]
            let identity = DappApprovalDecision.AccountIdentity(
                walletID: "wallet", address: account.address,
                provider: coin.correspondingInpageProvider,
                derivationPath: account.derivationPath
            )
            for fallback in [nil, Networks.ethereum] as [EthereumNetwork?] {
                let action = SelectAccountAction(
                    coinType: nil, selectedAccounts: [],
                    initiallyConnectedProviders: [.ethereum], network: fallback
                )
                for explicit in [nil, "0x1"] as [String?] {
                    let result = DappApprovalValidator.resolveSelection(
                        action: action,
                        selection: .init(accounts: [identity], ethereumChainID: explicit),
                        accounts: catalog,
                        networkResolver: { _ in nil }
                    )
                    XCTAssertEqual(result != nil, coin == .solana && fallback == nil && explicit == nil)
                    XCTAssertNotNil(DappApprovalValidator.resolveSelection(
                        action: action,
                        selection: .init(accounts: [], ethereumChainID: explicit),
                        accounts: catalog,
                        networkResolver: { _ in nil }
                    ))
                }
            }
        }
        XCTAssertNil(DappApprovalValidator.resolveSelection(
            action: .init(coinType: nil, selectedAccounts: [],
                          initiallyConnectedProviders: [], network: nil),
            selection: .init(accounts: [], ethereumChainID: nil),
            accounts: [], networkResolver: { _ in nil }
        ))
    }

    func testInvalidMessageDecisionsPreserveProviderErrorsWithoutReadingKeys() async throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        for coin in [WalletCoin.ethereum, .solana] {
            let account = processorAccount(privateKey: key, coin: coin)
            let access = ProcessorWalletAccess(accounts: [account], key: key)
            let action = SignMessageAction(
                subject: .signMessage, walletId: "wallet", account: account, meta: "reviewed",
                payload: coin == .ethereum ? .ethereumMessage(Data()) : .solanaMessage(Data())
            )
            let request = try coin == .ethereum
                ? ethereumRequest(method: "signMessage", address: account.address)
                : solanaRequest(method: "signMessage", publicKey: account.address)
            for decision in [DappApprovalDecision.message(.init(solanaCluster: .devnet)),
                             .addEthereumChain] {
                let result = await DappRequestProcessor.execute(
                    request: request, action: .approveMessage(action),
                    decision: decision, walletAccess: access
                )
                guard case .response(let response) = result else {
                    return XCTFail("Invalid decisions must not broadcast")
                }
                let isUnexpectedEthereumCluster = coin == .ethereum && {
                    if case .message = decision { return true }
                    return false
                }()
                XCTAssertEqual(response.json["error"] as? String,
                               isUnexpectedEthereumCluster ? Strings.failedToSign : Strings.somethingWentWrong)
                XCTAssertEqual(response.json["errorCode"] as? Int, ProviderResponseError.internalErrorCode)
                XCTAssertEqual(access.orderedAccountReads, 0)
                XCTAssertEqual(access.privateKeyReads, 0)
            }
        }
    }

    func testApprovalTransactionDistinguishesChangedNetworkFromUnreadyFee() throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        let account = processorAccount(privateKey: key, coin: .ethereum)
        let network = try XCTUnwrap(resolvedEthereumNetworkResolution().resolvedNetwork)
        let transaction = Transaction(
            from: account.address, to: account.address, nonce: "0x1", gas: "0x5208",
            value: "0x0", data: "0x", preparedFee: .legacy(gasPrice: 10)
        )
        let action = SendTransactionAction(
            transaction: transaction, resolvedNetwork: network,
            walletId: "wallet", account: account
        )
        let execution = try XCTUnwrap(DappApprovalDecision.TransactionExecution(
            transaction, reviewedNetwork: network
        ))
        guard case .success(.transaction(_, let rebuilt)) = DappApprovalValidator.resolve(
            action: .approveTransaction(action), decision: .transaction(execution),
            accounts: nil, networkResolver: { _ in nil }
        ) else { return XCTFail("Expected a ready reconstructed transaction") }
        XCTAssertEqual(rebuilt.nonce, transaction.nonce)
        XCTAssertEqual(rebuilt.gas, transaction.gas)
        XCTAssertEqual(rebuilt.preparedFee, transaction.preparedFee)

        let changedNetwork = try XCTUnwrap(resolvedEthereumNetworkResolution(source: .alchemy).resolvedNetwork)
        let changedAction = SendTransactionAction(
            transaction: transaction, resolvedNetwork: changedNetwork,
            walletId: "wallet", account: account
        )
        guard case .failure(.staleTransaction) = DappApprovalValidator.resolve(
            action: .approveTransaction(changedAction), decision: .transaction(execution),
            accounts: nil, networkResolver: { _ in nil }
        ) else { return XCTFail("A changed reviewed network must be stale") }

        var unready = transaction
        unready.currentBaseFeePerGas = 11
        let unreadyExecution = try XCTUnwrap(DappApprovalDecision.TransactionExecution(
            unready, reviewedNetwork: network
        ))
        guard case .failure(.invalidDecision) = DappApprovalValidator.resolve(
            action: .approveTransaction(action), decision: .transaction(unreadyExecution),
            accounts: nil, networkResolver: { _ in nil }
        ) else { return XCTFail("Insufficient fees must be an invalid decision") }
    }

    func testEmptyAccountSelectionDisconnectsAfterItsNetworkDisappears() async throws {
        let request = try XCTUnwrap(SafariRequest(json: [
            "id": 1,
            "name": "switchAccount",
            "provider": "unknown",
            "host": "example.com",
            "configurationKey": "https://example.com",
            "enqueueAttempt": "00000000000000000000000000000001",
            "admissionDeadline": dappRequestAdmissionDeadline,
            "workflowVersion": ExtensionBridge.workflowVersion,
            "body": ["latestConfigurations": []],
        ]))
        let action = SelectAccountAction(
            coinType: nil,
            selectedAccounts: [],
            initiallyConnectedProviders: [.ethereum],
            network: nil
        )
        let result = await DappRequestProcessor.execute(
            request: request,
            action: .switchAccount(action),
            decision: .accountSelection(.init(
                accounts: [],
                ethereumChainID: "0x7fffffffffffffff"
            )),
            walletAccess: ProcessorWalletAccess(accounts: [])
        )
        guard case .response(let response) = result else {
            return XCTFail("Disconnecting must not broadcast")
        }
        XCTAssertNil(response.json["error"])
        XCTAssertEqual(response.json["providersToDisconnect"] as? [String], ["ethereum"])
    }

    private func processorAccount(privateKey: WalletPrivateKey, coin: WalletCoin) -> WalletAccount {
        WalletAccount(
            address: WalletCrypto.addressFromPublicKeyData(privateKey.publicKeyData(coin: coin), coin: coin),
            coin: coin,
            derivation: .custom,
            derivationPath: coin == .ethereum ? "m/44'/60'/0'/0/0" : "m/44'/501'/0'/0'",
            publicKey: "",
            extendedPublicKey: ""
        )
    }

    func testPrivateBrowsingContextExtractionDistinguishesMissingAndMalformed() {
        var missing: [String: Any] = ["subject": "rpc"]
        XCTAssertEqual(
            ExtensionBridge.takePrivateBrowsing(from: &missing),
            .missing
        )

        var regular: [String: Any] = ["__bwPrivateBrowsing": false]
        XCTAssertEqual(
            ExtensionBridge.takePrivateBrowsing(from: &regular),
            .value(false)
        )
        XCTAssertNil(regular["__bwPrivateBrowsing"])

        var privateMessage: [String: Any] = ["__bwPrivateBrowsing": true]
        XCTAssertEqual(
            ExtensionBridge.takePrivateBrowsing(from: &privateMessage),
            .value(true)
        )

        for invalid in [1, "true", NSNull()] as [Any] {
            var malformed: [String: Any] = ["__bwPrivateBrowsing": invalid]
            XCTAssertEqual(
                ExtensionBridge.takePrivateBrowsing(from: &malformed),
                .malformed
            )
        }
    }

    func testPrivateBrowsingUnsupportedErrorIsSpecificAndCorrelated() throws {
        let request = try ethereumRequest(method: "requestAccounts")
        let response = ResponseToExtension(
            for: request,
            payload: .error(.privateBrowsingUnsupported)
        )

        XCTAssertEqual(response.json["id"] as? Int, request.id)
        XCTAssertEqual(
            response.json["error"] as? String,
            Strings.privateBrowsingUnsupported
        )
        XCTAssertEqual(response.json["errorCode"] as? Int, 4200)
        XCTAssertEqual(
            response.json["provider"] as? String,
            InpageProvider.ethereum.rawValue
        )
    }

    func testEthereumTransactionHashUsesSignedWireBytes() {
        let signedTransaction =
            "f86c098504a817c800825208943535353535353535353535353535353535353535" +
            "880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d" +
            "3c71ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9" +
            "f3dc64214b297fb1966a3b6d83"
        let expected =
            "0x33469b22e9f636356c4160a87eb19df52b7412e8eac32a4a55ffe88ea8350788"

        XCTAssertEqual(
            Ethereum.transactionHash(signedTransaction: signedTransaction),
            expected
        )
        XCTAssertEqual(
            Ethereum.transactionHash(
                signedTransaction: "0x" + signedTransaction
            ),
            expected
        )
        XCTAssertNil(Ethereum.transactionHash(signedTransaction: ""))
        XCTAssertNil(Ethereum.transactionHash(signedTransaction: "0x0"))
        XCTAssertNil(Ethereum.transactionHash(signedTransaction: "0xzz"))
    }

    func testUnknownSubmissionResponsesExposeIdentifiersWithoutSuccess() throws {
        XCTAssertEqual(
            ProviderResponseError.transactionSubmissionUnknownCode,
            ProviderResponseError.internalErrorCode
        )
        let transactionHash =
            "0x33469b22e9f636356c4160a87eb19df52b7412e8eac32a4a55ffe88ea8350788"
        let ethereumResponse = EthereumDappRequestProcessor
            .transactionSubmissionUnknownResponse(
                to: try ethereumRequest(method: "signTransaction"),
                transactionHash: transactionHash
            )
        XCTAssertEqual(
            ethereumResponse.json["error"] as? String,
            Strings.transactionSubmissionStatusUnknown
        )
        XCTAssertEqual(
            ethereumResponse.json["errorCode"] as? Int,
            ProviderResponseError.transactionSubmissionUnknownCode
        )
        let encodedData = try XCTUnwrap(
            ethereumResponse.json["errorDataJSON"] as? String
        )
        let decodedData = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(encodedData.utf8))
                as? [String: String]
        )
        XCTAssertEqual(decodedData, ["transactionHash": transactionHash])
        XCTAssertNil(ethereumResponse.json["result"])

        let signature = "transaction-signature"
        let solanaResponse = SolanaDappRequestProcessor
            .transactionSubmissionUnknownResponse(
                to: try solanaRequest(
                    method: "signAndSendTransaction",
                    publicKey: "public-key"
                ),
                signature: signature
            )
        XCTAssertEqual(
            solanaResponse.json["error"] as? String,
            Strings.transactionSubmissionStatusUnknown
        )
        XCTAssertEqual(
            solanaResponse.json["errorCode"] as? Int,
            ProviderResponseError.transactionSubmissionUnknownCode
        )
        XCTAssertEqual(solanaResponse.json["errorSignature"] as? String, signature)
        XCTAssertNil(solanaResponse.json["errorDataJSON"])
        XCTAssertNil(solanaResponse.json["result"])
    }

    func testEthereumBroadcastKeepsCheckpointForAmbiguousOutcomes() throws {
        let request = try ethereumRequest(method: "signTransaction")
        let expectedHash = "0xabc123"
        let recovery = EthereumDappRequestProcessor
            .transactionSubmissionUnknownResponse(
                to: request,
                transactionHash: expectedHash
            )
        let ambiguousResults: [Result<String, EthereumSendFailure>] = [
            .success("0xdifferent"),
            .failure(.transport),
            .failure(.rpc(.unknown)),
        ]
        for result in ambiguousResults {
            let response = EthereumDappRequestProcessor.transactionBroadcastResponse(
                to: request,
                expectedHash: expectedHash,
                recoveryResponse: recovery,
                result: result
            )
            XCTAssertEqual(
                try encodedResponse(response),
                try encodedResponse(recovery)
            )
        }

        let success = EthereumDappRequestProcessor.transactionBroadcastResponse(
            to: request,
            expectedHash: expectedHash,
            recoveryResponse: recovery,
            result: .success("0XABC123")
        )
        XCTAssertEqual(success.json["result"] as? String, expectedHash)
        XCTAssertNil(success.json["error"])

        let serverFailure = EthereumDappRequestProcessor
            .transactionBroadcastResponse(
                to: request,
                expectedHash: expectedHash,
                recoveryResponse: recovery,
                result: .failure(.rpc(.serverError(
                    -32_000,
                    "transaction rejected",
                    dataJSON: #"{"reason":"nonce"}"#
                )))
            )
        XCTAssertEqual(serverFailure.json["error"] as? String, "transaction rejected")
        XCTAssertEqual(serverFailure.json["errorCode"] as? Int, -32_000)
        XCTAssertEqual(
            serverFailure.json["errorDataJSON"] as? String,
            #"{"reason":"nonce"}"#
        )

        let notSubmitted = EthereumDappRequestProcessor
            .transactionBroadcastResponse(
                to: request,
                expectedHash: expectedHash,
                recoveryResponse: recovery,
                result: .failure(.rpc(.notSubmitted))
            )
        XCTAssertEqual(notSubmitted.json["error"] as? String, Strings.failedToSend)
        XCTAssertEqual(
            notSubmitted.json["errorCode"] as? Int,
            ProviderResponseError.internalErrorCode
        )
        XCTAssertNil(notSubmitted.json["errorDataJSON"])
        XCTAssertNil(notSubmitted.json["result"])
    }

    func testEthereumBroadcastKeepsCheckpointForAlreadyKnownRPCError() throws {
        let request = try ethereumRequest(method: "signTransaction")
        let expectedHash = "0xabc123"
        let recovery = EthereumDappRequestProcessor
            .transactionSubmissionUnknownResponse(
                to: request,
                transactionHash: expectedHash
            )

        let response = EthereumDappRequestProcessor.transactionBroadcastResponse(
            to: request,
            expectedHash: expectedHash,
            recoveryResponse: recovery,
            result: .failure(.rpc(.serverError(
                -32_000,
                "already known",
                dataJSON: nil
            )))
        )

        XCTAssertEqual(
            try encodedResponse(response),
            try encodedResponse(recovery)
        )
    }

    func testSolanaBroadcastKeepsCheckpointForAmbiguousOutcomes() throws {
        let request = try solanaRequest(
            method: "signAndSendTransaction",
            publicKey: "public-key"
        )
        let expectedSignature = "expected-signature"
        let recovery = SolanaDappRequestProcessor
            .transactionSubmissionUnknownResponse(
                to: request,
                signature: expectedSignature
            )
        let ambiguousResults: [Result<String, Solana.SendTransactionError>] = [
            .success("different-signature"),
            .failure(.unknown),
            .failure(.confirmationTimedOut(signature: "different-signature")),
        ]
        for result in ambiguousResults {
            let response = SolanaDappRequestProcessor.transactionBroadcastResponse(
                to: request,
                expectedSignature: expectedSignature,
                recoveryResponse: recovery,
                result: result
            )
            XCTAssertEqual(
                try encodedResponse(response),
                try encodedResponse(recovery)
            )
        }

        let success = SolanaDappRequestProcessor.transactionBroadcastResponse(
            to: request,
            expectedSignature: expectedSignature,
            recoveryResponse: recovery,
            result: .success(expectedSignature)
        )
        XCTAssertEqual(success.json["result"] as? String, expectedSignature)
        XCTAssertNil(success.json["error"])

        let confirmationFailure = SolanaDappRequestProcessor
            .transactionBroadcastResponse(
                to: request,
                expectedSignature: expectedSignature,
                recoveryResponse: recovery,
                result: .failure(.confirmationTimedOut(
                    signature: expectedSignature
                ))
            )
        XCTAssertEqual(
            confirmationFailure.json["error"] as? String,
            Strings.solanaConfirmationTimedOut
        )
        XCTAssertEqual(
            confirmationFailure.json["errorSignature"] as? String,
            expectedSignature
        )

        let explicitFailure = SolanaDappRequestProcessor
            .transactionBroadcastResponse(
                to: request,
                expectedSignature: expectedSignature,
                recoveryResponse: recovery,
                result: .failure(.rpcError(
                    message: "transaction rejected",
                    code: -32_003
                ))
            )
        XCTAssertEqual(explicitFailure.json["error"] as? String, "transaction rejected")
        XCTAssertEqual(explicitFailure.json["errorCode"] as? Int, -32_003)
        XCTAssertNil(explicitFailure.json["errorSignature"])

        let notSubmitted = SolanaDappRequestProcessor.transactionBroadcastResponse(
            to: request,
            expectedSignature: expectedSignature,
            recoveryResponse: recovery,
            result: .failure(.notSubmitted)
        )
        XCTAssertEqual(notSubmitted.json["error"] as? String, Strings.failedToSend)
        XCTAssertEqual(
            notSubmitted.json["errorCode"] as? Int,
            ProviderResponseError.internalErrorCode
        )
        XCTAssertNil(notSubmitted.json["errorSignature"])
        XCTAssertNil(notSubmitted.json["result"])
    }

    func testSolanaBroadcastKeepsCheckpointForAlreadyProcessedRPCError() throws {
        let request = try solanaRequest(
            method: "signAndSendTransaction",
            publicKey: "public-key"
        )
        let expectedSignature = "expected-signature"
        let recovery = SolanaDappRequestProcessor
            .transactionSubmissionUnknownResponse(
                to: request,
                signature: expectedSignature
            )
        let alreadyProcessed =
            "Transaction simulation failed: " +
            "This transaction has already been processed"

        let response = SolanaDappRequestProcessor.transactionBroadcastResponse(
            to: request,
            expectedSignature: expectedSignature,
            recoveryResponse: recovery,
            result: .failure(.rpcError(
                message: alreadyProcessed,
                code: -32_002
            ))
        )

        XCTAssertEqual(
            try encodedResponse(response),
            try encodedResponse(recovery)
        )
    }

    func testEthereumSendProviderErrorPreservesRPCCodeMessageAndData() {
        let dataJSON =
            #"{"baseFeePerGas":"0x132","minimumPriorityFeePerGas":"0x1"}"#
        let rpcError = EthereumDappRequestProcessor.providerError(
            for: .rpc(
                .serverError(
                    -32_000,
                    "FeeTooLow: EffectivePriorityFeePerGas too low 0 < 1",
                    dataJSON: dataJSON
                )
            )
        )

        XCTAssertEqual(rpcError.code, -32_000)
        XCTAssertEqual(rpcError.context, .dataJSON(dataJSON))
        XCTAssertEqual(
            rpcError.message,
            "FeeTooLow: EffectivePriorityFeePerGas too low 0 < 1"
        )

        XCTAssertEqual(
            EthereumDappRequestProcessor.providerError(for: .failedToSign).code,
            -32_603
        )
        XCTAssertEqual(
            EthereumDappRequestProcessor.providerError(for: .transport).code,
            -32_603
        )
        XCTAssertEqual(
            EthereumDappRequestProcessor.providerError(for: .invalidTransaction).code,
            -32_603
        )
    }

    func testEthereumSendConnectivityFailureUsesGenericMessage() {
        let transport = EthereumDappRequestProcessor.providerError(for: .transport)
        let unknown = EthereumDappRequestProcessor.providerError(for: .rpc(.unknown))
        let serverFailure = EthereumDappRequestProcessor.providerError(
            for: .rpc(.serverError(-32_000, "server failure", dataJSON: nil))
        )

        XCTAssertEqual(transport.message, Strings.failedToSend)
        XCTAssertEqual(unknown.message, Strings.failedToSend)
        XCTAssertEqual(serverFailure.message, "server failure")
        XCTAssertEqual(serverFailure.code, -32_000)
    }

    private func encodedResponse(_ response: ResponseToExtension) throws -> Data {
        return try JSONSerialization.data(
            withJSONObject: response.json,
            options: [.sortedKeys]
        )
    }

    private func ethereumRequest(
        method: String,
        address: String = "0x0000000000000000000000000000000000000001",
        requestedChainId: String = "0x1",
        parameters: [String: Any]? = nil
    ) throws -> SafariRequest {
        let requestData = try JSONSerialization.data(withJSONObject: [
            "id": 1,
            "name": method,
            "provider": "ethereum",
            "host": "example.com",
            "configurationKey": "example.com",
            "enqueueAttempt": "00000000000000000000000000000001",
            "admissionDeadline": dappRequestAdmissionDeadline,
            "workflowVersion": ExtensionBridge.workflowVersion,
            "body": [
                "address": address,
                "chainId": "0x1",
                "object": parameters ?? ["chainId": requestedChainId],
            ],
        ])
        return try XCTUnwrap(SafariRequest(data: requestData))
    }

    private func addEthereumChainRequest(
        chainId: String
    ) throws -> (request: SafariRequest, object: [String: Any]) {
        let object: [String: Any] = [
            "id": 3,
            "name": "addEthereumChain",
            "provider": "ethereum",
            "host": "example.com",
            "configurationKey": "example.com",
            "enqueueAttempt": "00000000000000000000000000000003",
            "admissionDeadline": dappRequestAdmissionDeadline,
            "workflowVersion": ExtensionBridge.workflowVersion,
            "revisions": ["ethereum": 0, "solana": 0],
            "body": [
                "address": "0x0000000000000000000000000000000000000003",
                "chainId": "0x1",
                "object": [
                    "chainId": chainId,
                    "rpcUrls": ["https://rpc.example"],
                    "blockExplorerUrls": [],
                    "nativeCurrency": [
                        "decimals": 18,
                        "name": "Test Ether",
                        "symbol": "TETH",
                    ],
                    "chainName": "Test Network",
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return (try XCTUnwrap(SafariRequest(data: data)), object)
    }

    private func solanaRequest(
        method: String,
        publicKey: String,
        parameters: [String: Any] = [:]
    ) throws -> SafariRequest {
        let requestData = try JSONSerialization.data(withJSONObject: [
            "id": 2,
            "name": method,
            "provider": "solana",
            "host": "example.com",
            "configurationKey": "example.com",
            "enqueueAttempt": "00000000000000000000000000000002",
            "admissionDeadline": dappRequestAdmissionDeadline,
            "workflowVersion": ExtensionBridge.workflowVersion,
            "body": [
                "publicKey": publicKey,
                "object": ["params": parameters],
            ],
        ])
        return try XCTUnwrap(SafariRequest(data: requestData))
    }

    func testOnlyEthereumAccountApprovalAdvertisesConfigurationStorage() throws {
        let responseBody = ResponseToExtension.Body.ethereum(
            .init(
                results: ["0x0000000000000000000000000000000000000001"],
                chainId: "0x1"
            )
        )

        let requestAccountsResponse = ResponseToExtension(
            for: try ethereumRequest(method: "requestAccounts"),
            payload: .body(responseBody)
        )
        XCTAssertNotNil(requestAccountsResponse.json["configurationToStore"])

        for method in ["addEthereumChain", "switchEthereumChain"] {
            let response = ResponseToExtension(
                for: try ethereumRequest(method: method),
                payload: .body(responseBody)
            )
            XCTAssertNil(response.json["configurationToStore"], method)
        }
    }

    func testSwitchAccountTreatsAccountlessEthereumAsDisconnectedButKeepsNetwork() async throws {
        let requestData = try JSONSerialization.data(withJSONObject: [
            "id": 1,
            "name": "switchAccount",
            "provider": "unknown",
            "host": "example.com",
            "configurationKey": "example.com",
            "enqueueAttempt": "00000000000000000000000000000001",
            "admissionDeadline": dappRequestAdmissionDeadline,
            "workflowVersion": ExtensionBridge.workflowVersion,
            "body": [
                "latestConfigurations": [
                    [
                        "provider": "ethereum",
                        "chainId": "0x1",
                    ],
                    [
                        "provider": "ethereum",
                        "results": [""],
                        "chainId": "0x1",
                    ],
                ],
            ],
        ])
        let request = try XCTUnwrap(SafariRequest(data: requestData))

        guard case let .approval(.switchAccount(action)) = DappRequestProcessor.prepare(request) else {
            return XCTFail("Expected switch-account action")
        }

        XCTAssertFalse(action.initiallyConnectedProviders.contains(.ethereum))
        XCTAssertEqual(action.network?.chainId, EthereumNetwork.ethMainnetChainId)
    }

    func testPrepareReturnsUnauthorizedForUnownedKnownChainSwitch() throws {
        let request = try ethereumRequest(method: "switchEthereumChain")

        guard case let .response(response) = DappRequestProcessor.prepare(request) else {
            return XCTFail("Expected immediate response")
        }

        XCTAssertEqual(response.json["errorCode"] as? Int, 4100)
        XCTAssertEqual(response.json["error"] as? String, Strings.providerNotReady)
    }

    func testPrepareWithoutWalletsReturnsDisconnectedKnownChainSwitch() throws {
        let request = try ethereumRequest(
            method: "switchEthereumChain",
            address: ""
        )

        guard case let .response(response) =
            DappRequestProcessor.prepareWithoutWallets(request) else {
            return XCTFail("Expected wallet-independent response")
        }

        XCTAssertEqual(response.json["results"] as? [String], [])
        XCTAssertEqual(response.json["chainId"] as? String, "0x1")
        XCTAssertNil(response.json["error"])
    }

    func testPrepareReturnsUnrecognizedForUnknownChainSwitch() throws {
        let request = try ethereumRequest(
            method: "switchEthereumChain",
            requestedChainId: "0x7fffffffffffffff"
        )

        for preparation in [
            DappRequestProcessor.prepare(request),
            try XCTUnwrap(DappRequestProcessor.prepareWithoutWallets(request)),
        ] {
            guard case let .response(response) = preparation else {
                return XCTFail("Expected wallet-independent response")
            }
            XCTAssertEqual(response.json["errorCode"] as? Int, 4902)
            XCTAssertEqual(response.json["error"] as? String, Strings.unrecognizedChainId)
        }
    }

    func testPrepareSolanaConnectReturnsApproval() async throws {
        let request = try solanaRequest(method: "connect", publicKey: "")

        guard case let .approval(.selectAccount(action)) = DappRequestProcessor.prepare(request) else {
            return XCTFail("Expected Solana account selection")
        }

        XCTAssertEqual(action.coinType, .solana)
    }

    func testPrepareSolanaSigningForUnknownAccountReturnsUnauthorizedResponse() throws {
        let publicKey = "not-a-wallet-public-key"
        let request = try solanaRequest(
            method: "signMessage",
            publicKey: publicKey,
            parameters: [
                "message": "hello",
                "messageEncoding": "utf8",
            ]
        )

        guard case let .response(response) = DappRequestProcessor.prepare(request) else {
            return XCTFail("Expected unauthorized response")
        }

        XCTAssertEqual(response.json["provider"] as? String, "solana")
        XCTAssertEqual(response.json["errorCode"] as? Int, 4100)
        XCTAssertEqual(response.json["error"] as? String, Strings.providerNotReady)
        XCTAssertEqual(response.json["errorPublicKey"] as? String, publicKey)
    }

    func testPrepareEthereumAccountRequestReturnsApproval() async throws {
        let request = try ethereumRequest(method: "requestAccounts")

        guard case let .approval(.selectAccount(action)) = DappRequestProcessor.prepare(request) else {
            return XCTFail("Expected Ethereum account selection")
        }

        XCTAssertEqual(action.coinType, .ethereum)
    }

    func testPrepareMalformedEthereumSigningReturnsImmediateResponse() throws {
        let request = try ethereumRequest(method: "signMessage")

        guard case let .response(response) = DappRequestProcessor.prepare(request) else {
            return XCTFail("Expected malformed-request response")
        }

        XCTAssertEqual(response.json["provider"] as? String, "ethereum")
        XCTAssertEqual(response.json["error"] as? String, Strings.somethingWentWrong)
        XCTAssertNil(response.json["errorCode"])
    }

    func testResponseToExtensionPreservesEncodedRPCErrorData() throws {
        let requestJSON: [String: Any] = [
            "id": 42,
            "name": "signTransaction",
            "provider": "ethereum",
            "host": "example.com",
            "configurationKey": "example.com",
            "enqueueAttempt": "00000000000000000000000000000001",
            "admissionDeadline": dappRequestAdmissionDeadline,
            "workflowVersion": ExtensionBridge.workflowVersion,
            "body": [
                "address":
                    "0x0000000000000000000000000000000000000001",
                "chainId": "0x1",
                "object": [
                    "to":
                        "0x0000000000000000000000000000000000000002",
                ],
            ],
        ]
        let requestData = try JSONSerialization.data(
            withJSONObject: requestJSON
        )
        let request = try XCTUnwrap(SafariRequest(data: requestData))
        let response = ResponseToExtension(
            for: request,
            payload: .error(
                ProviderResponseError(
                    message: "transaction underpriced",
                    code: -32_000,
                    context: .dataJSON("null")
                )
            )
        )

        XCTAssertEqual(response.json["error"] as? String, "transaction underpriced")
        XCTAssertEqual(response.json["errorCode"] as? Int, -32_000)
        XCTAssertEqual(response.json["errorDataJSON"] as? String, "null")
        XCTAssertEqual(response.json["provider"] as? String, "ethereum")
        XCTAssertNil(response.json["errorPublicKey"])
        XCTAssertNil(response.json["errorSignature"])
        XCTAssertNil(response.json["configurationToStore"])

        let canceledResponse = ResponseToExtension(
            for: request,
            payload: .error(
                ProviderResponseError(
                    message: Strings.canceled,
                    code: 4001
                )
            )
        )
        XCTAssertEqual(canceledResponse.json["error"] as? String, Strings.canceled)
        XCTAssertEqual(canceledResponse.json["errorCode"] as? Int, 4001)

        let unrecognizedChainResponse = ResponseToExtension(
            for: request,
            payload: .error(
                ProviderResponseError(
                    message: Strings.unrecognizedChainId,
                    code: 4902
                )
            )
        )
        XCTAssertEqual(
            unrecognizedChainResponse.json["error"] as? String,
            Strings.unrecognizedChainId
        )
        XCTAssertEqual(
            unrecognizedChainResponse.json["errorCode"] as? Int,
            4902
        )

        let codeLessResponse = ResponseToExtension(
            for: request,
            payload: .error(
                ProviderResponseError(message: "generic failure")
            )
        )
        XCTAssertNil(codeLessResponse.json["errorCode"])

        let publicKeyResponse = ResponseToExtension(
            for: request,
            payload: .error(
                ProviderResponseError(
                    message: Strings.providerNotReady,
                    code: 4100,
                    context: .unauthorizedPublicKey("public-key")
                )
            )
        )
        XCTAssertEqual(
            publicKeyResponse.json["errorPublicKey"] as? String,
            "public-key"
        )
        XCTAssertNil(publicKeyResponse.json["errorDataJSON"])
        XCTAssertNil(publicKeyResponse.json["errorSignature"])

        let signatureResponse = ResponseToExtension(
            for: request,
            payload: .error(
                ProviderResponseError(
                    message: Strings.failedToSend,
                    code: -32_005,
                    context: .transactionSignature("signature")
                )
            )
        )
        XCTAssertEqual(
            signatureResponse.json["errorSignature"] as? String,
            "signature"
        )
        XCTAssertNil(signatureResponse.json["errorDataJSON"])
        XCTAssertNil(signatureResponse.json["errorPublicKey"])
    }

    func testEthereumTransactionFeeModeInferenceAndLegacyNonceOwnership() throws {
        let automatic = ethereumTransfer(parameters: [
            "nonce": "0x2a",
        ])
        XCTAssertEqual(automatic?.feeIntent, .automatic)
        XCTAssertNil(automatic?.preparedFee)
        XCTAssertNil(automatic?.nonce)

        let explicitLegacy = ethereumTransfer(parameters: [
            "type": "0x0",
        ])
        XCTAssertEqual(explicitLegacy?.feeIntent, .legacy(gasPrice: nil))
        XCTAssertNil(explicitLegacy?.preparedFee)

        let inferredLegacy = try XCTUnwrap(ethereumTransfer(parameters: [
            "gasPrice": "0x7",
        ]))
        XCTAssertEqual(inferredLegacy.feeIntent, .legacy(gasPrice: BigUInt(7)))
        XCTAssertEqual(inferredLegacy.preparedFee, .legacy(gasPrice: BigUInt(7)))
        XCTAssertEqual(inferredLegacy.gasPrice, "0x7")
        XCTAssertEqual(inferredLegacy.feeProvenance.gasPrice, .dapp)
        XCTAssertNil(inferredLegacy.feeProvenance.maxPriorityFeePerGas)
        XCTAssertNil(inferredLegacy.feeProvenance.maxFeePerGas)
    }

    func testEthereumTransactionParsesCompleteAndPartialEIP1559Fees() throws {
        let complete = try XCTUnwrap(ethereumTransfer(parameters: [
            "type": "0x2",
            "maxPriorityFeePerGas": "0x2",
            "maxFeePerGas": "0x9",
        ]))
        XCTAssertEqual(
            complete.feeIntent,
            .eip1559(
                maxPriorityFeePerGas: BigUInt(2),
                maxFeePerGas: BigUInt(9)
            )
        )
        XCTAssertEqual(
            complete.preparedFee,
            .eip1559(
                maxPriorityFeePerGas: BigUInt(2),
                maxFeePerGas: BigUInt(9)
            )
        )
        XCTAssertEqual(complete.feeProvenance.maxPriorityFeePerGas, .dapp)
        XCTAssertEqual(complete.feeProvenance.maxFeePerGas, .dapp)
        XCTAssertNil(complete.gasPrice)

        let priorityOnly = try XCTUnwrap(ethereumTransfer(parameters: [
            "maxPriorityFeePerGas": "0x3",
        ]))
        XCTAssertEqual(
            priorityOnly.feeIntent,
            .eip1559(
                maxPriorityFeePerGas: BigUInt(3),
                maxFeePerGas: nil
            )
        )
        XCTAssertNil(priorityOnly.preparedFee)
        XCTAssertEqual(priorityOnly.feeProvenance.maxPriorityFeePerGas, .dapp)
        XCTAssertNil(priorityOnly.feeProvenance.maxFeePerGas)

        let maxFeeOnly = try XCTUnwrap(ethereumTransfer(parameters: [
            "type": "0x2",
            "maxFeePerGas": "0xa",
        ]))
        XCTAssertEqual(
            maxFeeOnly.feeIntent,
            .eip1559(
                maxPriorityFeePerGas: nil,
                maxFeePerGas: BigUInt(10)
            )
        )
        XCTAssertNil(maxFeeOnly.preparedFee)
        XCTAssertNil(maxFeeOnly.feeProvenance.maxPriorityFeePerGas)
        XCTAssertEqual(maxFeeOnly.feeProvenance.maxFeePerGas, .dapp)

        let accessListOnly = ethereumTransfer(parameters: [
            "accessList": [],
        ])
        XCTAssertEqual(
            accessListOnly?.feeIntent,
            .eip1559(maxPriorityFeePerGas: nil, maxFeePerGas: nil)
        )
        XCTAssertEqual(accessListOnly?.accessList, [])
    }

    func testEthereumTransactionRejectsFeeModeConflictsAndUnsupportedTypes() {
        let conflicts: [[String: Any]] = [
            ["gasPrice": "0x1", "maxFeePerGas": "0x2"],
            ["gasPrice": "0x1", "maxPriorityFeePerGas": "0x1"],
            ["gasPrice": "0x1", "accessList": []],
            ["type": "0x0", "maxFeePerGas": "0x2"],
            ["type": "0x0", "maxPriorityFeePerGas": "0x1"],
            ["type": "0x0", "accessList": []],
            ["type": "0x2", "gasPrice": "0x1"],
        ]
        for parameters in conflicts {
            XCTAssertNil(
                ethereumTransfer(parameters: parameters),
                "Expected conflicting transaction fields to be rejected: \(parameters)"
            )
        }

        for type in ["0x1", "0x3", "0x4", "0x5", "0xffff"] {
            XCTAssertNil(
                ethereumTransfer(parameters: ["type": type]),
                "Expected unsupported transaction type \(type) to be rejected"
            )
        }
        XCTAssertNil(ethereumTransfer(parameters: ["type": 2]))
    }

    func testEthereumTransactionParsingErrorsDistinguishInvalidParametersFromUnsupportedTypes() {
        let malformedParameters: [[String: Any]] = [
            ["gasPrice": "0x1", "maxFeePerGas": "0x2"],
            [
                "accessList": [[
                    "address": "0x1",
                    "storageKeys": [],
                ]],
            ],
            [
                "maxPriorityFeePerGas": "0x3",
                "maxFeePerGas": "0x2",
            ],
            ["data": 1],
            ["data": "not hex"],
            ["to": "0x1"],
            ["type": 2],
            ["type": "0x" + String(repeating: "f", count: 65)],
        ]

        for parameters in malformedParameters {
            XCTAssertEqual(
                ethereumTransferParsingError(parameters: parameters),
                .invalidParameters,
                "Expected invalid parameters for \(parameters)"
            )
        }
        XCTAssertEqual(
            ethereumTransfer(parameters: ["gasPrice": "0x00"])?.feeIntent,
            .legacy(gasPrice: BigUInt(0))
        )
        XCTAssertEqual(
            ethereumTransfer(parameters: ["type": "0x00"])?.feeIntent,
            .legacy(gasPrice: nil)
        )
        XCTAssertEqual(
            ethereumTransferParsingError(
                parameters: ["chainId": "0x1"],
                selectedChainID: "0x64"
            ),
            .invalidParameters
        )
        XCTAssertEqual(
            ethereumTransactionParsingError(parameters: [:]),
            .invalidParameters
        )
        XCTAssertEqual(
            ethereumTransferParsingError(parameters: [
                "type": "0x1",
                "gasPrice": "0x00",
            ]),
            .unsupportedTransactionType
        )
        XCTAssertEqual(
            ethereumTransferParsingError(parameters: [
                "type": "0x1",
                "accessList": [[
                    "address": "0x1",
                    "storageKeys": [],
                ]],
            ]),
            .invalidParameters
        )
        XCTAssertEqual(
            ethereumTransferParsingError(
                parameters: [
                    "type": "0x1",
                    "chainId": "0x1",
                ],
                selectedChainID: "0x64"
            ),
            .invalidParameters
        )
        XCTAssertEqual(
            ethereumTransferParsingError(parameters: [
                "type": "0x3",
                "gasPrice": "0x1",
                "maxFeePerGas": "0x2",
            ]),
            .invalidParameters
        )
        XCTAssertEqual(
            ethereumTransferParsingError(parameters: [
                "type": "0x3",
                "maxPriorityFeePerGas": "0x3",
                "maxFeePerGas": "0x2",
            ]),
            .invalidParameters
        )

        for type in ["0x1", "0x3", "0x4", "0x5", "0xffff"] {
            XCTAssertEqual(
                ethereumTransferParsingError(parameters: ["type": type]),
                .unsupportedTransactionType,
                "Expected unsupported transaction type for \(type)"
            )
        }
    }

    func testEthereumTransactionParsingErrorsMapToProviderCodes() {
        let invalidParameters = EthereumDappRequestProcessor
            .transactionProviderError(for: .invalidParameters)
        XCTAssertEqual(invalidParameters.message, Strings.somethingWentWrong)
        XCTAssertEqual(invalidParameters.code, -32_602)

        let unsupportedType = EthereumDappRequestProcessor
            .transactionProviderError(for: .unsupportedTransactionType)
        XCTAssertEqual(unsupportedType.message, Strings.somethingWentWrong)
        XCTAssertEqual(unsupportedType.code, 4200)
    }

    func testEthereumTransactionRejectsMalformedOverflowingOrUnsafeFeeQuantities() {
        let malformedValues: [Any] = [
            "0x",
            "1",
            "0xgg",
            NSNull(),
        ]
        for value in malformedValues {
            XCTAssertNil(
                ethereumTransfer(parameters: ["gasPrice": value]),
                "Expected malformed gas price to be rejected: \(value)"
            )
        }

        let overflowingUInt256 = "0x1" + String(repeating: "0", count: 64)
        XCTAssertNil(ethereumTransfer(parameters: [
            "gasPrice": overflowingUInt256,
        ]))
        XCTAssertNil(ethereumTransfer(parameters: [
            "maxFeePerGas": overflowingUInt256,
        ]))
        XCTAssertNil(ethereumTransfer(parameters: [
            "maxPriorityFeePerGas": overflowingUInt256,
        ]))
        XCTAssertNil(ethereumTransfer(parameters: [
            "type": overflowingUInt256,
        ]))
        XCTAssertNil(ethereumTransfer(parameters: [
            "chainId": overflowingUInt256,
        ]))
        XCTAssertNil(ethereumTransfer(parameters: [
            "gas": overflowingUInt256,
        ]))
        XCTAssertNil(ethereumTransfer(parameters: [
            "value": overflowingUInt256,
        ]))

        XCTAssertEqual(
            ethereumTransfer(parameters: ["gasPrice": "0x0"])?.feeIntent,
            .legacy(gasPrice: BigUInt(0))
        )
        XCTAssertEqual(
            ethereumTransfer(parameters: ["gasPrice": "0x00"])?.feeIntent,
            .legacy(gasPrice: BigUInt(0))
        )
        let uppercasePrefixedLegacy = ethereumTransfer(parameters: [
            "gasPrice": "0X1",
        ])
        XCTAssertEqual(
            uppercasePrefixedLegacy?.feeIntent,
            .legacy(gasPrice: BigUInt(1))
        )
        XCTAssertEqual(uppercasePrefixedLegacy?.gasPrice, "0X1")
        let zeroPriority = ethereumTransfer(parameters: [
            "maxPriorityFeePerGas": "0x0",
        ])
        XCTAssertEqual(
            zeroPriority?.feeIntent,
            .eip1559(
                maxPriorityFeePerGas: BigUInt(),
                maxFeePerGas: nil
            )
        )
        XCTAssertNil(zeroPriority?.preparedFee)
        XCTAssertNil(ethereumTransfer(parameters: [
            "maxPriorityFeePerGas": "0x3",
            "maxFeePerGas": "0x2",
        ]))
    }

    func testEthereumUInt256QuantityParserIsLiberalBoundedAndCaseInsensitive() throws {
        let maximum = "0x" + String(repeating: "F", count: 64)
        let parsedMaximum = try XCTUnwrap(
            EthereumQuantity.parseUInt256(maximum)
        )
        XCTAssertEqual(parsedMaximum.toData(), Data(repeating: 0xff, count: 32))
        XCTAssertEqual(EthereumQuantity.parseUInt256("0x0"), BigUInt(0))
        XCTAssertEqual(EthereumQuantity.parseUInt256("0xaBcDeF"), BigUInt(0xabcdef))
        XCTAssertEqual(EthereumQuantity.parseUInt256("0X1"), BigUInt(1))
        XCTAssertEqual(EthereumQuantity.parseUInt256("0x00"), BigUInt(0))
        XCTAssertEqual(EthereumQuantity.parseUInt256("0x01"), BigUInt(1))
        XCTAssertEqual(
            EthereumQuantity.parseUInt256("0x0de0b6b3a7640000"),
            BigUInt(1_000_000_000_000_000_000)
        )
        XCTAssertEqual(
            EthereumQuantity.parseUInt256(
                "0x" + String(repeating: "0", count: 64) + "1"
            ),
            BigUInt(1)
        )
        XCTAssertNil(EthereumQuantity.parseUInt256("abcdef"))
        XCTAssertEqual(
            EthereumQuantity.parseUInt256(
                "aBcDeF",
                allowPrefixless: true
            ),
            BigUInt(0xabcdef)
        )
        XCTAssertEqual(
            EthereumQuantity.parseUInt256(
                "01",
                allowPrefixless: true
            ),
            BigUInt(1)
        )
        XCTAssertNil(
            EthereumQuantity.parseUInt256("", allowPrefixless: true)
        )

        for malformed in [
            "",
            "0x",
            "0X",
            "0xg",
            "0xＦ",
            "0xＦ1",
            "0x" + String(repeating: "f", count: 65),
            "0x" + String(repeating: "0", count: 256) + "1",
        ] {
            XCTAssertNil(
                EthereumQuantity.parseUInt256(malformed),
                "Expected malformed quantity to be rejected: \(malformed)"
            )
        }
    }

    func testEthereumTransactionValidatesPresentGasAndValueQuantities() throws {
        let absent = try XCTUnwrap(ethereumTransfer(parameters: [:]))
        XCTAssertNil(absent.gas)
        XCTAssertEqual(absent.value, String.hexPrefix)

        let maximum = "0x" + String(repeating: "F", count: 64)
        let maximumTransaction = try XCTUnwrap(ethereumTransfer(parameters: [
            "gas": maximum,
            "value": maximum,
        ]))
        XCTAssertEqual(maximumTransaction.gas, maximum)
        XCTAssertEqual(maximumTransaction.value, maximum)

        let zero = try XCTUnwrap(ethereumTransfer(parameters: [
            "gas": "0x0",
            "value": "0x0",
        ]))
        XCTAssertEqual(zero.gas, "0x0")
        XCTAssertEqual(zero.value, "0x0")

        for encoded in ["0x00", "0x01", "0X1"] {
            let liberalGas = try XCTUnwrap(
                ethereumTransfer(parameters: ["gas": encoded]),
                "Expected liberal gas encoding to be accepted: \(encoded)"
            )
            XCTAssertEqual(liberalGas.gas, encoded)

            let liberalValue = try XCTUnwrap(
                ethereumTransfer(parameters: ["value": encoded]),
                "Expected liberal value encoding to be accepted: \(encoded)"
            )
            XCTAssertEqual(liberalValue.value, encoded)
        }

        let malformedValues: [Any] = [
            "0x",
            "0xgg",
            1,
            NSNull(),
        ]
        for field in ["gas", "value"] {
            for value in malformedValues {
                XCTAssertEqual(
                    ethereumTransferParsingError(parameters: [field: value]),
                    .invalidParameters,
                    "Expected malformed \(field) to be rejected: \(value)"
                )
            }
        }
    }

    func testEthereumTransactionValidatesOptionalFromAgainstSelectedAccount() throws {
        let selectedAddress =
            "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"
        let caseVariedAddress =
            "0xABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD"

        let absent = try XCTUnwrap(
            ethereumTransfer(
                parameters: [:],
                selectedAddress: selectedAddress
            )
        )
        XCTAssertEqual(absent.from, selectedAddress)

        let matching = try XCTUnwrap(
            ethereumTransfer(
                parameters: ["from": selectedAddress],
                selectedAddress: selectedAddress
            )
        )
        XCTAssertEqual(matching.from, selectedAddress)

        let caseVaried = try XCTUnwrap(
            ethereumTransfer(
                parameters: ["from": caseVariedAddress],
                selectedAddress: selectedAddress
            )
        )
        XCTAssertEqual(caseVaried.from, selectedAddress)

        let invalidFromValues: [Any] = [
            "0x0000000000000000000000000000000000000002",
            "0x1",
            NSNull(),
            1,
        ]
        for value in invalidFromValues {
            XCTAssertEqual(
                ethereumTransferParsingError(
                    parameters: ["from": value],
                    selectedAddress: selectedAddress
                ),
                .invalidParameters,
                "Expected invalid from value: \(value)"
            )
        }
    }

    func testEthereumTransactionValidatesOptionalTransactionChainID() {
        XCTAssertNotNil(ethereumTransfer(parameters: [
            "chainId": "0x64",
        ], selectedChainID: "0x64"))
        XCTAssertNil(ethereumTransfer(parameters: [
            "chainId": "0x1",
        ], selectedChainID: "0x64"))
        XCTAssertNotNil(ethereumTransfer(parameters: [
            "chainId": "0x01",
        ], selectedChainID: "0x1"))
        XCTAssertNotNil(ethereumTransfer(parameters: [
            "chainId": "0X1",
        ], selectedChainID: "0x1"))
        XCTAssertNil(ethereumTransfer(parameters: [
            "chainId": 1,
        ], selectedChainID: "0x1"))
    }

    func testEthereumTransactionAccessListPreservesEntryAndStorageKeyOrder() throws {
        let firstAddress = "0x0000000000000000000000000000000000000001"
        let secondAddress = "0x00000000000000000000000000000000000000f0"
        let firstKey = "0x" + String(repeating: "0", count: 63) + "1"
        let secondKey = "0x" + String(repeating: "0", count: 62) + "20"
        let thirdKey = "0x" + String(repeating: "0", count: 61) + "300"

        let transaction = try XCTUnwrap(ethereumTransfer(parameters: [
            "accessList": [
                [
                    "address": firstAddress,
                    "storageKeys": [firstKey, secondKey],
                ],
                [
                    "address": secondAddress,
                    "storageKeys": [thirdKey],
                ],
            ],
        ]))

        XCTAssertEqual(
            transaction.feeIntent,
            .eip1559(maxPriorityFeePerGas: nil, maxFeePerGas: nil)
        )
        XCTAssertEqual(
            transaction.accessList.map(\.addressHexString),
            [firstAddress, secondAddress]
        )
        XCTAssertEqual(
            transaction.accessList.map(\.storageKeyHexStrings),
            [[firstKey, secondKey], [thirdKey]]
        )
    }

    func testEthereumTransactionRejectsMalformedAccessLists() {
        let address = "0x0000000000000000000000000000000000000001"
        let key = "0x" + String(repeating: "0", count: 63) + "1"
        let malformedAccessLists: [Any] = [
            NSNull(),
            ["not an entry"],
            [["storageKeys": [key]]],
            [["address": "0x1", "storageKeys": [key]]],
            [["address": address]],
            [["address": address, "storageKeys": key]],
            [["address": address, "storageKeys": ["0x1"]]],
            [["address": address, "storageKeys": [key, 1]]],
            [[
                "address": String(address.dropFirst(2)),
                "storageKeys": [key],
            ]],
            [[
                "address": "0X" + String(address.dropFirst(2)),
                "storageKeys": [key],
            ]],
            [[
                "address": address,
                "storageKeys": [String(key.dropFirst(2))],
            ]],
            [[
                "address": address,
                "storageKeys": ["0X" + String(key.dropFirst(2))],
            ]],
        ]

        for accessList in malformedAccessLists {
            XCTAssertNil(
                ethereumTransfer(parameters: ["accessList": accessList]),
                "Expected malformed access list to be rejected: \(accessList)"
            )
        }
    }

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
        XCTAssertEqual(
            SolanaDappRequestProcessor.decodedSignMessage(
                encodedHello,
                messageEncoding: .hex
            ),
            Data("hello".utf8)
        )
        XCTAssertEqual(
            SolanaDappRequestProcessor.decodedSignMessage(
                "hello",
                messageEncoding: .utf8
            ),
            Data("hello".utf8)
        )
        XCTAssertEqual(
            SolanaDappRequestProcessor.decodedSignMessage(
                "dead",
                messageEncoding: .utf8
            ),
            Data("dead".utf8)
        )
        XCTAssertNil(
            SolanaDappRequestProcessor.decodedSignMessage(
                "hello",
                messageEncoding: .hex
            )
        )
        XCTAssertEqual(solanaSignMessageEncoding(display: "utf8", messageEncoding: "hex"), .hex)
        XCTAssertEqual(solanaSignMessageEncoding(display: "utf8", messageEncoding: nil), .utf8)
        XCTAssertNil(solanaSignMessageEncoding(display: "utf8", messageEncoding: "base58"))
    }

    private func ethereumTransfer(
        parameters: [String: Any],
        selectedChainID: String = "0x1",
        selectedAddress: String =
            "0x0000000000000000000000000000000000000001"
    ) -> Transaction? {
        var transferParameters: [String: Any] = [
            "to": "0x0000000000000000000000000000000000000002",
        ]
        transferParameters.merge(parameters) { _, newValue in newValue }
        return ethereumTransaction(
            parameters: transferParameters,
            selectedChainID: selectedChainID,
            selectedAddress: selectedAddress
        )
    }

    private func ethereumTransferParsingError(
        parameters: [String: Any],
        selectedChainID: String = "0x1",
        selectedAddress: String =
            "0x0000000000000000000000000000000000000001"
    ) -> TransactionParsingError? {
        var transferParameters: [String: Any] = [
            "to": "0x0000000000000000000000000000000000000002",
        ]
        transferParameters.merge(parameters) { _, newValue in newValue }
        return ethereumTransactionParsingError(
            parameters: transferParameters,
            selectedChainID: selectedChainID,
            selectedAddress: selectedAddress
        )
    }

    private func ethereumTransactionParsingError(
        parameters: [String: Any],
        selectedChainID: String = "0x1",
        selectedAddress: String =
            "0x0000000000000000000000000000000000000001"
    ) -> TransactionParsingError? {
        switch ethereumRequest(
            parameters: parameters,
            selectedChainID: selectedChainID,
            selectedAddress: selectedAddress
        ).transactionParsingResult {
        case .success:
            return nil
        case .failure(let error):
            return error
        }
    }

    private func ethereumTransaction(
        parameters: [String: Any],
        selectedChainID: String = "0x1",
        selectedAddress: String =
            "0x0000000000000000000000000000000000000001"
    ) -> Transaction? {
        try? ethereumRequest(
            parameters: parameters,
            selectedChainID: selectedChainID,
            selectedAddress: selectedAddress
        ).transactionParsingResult.get()
    }

    private func ethereumRequest(
        parameters: [String: Any],
        selectedChainID: String = "0x1",
        selectedAddress: String =
            "0x0000000000000000000000000000000000000001"
    ) -> SafariRequest.Ethereum {
        let json: [String: Any] = [
            "address": selectedAddress,
            "chainId": selectedChainID,
            "object": parameters,
        ]
        guard let request = SafariRequest.Ethereum(
            name: "signTransaction",
            json: json
        ) else {
            preconditionFailure("Invalid Ethereum request fixture")
        }
        return request
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

    func testExistingCustomChainAdditionRequiresMatchingDefinition() throws {
        let approvedNetwork = approvedEthereumNetwork()
        let resolvedNetwork = try XCTUnwrap(
            resolvedEthereumNetworkResolution().resolvedNetwork
        )
        var comparisonCallCount = 0

        XCTAssertTrue(EthereumDappRequestProcessor.existingChainAdditionMatches(
            approvedNetwork: approvedNetwork,
            resolvedNetwork: resolvedNetwork,
            customDefinitionResult: { network in
                comparisonCallCount += 1
                XCTAssertEqual(network.chainId, approvedNetwork.chainId)
                return .matching
            }
        ))
        XCTAssertFalse(EthereumDappRequestProcessor.existingChainAdditionMatches(
            approvedNetwork: approvedNetwork,
            resolvedNetwork: resolvedNetwork,
            customDefinitionResult: { _ in .conflict }
        ))
        XCTAssertFalse(EthereumDappRequestProcessor.existingChainAdditionMatches(
            approvedNetwork: approvedNetwork,
            resolvedNetwork: resolvedNetwork,
            customDefinitionResult: { _ in .unavailable }
        ))
        XCTAssertEqual(comparisonCallCount, 1)

        let catalogNetwork = try XCTUnwrap(
            resolvedEthereumNetworkResolution(source: .alchemy).resolvedNetwork
        )
        XCTAssertTrue(EthereumDappRequestProcessor.existingChainAdditionMatches(
            approvedNetwork: approvedNetwork,
            resolvedNetwork: catalogNetwork,
            customDefinitionResult: { _ in
                XCTFail("Catalog networks must not read custom definitions")
                return .conflict
            }
        ))
    }

    func testExistingCustomChainAdditionAllowsGrandfatheredLocalDefinitionMatch() throws {
        var approvedNetwork = approvedEthereumNetwork()
        approvedNetwork.rpcUrls = [
            "http://localhost:8545",
            "https://safe.example",
        ]
        let resolvedNetwork = try XCTUnwrap(
            resolvedEthereumNetworkResolution().resolvedNetwork
        )
        XCTAssertEqual(
            approvedNetwork.defaultRpcURL?.absoluteString,
            "https://safe.example"
        )
        XCTAssertEqual(
            CustomNetworkDefinition.requestedRPCURLs(for: approvedNetwork)
                .map(\.absoluteString),
            ["https://safe.example", "http://localhost:8545"]
        )

        XCTAssertTrue(EthereumDappRequestProcessor.existingChainAdditionMatches(
            approvedNetwork: approvedNetwork,
            resolvedNetwork: resolvedNetwork,
            customDefinitionResult: { network in
                XCTAssertEqual(
                    CustomNetworkDefinition.requestedRPCURLs(for: network)
                        .map(\.absoluteString),
                    ["https://safe.example", "http://localhost:8545"]
                )
                return .matching
            }
        ))
    }

    func testPopupOnlySubjectsDecodeOnlyWithoutWebPageFields() throws {
        let popupMessage: [String: Any] = [
            "id": 42,
            "workflowVersion": ExtensionBridge.workflowVersion,
            "subject": "approveRequest",
            "requestToken": "00000000-0000-0000-0000-000000000001",
            "reviewToken": "00000000-0000-0000-0000-000000000002",
            "payload": [:],
        ]
        XCTAssertNoThrow(try decodeInternalRequest(popupMessage))
        var withoutReviewToken = popupMessage
        withoutReviewToken.removeValue(forKey: "reviewToken")
        XCTAssertThrowsError(try decodeInternalRequest(withoutReviewToken))

        for field in [
            "host",
            "name",
            "favicon",
            "unexpected",
            "enqueueAttempt",
            "admissionDeadline",
            "configurationKey",
            "body",
            "chainId",
        ] {
            var smuggled = popupMessage
            smuggled[field] = "evil.example"
            XCTAssertThrowsError(try decodeInternalRequest(smuggled))
        }
    }

    func testApprovalReadAndRetryDecodeOnlyTokenBoundIdentity() throws {
        for subject in ["getApprovalState", "retryApproval"] {
            let message: [String: Any] = [
                "id": 42,
                "workflowVersion": ExtensionBridge.workflowVersion,
                "subject": subject,
                "requestToken": "00000000-0000-0000-0000-000000000001",
            ]
            let request = try decodeInternalRequest(message)
            XCTAssertEqual(request.id, 42)
            switch request.command {
            case .popup(.getApprovalState(let identity)):
                XCTAssertEqual(subject, "getApprovalState")
                XCTAssertNil(identity.reviewToken)
            case .popup(.retryApproval(let identity)):
                XCTAssertEqual(subject, "retryApproval")
                XCTAssertNil(identity.reviewToken)
            default:
                XCTFail("Expected the requested popup command")
            }
            for field: (String, Any) in [
                ("payload", ["mode": "full"]),
                ("payload", ["mode": "poll"]),
                ("payload", [:]),
                ("reviewToken", "00000000-0000-0000-0000-000000000002"),
                ("host", "example.com"),
            ] {
                var invalid = message
                invalid[field.0] = field.1
                XCTAssertThrowsError(try decodeInternalRequest(invalid))
            }
            for token: Any in [NSNull(), "invalid", ""] {
                var invalid = message
                invalid["requestToken"] = token
                XCTAssertThrowsError(try decodeInternalRequest(invalid))
            }
        }
    }

    func testConfigurationMutationClassificationUsesOneStrictContract() {
        XCTAssertEqual(
            ResponseToExtension.ConfigurationMutation.classify([
                "name": "addEthereumChain",
                "provider": "ethereum",
                "chainId": "0x2a",
            ]),
            .addsEthereumChain(chainId: "0x2a")
        )
        XCTAssertEqual(
            ResponseToExtension.ConfigurationMutation.classify([
                "provider": "solana",
                "errorCode": 4100,
                "errorPublicKey": "public-key",
            ]),
            .removesSolanaAuthorization(publicKey: "public-key")
        )
        XCTAssertEqual(
            ResponseToExtension.ConfigurationMutation.classify([
                "configurationToStore": [["provider": "ethereum"]],
            ]),
            .storesConfiguration
        )
        for response: [String: Any] in [
            ["name": "addEthereumChain", "chainId": "0x2a"],
            ["name": "addEthereumChain", "provider": "solana", "chainId": "0x2a"],
            [
                "name": "addEthereumChain",
                "provider": "ethereum",
                "chainId": "0x2a",
                "error": "failed",
            ],
            ["provider": "solana", "errorCode": 4100],
        ] {
            XCTAssertNil(ResponseToExtension.ConfigurationMutation.classify(response))
        }
    }

    func testCancellableCallbackReturnsCallbackResultExactlyOnce() async {
        let probe = CancellableCallbackProbe<Int>()
        let task = Task {
            await awaitCancellableCallback { probe.install($0) }
        }
        let callback = await probe.wait()
        callback(42)
        callback(43)
        let result = await task.value
        XCTAssertEqual(result, 42)
    }

    func testCancellableCallbackFinishesOnCancellationAndIgnoresLateCallback() async {
        let probe = CancellableCallbackProbe<Int>()
        let task = Task {
            await awaitCancellableCallback { probe.install($0) }
        }
        let callback = await probe.wait()
        task.cancel()
        let cancelledResult = await task.value
        XCTAssertNil(cancelledResult)
        callback(42)
        let lateResult = await task.value
        XCTAssertNil(lateResult)
    }

    func testCancellableCallbackDoesNotStartAfterPriorCancellation() async {
        var didStart = false
        let value: Int? = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await awaitCancellableCallback { _ in didStart = true }
        }.value
        XCTAssertNil(value)
        XCTAssertFalse(didStart)
    }

    func testBackgroundOperationLeavesMainActor() async {
        let ranOnMainThread = await Task { @MainActor in
            await awaitBackgroundOperation { Thread.isMainThread }
        }.value
        XCTAssertEqual(ranOnMainThread, false)
    }

    func testCancellableCallbackStartsOnCallerActor() async {
        let ranOnMainThread = await Task { @MainActor in
            await awaitCancellableCallback { completion in
                completion(Thread.isMainThread)
            }
        }.value
        XCTAssertEqual(ranOnMainThread, true)
    }

    func testBackgroundOperationDoesNotStartAfterPriorCancellation() async {
        let value = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await awaitBackgroundOperation { true }
        }.value
        XCTAssertNil(value)
    }

    func testPopupOnlySubjectsRefuseNonObjects() {
        XCTAssertThrowsError(try decodeInternalRequest([
            ["subject": "getApprovalState", "id": 42],
        ]))
        XCTAssertThrowsError(try decodeInternalRequest("rejectRequest"))
    }

    func testWebPageSubjectsStayReachableFromContentScripts() throws {
        let responseMessage: [String: Any] = [
            "subject": "getResponse",
            "id": 42,
            "workflowVersion": ExtensionBridge.workflowVersion,
            "configurationKey": "wallet.example",
            "requestToken": "00000000-0000-0000-0000-000000000001",
            "executionDeadline": 1_700_000_160_000,
            "revisions": ["ethereum": 0, "solana": 0],
        ]
        let responseRequest = try decodeInternalRequest(responseMessage)
        guard case .page(.getResponse(let identity)) = responseRequest.command else {
            return XCTFail("expected getResponse")
        }
        XCTAssertEqual(
            identity.executionDeadline.timeIntervalSince1970,
            1_700_000_160,
            accuracy: 0.001
        )
        XCTAssertThrowsError(try decodeInternalRequest(
            responseMessage.filter { $0.key != "executionDeadline" }
        ))

        let rpcMessage: [String: Any] = [
            "subject": "rpc",
            "id": 42,
            "workflowVersion": ExtensionBridge.workflowVersion,
            "body": "{}",
            "chainId": "0x1",
        ]
        XCTAssertNoThrow(try decodeInternalRequest(rpcMessage))
    }

    private func decodeInternalRequest(_ value: Any) throws -> InternalSafariRequest {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed]
        )
        return try JSONDecoder().decode(InternalSafariRequest.self, from: data)
    }

    private func resolvedEthereumNetworkResolution(
        source: RPCSource = .custom
    ) -> EthereumNetworkResolution {
        let rpcURL = URL(string: "https://custom.example")!
        let network = EthereumNetwork(
            chainId: 64_240,
            name: "Custom",
            symbol: "CUSTOM",
            rpcEndpoint: .unauthenticated(rpcURL),
            isTestnet: false,
            mightShowPrice: false,
            explorer: nil
        )
        return .resolved(
            ResolvedEthereumNetwork(network: network, source: source)
        )
    }

    private func approvedEthereumNetwork() -> EthereumNetworkFromDapp {
        return EthereumNetworkFromDapp(
            chainId: String.hex(64_240, withPrefix: true),
            rpcUrls: ["https://custom.example"],
            blockExplorerUrls: [],
            nativeCurrency: EthereumNetworkFromDapp.Currency(
                decimals: 18,
                name: "Custom Coin",
                symbol: "CUSTOM"
            ),
            chainName: "Custom"
        )
    }

}

private struct ProcessorWeakWalletAccess {
    weak var value: ProcessorWalletAccess?
}

private final class ProcessorWalletAccess: WalletAccess {
    let catalogIdentity = WalletCatalogIdentity(
        generation: nil,
        catalogData: Data()
    )
    private let accounts: [SpecificWalletAccount]
    private let key: WalletPrivateKey?
    private(set) var orderedAccountReads = 0
    private(set) var privateKeyReads = 0

    var orderedAccounts: [SpecificWalletAccount] {
        orderedAccountReads += 1
        return accounts
    }

    init(accounts: [WalletAccount], key: WalletPrivateKey? = nil) {
        self.accounts = accounts.map { SpecificWalletAccount(walletId: "wallet", account: $0) }
        self.key = key
    }

    func privateKey(walletID: String, account: WalletAccount) -> WalletPrivateKey? {
        privateKeyReads += 1
        guard accounts.contains(where: {
            $0.walletId == walletID && $0.account == account
        }) else { return nil }
        return key
    }
}
