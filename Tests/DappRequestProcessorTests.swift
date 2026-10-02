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

@MainActor
final class DappRequestProcessorTests: XCTestCase {

    func testImmediateResultsCannotCompleteSigningOrGrantAnotherAccount() throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        let account = processorAccount(privateKey: key, coin: .ethereum)
        let signing = try ethereumRequest(
            method: "signPersonalMessage", address: account.address,
            parameters: ["data": "0x01"]
        )
        XCTAssertNil(ImmediateResolution.existingEthereumAccounts.response(for: signing))
        XCTAssertNil(ImmediateResolution.existingSolanaConnection.response(for: signing))
        XCTAssertNil(ImmediateResolution.ethereumRecoveredAddress(account.address).response(for: signing))
        XCTAssertNil(ImmediateResolution.ethereumChain("0x1").response(for: signing))
        let request = try ethereumRequest(method: "requestAccounts")
        XCTAssertNil(ImmediateResolution.existingEthereumAccounts.response(for: request))
        let unknown = try addEthereumChainRequest(chainId: "0x7ffffffffffffffe").request
        XCTAssertNil(ImmediateResolution.ethereumChain("0x7ffffffffffffffe").response(for: unknown))
    }

    func testSolanaRevocationRequiresExplicitMatchingImmediateDenial() throws {
        let request = try solanaRequest(method: "connect", publicKey: "existing")
        let failure = try XCTUnwrap(ImmediateResolution.failure(.init(
            message: Strings.providerNotReady, code: 4100,
            context: .unauthorizedPublicKey("existing")
        )).response(for: request))
        XCTAssertNil(failure.mutation)
        XCTAssertFalse(failure.authorizationFailure)
        XCTAssertNil(ImmediateResolution.solanaAuthorizationDenied(publicKey: "different").response(for: request))
        let denial = try XCTUnwrap(ImmediateResolution.solanaAuthorizationDenied(publicKey: "existing").response(for: request))
        XCTAssertEqual(denial.mutation, .revokeSolana("existing"))
        XCTAssertTrue(denial.authorizationFailure)
    }

    func testAcceptedConsentCannotAuthorizeAgainAfterRollback() throws {
        let fixture = try ApprovedExecutionTestFixture()
        let snapshot = try fixture.enqueue(
            id: 41, name: "requestAccounts", provider: .ethereum,
            body: ["address": "", "chainId": "0x1", "object": [:]]
        )
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        let account = processorAccount(privateKey: key, coin: .ethereum)
        let catalog = processorCatalog(accounts: [account])
        guard case .approval(let intent) = DappRequestProcessor().prepare(
            try XCTUnwrap(snapshot.requestBinding), catalog: catalog
        ) else { return XCTFail("Expected account review") }
        let review = ApprovalReview(intent: intent)
        let selection = DappApprovalDecision.AccountSelection(
            accounts: [WalletAccountDescriptor(walletID: "wallet", account: account)], ethereumChainID: "0x1"
        )
        let consent = try XCTUnwrap(review.acceptAccounts(selection: selection, approvedAt: fixture.now))
        XCTAssertNil(review.acceptAccounts(selection: selection, approvedAt: fixture.now))
        let first = try consent.resolve(accounts: catalog.orderedAccounts, networkResolver: Networks.withChainIdHex).get()
        let copy = try consent.resolve(accounts: catalog.orderedAccounts, networkResolver: Networks.withChainIdHex).get()
        guard case .claimed(let claim) = fixture.store.claim(handle: snapshot.handle),
              claim.adoptForExecution(),
              case .authorized(let firstPermit) = fixture.store.authorize(claim: claim, approval: first) else {
            return XCTFail("Expected the accepted review to authorize")
        }
        XCTAssertEqual(fixture.store.abandon(permit: firstPermit), .persisted)
        guard case .claimed(let nextClaim) = fixture.store.claim(handle: snapshot.handle),
              nextClaim.adoptForExecution() else {
            return XCTFail("Expected a new execution claim")
        }
        guard case .ownershipLost = fixture.store.authorize(claim: nextClaim, approval: copy) else {
            return XCTFail("Copies of an accepted consent must share authorization consumption")
        }
        XCTAssertEqual(fixture.store.abandon(claim: nextClaim), .persisted)
        let invalidated = ApprovalReview(intent: intent)
        invalidated.invalidate()
        XCTAssertNil(invalidated.acceptAccounts(selection: selection, approvedAt: fixture.now))
    }

    func testExecutorAbandonRetiresConsentWithoutIssuingAnExecutionPermit() async throws {
        let fixture = try ApprovedExecutionTestFixture()
        let snapshot = try fixture.enqueue(
            id: 44, name: "requestAccounts", provider: .ethereum,
            body: ["address": "", "chainId": "0x1", "object": [:]]
        )
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        let account = processorAccount(privateKey: key, coin: .ethereum)
        let catalog = processorCatalog(accounts: [account])
        guard case .approval(let intent) = DappRequestProcessor().prepare(
            try XCTUnwrap(snapshot.requestBinding), catalog: catalog
        ) else { return XCTFail("Expected account review") }
        let review = ApprovalReview(intent: intent)
        let selection = DappApprovalDecision.AccountSelection(
            accounts: [WalletAccountDescriptor(walletID: "wallet", account: account)], ethereumChainID: "0x1"
        )
        let consent = try XCTUnwrap(review.acceptAccounts(selection: selection, approvedAt: fixture.now))
        guard case .claimed(let claim) = fixture.store.claim(handle: snapshot.handle) else {
            return XCTFail("Expected execution claim")
        }
        let executor = DurableApprovalExecutor(
            store: ExtensionBridge(store: fixture.store), clock: { fixture.now }
        )
        let result = await executor.execute(claim: claim, prepare: { _ in
            .ready(consent: consent, signing: .none)
        }, resolve: { _ in .abandon })
        XCTAssertEqual(result, .abandoned)
        let retiredApproval = try consent.resolve(
            accounts: catalog.orderedAccounts, networkResolver: Networks.withChainIdHex
        ).get()
        guard case .claimed(let freshClaim) = fixture.store.claim(handle: snapshot.handle),
              freshClaim.adoptForExecution() else { return XCTFail("Expected fresh review ownership") }
        let replay = fixture.store.authorize(claim: freshClaim, approval: retiredApproval)
        XCTAssertEqual(replay, .ownershipLost)
        let freshConsent = try XCTUnwrap(review.renewed().acceptAccounts(selection: selection, approvedAt: fixture.now))
        let freshApproval = try freshConsent.resolve(
            accounts: catalog.orderedAccounts, networkResolver: Networks.withChainIdHex
        ).get()
        guard case .authorized(let permit) = fixture.store.authorize(claim: freshClaim, approval: freshApproval) else {
            return XCTFail("An abandoned attempt requires new consent without poisoning the fresh claim")
        }
        XCTAssertEqual(fixture.store.abandon(permit: permit), .persisted)
    }

    func testRenewedReviewKeepsOldAcceptanceClosedAndUsesFreshConsent() throws {
        let fixture = try ApprovedExecutionTestFixture()
        let snapshot = try fixture.enqueue(
            id: 42, name: "requestAccounts", provider: .ethereum,
            body: ["address": "", "chainId": "0x1", "object": [:]]
        )
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        let account = processorAccount(privateKey: key, coin: .ethereum)
        let catalog = processorCatalog(accounts: [account])
        guard case .approval(let intent) = DappRequestProcessor().prepare(
            try XCTUnwrap(snapshot.requestBinding), catalog: catalog
        ) else { return XCTFail("Expected account review") }
        let original = ApprovalReview(intent: intent)
        let selection = DappApprovalDecision.AccountSelection(
            accounts: [WalletAccountDescriptor(walletID: "wallet", account: account)], ethereumChainID: "0x1"
        )
        original.invalidate()
        let renewed = original.renewed()
        XCTAssertNil(original.acceptAccounts(selection: selection, approvedAt: fixture.now))
        let first = try XCTUnwrap(renewed.acceptAccounts(selection: selection, approvedAt: fixture.now))
        let next = renewed.renewed()
        XCTAssertNil(renewed.acceptAccounts(selection: selection, approvedAt: fixture.now))
        let second = try XCTUnwrap(next.acceptAccounts(selection: selection, approvedAt: fixture.now))
        XCTAssertNil(next.acceptAccounts(selection: selection, approvedAt: fixture.now))

        let firstApproval = try first.resolve(accounts: catalog.orderedAccounts, networkResolver: Networks.withChainIdHex).get()
        let copiedFirst = try first.resolve(accounts: catalog.orderedAccounts, networkResolver: Networks.withChainIdHex).get()
        let secondApproval = try second.resolve(accounts: catalog.orderedAccounts, networkResolver: Networks.withChainIdHex).get()
        XCTAssertTrue(firstApproval.consumeAuthorization())
        XCTAssertFalse(copiedFirst.consumeAuthorization())
        XCTAssertTrue(secondApproval.consumeAuthorization())
        XCTAssertFalse(secondApproval.consumeAuthorization())
    }

    func testMessageConsentChecksCurrentAccountBeforeInvalidDecision() throws {
        let fixture = try ApprovedExecutionTestFixture()
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        let account = processorAccount(privateKey: key, coin: .ethereum)
        try fixture.establishGrant(WalletAccountDescriptor(walletID: "wallet", account: account))
        let snapshot = try fixture.enqueue(
            id: 43, name: "signPersonalMessage", provider: .ethereum,
            body: ["address": account.address, "chainId": "0x1", "object": ["data": "0x01"]]
        )
        let catalog = processorCatalog(accounts: [account])
        guard case .approval(let intent) = DappRequestProcessor().prepare(
            try XCTUnwrap(snapshot.requestBinding), catalog: catalog
        ) else { return XCTFail("Expected message review") }
        let review = ApprovalReview(intent: intent)
        let consent = try XCTUnwrap(review.acceptMessage(cluster: .devnet, approvedAt: fixture.now))
        guard case .failure(.staleAccount) = consent.resolve(
            accounts: [.init(walletId: "other-wallet", account: account)],
            networkResolver: Networks.withChainIdHex
        ) else { return XCTFail("A removed account must take precedence over an invalid cluster") }
        guard case .failure(.invalidDecision) = consent.resolve(
            accounts: catalog.orderedAccounts, networkResolver: Networks.withChainIdHex
        ) else { return XCTFail("Ethereum message approval must reject a Solana cluster") }

        let validConsent = try XCTUnwrap(review.renewed().acceptMessage(cluster: nil, approvedAt: fixture.now))
        let resolved = try validConsent.resolve(
            accounts: catalog.orderedAccounts, networkResolver: Networks.withChainIdHex
        ).get()
        guard case .signing(_, .ethereumPersonalMessage(let data)) = resolved.approval.kind else {
            return XCTFail("Expected the canonical message payload")
        }
        XCTAssertEqual(data, Data([1]))
    }

    func testTransactionConsentChecksCurrentAccountBeforeChangedNetwork() throws {
        let (fixture, action, review) = try processorTransactionReview()
        let execution = try XCTUnwrap(DappApprovalDecision.TransactionExecution(
            action.transaction, reviewedNetwork: action.resolvedNetwork,
            approvedAccount: WalletAccountDescriptor(walletID: action.walletId, account: action.account)
        ))
        let consent = try XCTUnwrap(review.acceptTransaction(execution: execution, approvedAt: fixture.now))
        let changedNetwork = ResolvedEthereumNetwork(
            network: action.chain, source: action.rpcSource == .custom ? .alchemy : .custom
        )
        guard case .failure(.staleAccount) = consent.resolve(
            accounts: [.init(walletId: "other-wallet", account: action.account)],
            networkResolver: Networks.withChainIdHex,
            transactionNetworkResolver: { _ in changedNetwork }
        ) else { return XCTFail("A removed account must take precedence over a changed network") }
        guard case .failure(.staleTransaction) = consent.resolve(
            accounts: [.init(walletId: action.walletId, account: action.account)],
            networkResolver: Networks.withChainIdHex,
            transactionNetworkResolver: { _ in changedNetwork }
        ) else { return XCTFail("A changed network must invalidate the accepted transaction") }
    }

    func testTransactionConsentUsesAcceptedExecutionFields() throws {
        let (fixture, action, review) = try processorTransactionReview()
        var accepted = action.transaction
        accepted.nonce = "0x5"
        accepted.gas = "0xea60"
        accepted.replacePreparedFee(.legacy(gasPrice: 10), provenance: .init(source: .manual, for: .legacy(gasPrice: 10)))
        let execution = try XCTUnwrap(DappApprovalDecision.TransactionExecution(
            accepted, reviewedNetwork: action.resolvedNetwork,
            approvedAccount: WalletAccountDescriptor(walletID: action.walletId, account: action.account)
        ))
        let consent = try XCTUnwrap(review.acceptTransaction(execution: execution, approvedAt: fixture.now))
        let result = consent.resolve(
            accounts: [.init(walletId: action.walletId, account: action.account)],
            networkResolver: Networks.withChainIdHex,
            transactionNetworkResolver: { _ in action.resolvedNetwork }
        )
        guard case .success(let resolved) = result else {
            return XCTFail("Accepted execution fields must remain ready: \(result)")
        }
        guard case .signing(_, .ethereumTransaction(let transaction, let network)) = resolved.approval.kind else {
            return XCTFail("Expected the accepted transaction")
        }
        XCTAssertEqual(transaction.nonce, accepted.nonce)
        XCTAssertEqual(transaction.gas, accepted.gas)
        XCTAssertEqual(transaction.preparedFee, accepted.preparedFee)
        XCTAssertEqual(transaction.feeProvenance, accepted.feeProvenance)
        XCTAssertEqual(transaction.currentBaseFeePerGas, accepted.feeBasisBaseFeePerGas)
        XCTAssertEqual(transaction.to, action.transaction.to)
        XCTAssertEqual(transaction.data, action.transaction.data)
        XCTAssertEqual(transaction.feeIntent, action.transaction.feeIntent)
        XCTAssertEqual(network, action.resolvedNetwork)
    }

    func testSerializedSolanaReviewRetainsRequestCosignatureAtBindingAndResolution() throws {
        let fixture = try ApprovedExecutionTestFixture()
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 2, count: 32)))
        let account = processorAccount(privateKey: key, coin: .solana)
        try fixture.establishGrant(WalletAccountDescriptor(walletID: "wallet", account: account))
        let cosigner = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 3, count: 32))
        let message = SolanaMessageFixture.wireMessage(
            requiredSignatures: 2,
            accountKeys: [cosigner.publicKey.rawRepresentation, key.publicKeyData(coin: .solana)],
            bodyAfterBlockhash: Data([0])
        )
        let originalCosignature = try cosigner.signature(for: message)
        let wire = Data([2]) + originalCosignature + Data(repeating: 0, count: 64) + message
        let snapshot = try fixture.enqueue(
            id: 45, name: "signAndSendTransaction", provider: .solana,
            body: ["publicKey": account.address, "object": ["params": [
                "transaction": WalletCrypto.base58Encode(data: wire),
                "options": ["cluster": "devnet", "maxRetries": 3]
            ]]]
        )
        guard case .approval(let actionIntent) = DappRequestProcessor().prepare(
            try XCTUnwrap(snapshot.requestBinding), catalog: processorCatalog(accounts: [account])
        ),
              case .approveMessage(let action) = actionIntent.action,
              case .solanaSerializedBroadcast = action.payload else {
            return XCTFail("Expected serialized Solana review")
        }
        let review = ApprovalReview(intent: actionIntent)
        let consent = try XCTUnwrap(review.acceptMessage(cluster: .testnet, approvedAt: fixture.now))
        let resolved = try consent.resolve(
            accounts: processorCatalog(accounts: [account]).orderedAccounts,
            networkResolver: Networks.withChainIdHex
        ).get()
        guard case .signing(_, .solanaSerializedBroadcast(let transaction, let retainedOptions, let cluster)) = resolved.approval.kind else {
            return XCTFail("Expected serialized Solana signing payload")
        }
        let signed = try XCTUnwrap(Solana.signedTransactionForSignAndSend(
            preparedSerializedTransaction: transaction, privateKey: key
        ))
        let bytes = try XCTUnwrap(Data(base64Encoded: signed))
        XCTAssertEqual(bytes.subdata(in: 1..<65), originalCosignature)
        XCTAssertEqual(bytes.subdata(in: 129..<bytes.count), message)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key.publicKeyData(coin: .solana))
        XCTAssertTrue(publicKey.isValidSignature(bytes.subdata(in: 65..<129), for: message))
        XCTAssertEqual(cluster, .testnet)
        XCTAssertEqual(retainedOptions.clusterHint, .devnet)
        XCTAssertEqual(retainedOptions.maxRetries, 3)
    }

    private func processorTransactionReview() throws -> (ApprovedExecutionTestFixture, SendTransactionAction, ApprovalReview) {
        let fixture = try ApprovedExecutionTestFixture(now: Date(timeIntervalSince1970: 1_700_000_000))
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        let account = processorAccount(privateKey: key, coin: .ethereum)
        try fixture.establishGrant(WalletAccountDescriptor(walletID: "wallet", account: account))
        let snapshot = try fixture.enqueue(
            id: 44, name: "signTransaction", provider: .ethereum,
            body: ["address": account.address, "chainId": "0x1", "object": [
                "from": account.address, "to": "0x0000000000000000000000000000000000000002",
                "value": "0x1", "data": "0x", "nonce": "0x0", "gas": "0x5208", "gasPrice": "0x1"
            ]]
        )
        guard case .approval(let preparedIntent) = DappRequestProcessor().prepare(
            try XCTUnwrap(snapshot.requestBinding), catalog: processorCatalog(accounts: [account])
        ),
              case .approveTransaction(let prepared) = preparedIntent.action else { throw CocoaError(.coderInvalidValue) }
        var transaction = prepared.transaction
        transaction.nonce = "0x0"
        transaction.gas = "0x5208"
        transaction.currentBaseFeePerGas = 1
        transaction.replacePreparedFee(.legacy(gasPrice: 2), provenance: .init(gasPrice: .dapp))
        let action = SendTransactionAction(
            transaction: transaction, resolvedNetwork: prepared.resolvedNetwork,
            walletId: prepared.walletId, account: prepared.account
        )
        let review = ApprovalReview(intent: preparedIntent)
        return (fixture, action, review)
    }

    func testFactoryUsesStoredCanonicalSigningTransactionAndNetworkPayloads() throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        let account = processorAccount(privateKey: key, coin: .ethereum)
        let catalog = processorCatalog(accounts: [account])
        let fixture = try ApprovedExecutionTestFixture()
        try fixture.establishGrant(WalletAccountDescriptor(walletID: "wallet", account: account))
        let messageParameters = NSMutableDictionary(dictionary: ["data": "0x01"])
        let messageSnapshot = try fixture.enqueue(
            id: 51, name: "signPersonalMessage", provider: .ethereum,
            body: ["address": account.address, "chainId": "0x1", "object": messageParameters]
        )
        messageParameters["data"] = "0x02"
        guard case .approval(let messageIntent) = DappRequestProcessor().prepare(
            try XCTUnwrap(messageSnapshot.requestBinding), catalog: catalog
        ), case .approveMessage(let message) = messageIntent.action,
           case .ethereumPersonalMessage(let data) = message.payload else {
            return XCTFail("Expected a canonical message review")
        }
        XCTAssertEqual(data, Data([1]))

        let transactionParameters = NSMutableDictionary(dictionary: [
            "from": account.address, "to": "0x0000000000000000000000000000000000000002",
            "value": "0x1", "data": "0x", "nonce": "0x0", "gas": "0x5208", "gasPrice": "0x1"
        ])
        let transactionSnapshot = try fixture.enqueue(
            id: 52, name: "signTransaction", provider: .ethereum,
            body: ["address": account.address, "chainId": "0x1", "object": transactionParameters]
        )
        transactionParameters["to"] = "0x0000000000000000000000000000000000000003"
        transactionParameters["data"] = "0x1234"
        guard case .approval(let transactionIntent) = DappRequestProcessor().prepare(
            try XCTUnwrap(transactionSnapshot.requestBinding), catalog: catalog
        ), case .approveTransaction(let transaction) = transactionIntent.action else {
            return XCTFail("Expected a canonical transaction review")
        }
        XCTAssertEqual(transaction.transaction.to, "0x0000000000000000000000000000000000000002")
        XCTAssertEqual(transaction.transaction.data, "0x")

        var network = approvedEthereumNetwork()
        network.chainId = "0x7ffffffffffffffe"
        let definition = NSMutableDictionary(dictionary: try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(network)) as? [String: Any]
        ))
        let networkSnapshot = try fixture.enqueue(
            id: 53, name: "addEthereumChain", provider: .ethereum,
            body: ["address": account.address, "chainId": "0x1", "object": definition]
        )
        definition["rpcUrls"] = ["https://different.example/rpc"]
        guard case .approval(let networkIntent) = DappRequestProcessor().prepare(
            try XCTUnwrap(networkSnapshot.requestBinding), catalog: catalog
        ), case .addEthereumChain(let addition) = networkIntent.action else {
            return XCTFail("Expected a canonical network review")
        }
        XCTAssertEqual(addition.chainToAdd.rpcUrls, network.rpcUrls)
    }

    func testApprovedCompletionRejectsDifferentSigningFamiliesAndBatchLength() async throws {
        let (ethereumRequest, ethereumApproval) = try processorMessageApproval(coin: .ethereum)
        let (ethereumPermit, _) = try await executeProcessor(
            request: ethereumRequest, approval: ethereumApproval,
            signer: ProcessorWalletSigner(result: .success(.ethereumSignature("approved")))
        )
        XCTAssertNil(ApprovedCompletion.signed(.solanaSignature("wrong-family"), permit: ethereumPermit))
        XCTAssertNil(PreparedBroadcast.signed(.ethereumSignature("approved"), permit: ethereumPermit))

        let (solanaRequest, solanaApproval) = try processorMessageApproval(coin: .solana, batch: true)
        let signatures = ["first", "second", "third"]
        let (solanaPermit, _) = try await executeProcessor(
            request: solanaRequest, approval: solanaApproval,
            signer: ProcessorWalletSigner(result: .success(.solanaSignatures(signatures)))
        )
        XCTAssertNil(ApprovedCompletion.signed(.ethereumSignature("wrong-family"), permit: solanaPermit))
        XCTAssertNil(ApprovedCompletion.signed(.solanaSignature("wrong-shape"), permit: solanaPermit))
        XCTAssertNil(ApprovedCompletion.signed(.solanaSignatures(["first"]), permit: solanaPermit))
        XCTAssertNotNil(ApprovedCompletion.signed(.solanaSignatures(signatures), permit: solanaPermit))
    }

    func testSigningResolvesExactAuthorizedWalletAmongDuplicateAddresses() throws {
        for coin in [WalletCoin.ethereum, .solana] {
            let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
            let account = processorAccount(privateKey: key, coin: coin)
            var request = try coin == .ethereum
                ? ethereumRequest(method: "signPersonalMessage", address: account.address, parameters: ["data": "0x01"])
                : solanaRequest(method: "signMessage", publicKey: account.address, parameters: ["message": "01"])
            let descriptor = WalletAccountDescriptor(walletID: "second", account: account)
            request.authorizedAccount = descriptor
            let catalog = WalletReviewCatalog(
                identity: WalletCatalogIdentity(generation: UUID(), catalogData: Data("duplicate accounts".utf8)),
                orderedAccounts: [
                    SpecificWalletAccount(walletId: "first", account: account),
                    SpecificWalletAccount(walletId: "second", account: account),
                ]
            )
            guard case .approval(let actionIntent) = DappRequestProcessor().prepare(try requestBindingForTesting(request), catalog: catalog),
              case .approveMessage(let action) = actionIntent.action else {
                return XCTFail("Expected the exact authorized account")
            }
            XCTAssertEqual(action.walletId, "second")
            let disconnected = try ApprovedExecutionTestFixture()
            let origin = "https://example.com"
            guard case .snapshot(let authority) = disconnected.store.configurationSnapshot(
                configurationKey: origin, profileIdentifier: nil
            ) else { return XCTFail("Expected disconnected authority") }
            let raw: [String: Any] = [
                "id": request.id, "name": request.name, "provider": request.provider.rawValue,
                "host": request.host, "configurationKey": origin,
                "enqueueAttempt": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                "admissionDeadline": Int(disconnected.now.addingTimeInterval(150).timeIntervalSince1970 * 1_000),
                "workflowVersion": ExtensionBridge.workflowVersion,
                "authority": authority.version.json, "body": requestBodyForTesting(request),
            ]
            let unowned = try XCTUnwrap(SafariRequest(json: raw))
            guard case .accepted(let ingress) = ExtensionBridge.dappIngressResult(request: unowned, rawObject: raw),
                  case .unauthorized = disconnected.store.enqueue(ingress: ingress, profileIdentifier: nil) else {
                return XCTFail("An address match must not substitute for a native grant")
            }
        }
    }

    func testAlreadyGrantedConnectReturnsNativeAccountWithoutAnotherApproval() throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        for coin in [WalletCoin.ethereum, .solana] {
            let account = processorAccount(privateKey: key, coin: coin)
            var request = try coin == .ethereum
                ? ethereumRequest(method: "requestAccounts")
                : solanaRequest(method: "connect", publicKey: "")
            request.authorizedAccount = WalletAccountDescriptor(walletID: "wallet", account: account)
            guard case .immediate(let responseResolution)? = DappRequestProcessor().prepareWithoutWallets(try requestBindingForTesting(request)) else {
                return XCTFail("Existing native grants must not prompt again")
            }
            let response = try XCTUnwrap(responseResolution.response(for: request))
            XCTAssertNil(response.mutation)
            XCTAssertTrue(response.approvedAccounts.isEmpty)
            if coin == .ethereum {
                XCTAssertEqual(response.json["result"] as? [String], [account.address.lowercased()])
            } else {
                XCTAssertEqual((response.json["result"] as? [String: String])?["publicKey"], account.address)
            }
        }
    }

    func testTrustedSolanaConnectUsesNativeGrantWithoutApproval() throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 2, count: 32)))
        let account = processorAccount(privateKey: key, coin: .solana)
        var request = try solanaRequest(method: "connect", publicKey: account.address, parameters: ["onlyIfTrusted": true])
        request.authorizedAccount = WalletAccountDescriptor(walletID: "wallet", account: account)
        guard case .immediate(let responseResolution)? = DappRequestProcessor().prepareWithoutWallets(try requestBindingForTesting(request)) else {
            return XCTFail("Trusted connect must not present an approval")
        }
        let response = try XCTUnwrap(responseResolution.response(for: request))
        XCTAssertEqual((response.json["result"] as? [String: String])?["publicKey"], account.address)
        request.authorizedAccount = nil
        guard case .immediate(let deniedResolution)? = DappRequestProcessor().prepareWithoutWallets(try requestBindingForTesting(request)) else {
            return XCTFail("An absent grant must not present an approval")
        }
        let denied = try XCTUnwrap(deniedResolution.response(for: request))
        XCTAssertEqual((denied.json["error"] as? [String: Any])?["code"] as? Int, 4100)
    }

    func testPreparedMessageKeepsReviewedPayloadAndUsesExplicitSigner() async throws {
        let privateKey = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        let account = processorAccount(privateKey: privateKey, coin: .ethereum)
        let request = try ethereumRequest(
            method: "signPersonalMessage",
            address: account.address,
            parameters: ["data": "0x7265766965776564"]
        )
        let reviewCatalog = processorCatalog(accounts: [account])
        let preparation = DappRequestProcessor().prepare(
            try requestBindingForTesting(request),
            catalog: reviewCatalog
        )
        guard case .approval(let actionIntent) = preparation,
              case .approveMessage(let action) = actionIntent.action,
              case .ethereumPersonalMessage(let data) = action.payload else {
            return XCTFail("Expected prepared personal-message bytes")
        }
        XCTAssertEqual(data, Data("reviewed".utf8))
        XCTAssertEqual(action.meta, "reviewed")

        let signature = try Ethereum.signPersonalMessage(data: data, privateKey: privateKey)
        let signer = ProcessorWalletSigner(result: .success(.ethereumSignature(signature)))
        let (permit, result) = try await executeProcessor(
            request: request,
            approval: try DappApprovalValidator.resolve(
                action: .approveMessage(action),
                decision: .message(.init(approvedAccount: WalletAccountDescriptor(walletID: action.walletId, account: action.account), solanaCluster: nil)),
                accounts: nil,
                networkResolver: Networks.withChainIdHex
            ).get(),
            signer: signer
        )
        guard case .completed(let completion) = result else {
            return XCTFail("Message signing must not broadcast")
        }
        let response = try XCTUnwrap(completion.response(for: permit))
        XCTAssertEqual(
            response.json["result"] as? String,
            try Ethereum.signPersonalMessage(data: Data("reviewed".utf8), privateKey: privateKey)
        )
        XCTAssertEqual(signer.signCalls, 1)
        guard case .rollback = await DappRequestProcessor().execute(permit: permit, signer: signer) else {
            return XCTFail("An approved execution cannot invoke the signer twice")
        }
        XCTAssertEqual(signer.signCalls, 1)
    }

    func testAccountSelectionExecutionUsesExactReviewedDerivationPath() async throws {
        let privateKey = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        let account = processorAccount(privateKey: privateKey, coin: .ethereum)
        let catalog = processorCatalog(accounts: [account])
        let request = try ethereumRequest(method: "requestAccounts", address: account.address)
        guard case .approval(let intent) = DappRequestProcessor().prepare(try requestBindingForTesting(request), catalog: catalog)
        else { return XCTFail("Expected account selection") }
        for path in [account.derivationPath, "m/44'/60'/0'/0/9"] {
            let decision = DappApprovalDecision.accountSelection(.init(
                accounts: [.init(
                    walletID: "wallet",
                    coin: .ethereum,
                    normalizedAddress: account.address.lowercased(),
                    derivationPath: path
                )],
                ethereumChainID: "0x1"
            ))
            let resolved = DappApprovalValidator.resolve(
                action: intent.action, decision: decision,
                accounts: catalog.orderedAccounts,
                networkResolver: Networks.withChainIdHex
            )
            if path == account.derivationPath {
                let (permit, result) = try await executeProcessor(
                    request: request, approval: try resolved.get(), signer: nil
                )
                guard case .completed(let completion) = result else {
                    return XCTFail("Account selection must not broadcast")
                }
                let response = try XCTUnwrap(completion.response(for: permit))
                XCTAssertEqual(response.json["result"] as? [String], [account.address])
                XCTAssertNotNil(response.mutation)
            } else {
                guard case .failure(.invalidDecision) = resolved else {
                    return XCTFail("A different derivation path must fail validation")
                }
            }
        }
    }

    func testSolanaPreparedBroadcastRequiresExplicitClusterAndDoesNotSend() async throws {
        let privateKey = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 2, count: 32)))
        let account = processorAccount(privateKey: privateKey, coin: .solana)
        let catalog = processorCatalog(accounts: [account])
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
        guard case .approval(let actionIntent) =
                DappRequestProcessor().prepare(try requestBindingForTesting(request), catalog: catalog),
              case .approveMessage(let action) = actionIntent.action else {
            return XCTFail("Expected prepared Solana broadcast")
        }
        XCTAssertEqual(action.solanaClusterOptions?.suggestedCluster, .devnet)
        guard case .failure(.invalidDecision) = DappApprovalValidator.resolve(
            action: .approveMessage(action),
            decision: .message(.init(approvedAccount: WalletAccountDescriptor(walletID: action.walletId, account: action.account), solanaCluster: nil)),
            accounts: nil, networkResolver: Networks.withChainIdHex
        ) else { return XCTFail("A missing cluster must fail validation") }

        guard case .solanaLegacyBroadcast(let preparedTransaction, let options) = action.payload else {
            return XCTFail("Expected a legacy broadcast payload")
        }
        let signedTransaction = try XCTUnwrap(Solana.signedTransactionForSignAndSend(
            preparedLegacyTransaction: preparedTransaction,
            privateKey: privateKey
        ))
        let expectedSignature = try XCTUnwrap(Solana.transactionSignature(
            signedTransaction: signedTransaction
        ))
        let signer = ProcessorWalletSigner(result: .success(.solanaTransaction(
            signedTransaction: signedTransaction,
            signature: expectedSignature,
            cluster: .testnet,
            options: options
        )))
        let (permit, result) = try await executeProcessor(
            request: request,
            approval: try DappApprovalValidator.resolve(
                action: .approveMessage(action),
                decision: .message(.init(approvedAccount: WalletAccountDescriptor(walletID: action.walletId, account: action.account), solanaCluster: .testnet)),
                accounts: nil, networkResolver: Networks.withChainIdHex
            ).get(),
            signer: signer
        )
        guard case .broadcast(let broadcast) = result else {
            return XCTFail("Execution must return a broadcast for the durable executor")
        }
        let signature = try XCTUnwrap(
            ((try XCTUnwrap(broadcast.recoveryCompletion(for: permit)?.response(for: permit)).json["error"] as? [String: Any])?["data"] as? [String: Any])?["signature"] as? String
        )
        let signatureData = try XCTUnwrap(WalletCrypto.base58Decode(string: signature))
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: privateKey.publicKeyData(coin: .solana)
        )
        XCTAssertTrue(publicKey.isValidSignature(signatureData, for: message))
        XCTAssertEqual(action.solanaClusterOptions?.suggestedCluster, .devnet)
        XCTAssertEqual(signer.signCalls, 1)
    }

    func testBroadcastDispatchRequiresTheExactCheckpointedBroadcastAndRunsOnce() async throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 2, count: 32)))
        let account = processorAccount(privateKey: key, coin: .solana)
        let descriptor = WalletAccountDescriptor(walletID: "wallet", account: account)
        let fixture = try ApprovedExecutionTestFixture()
        try fixture.establishGrant(descriptor)
        let message = SolanaMessageFixture.wireMessage(
            accountKeys: [key.publicKeyData(coin: .solana)], bodyAfterBlockhash: Data([0])
        )
        let snapshot = try fixture.enqueue(
            id: 2, name: "signAndSendTransaction", provider: .solana,
            body: ["publicKey": account.address, "object": ["params": [
                "message": WalletCrypto.base58Encode(data: message), "options": ["cluster": "testnet"]
            ]]]
        )
        guard case .approval(let actionIntent) = DappRequestProcessor().prepare(
            try XCTUnwrap(snapshot.requestBinding), catalog: processorCatalog(accounts: [account])
        ),
              case .approveMessage(let action) = actionIntent.action, case .solanaLegacyBroadcast(let transaction, let options) = action.payload else {
            return XCTFail("Expected a prepared Solana broadcast")
        }
        let permit = try fixture.authorize(
            snapshot: snapshot, action: .approveMessage(action),
            decision: .message(.init(approvedAccount: descriptor, solanaCluster: .testnet))
        )
        defer { permit.releaseLease() }
        XCTAssertTrue(permit.consumeExecution())
        let signed = try XCTUnwrap(Solana.signedTransactionForSignAndSend(preparedLegacyTransaction: transaction, privateKey: key))
        let signature = try XCTUnwrap(Solana.transactionSignature(signedTransaction: signed))
        let output = WalletSigningOutput.solanaTransaction(
            signedTransaction: signed, signature: signature, cluster: .testnet, options: options
        )
        let checkpointed = try XCTUnwrap(PreparedBroadcast.signed(output, permit: permit))
        let other = try XCTUnwrap(PreparedBroadcast.signed(output, permit: permit))
        guard case .prepared(let dispatch) = fixture.store.prepareBroadcast(permit: permit, broadcast: checkpointed) else {
            return XCTFail("Expected a durable broadcast checkpoint")
        }
        let sender = ProcessorBroadcastSender()
        let substituted = await other.dispatch(using: dispatch, sender: sender)
        XCTAssertNil(substituted)
        XCTAssertEqual(sender.sends, 0)
        let completed = await checkpointed.dispatch(using: dispatch, sender: sender)
        XCTAssertEqual(try XCTUnwrap(completed?.response(for: permit)).json["result"] as? String, signature)
        let duplicate = await checkpointed.dispatch(using: dispatch, sender: sender)
        XCTAssertNil(duplicate)
        XCTAssertEqual(sender.sends, 1)
    }

    func testUnavailableSigningAuthorizationRollsBackForBothProviders() async throws {
        for coin in [WalletCoin.ethereum, .solana] {
            let (request, approval) = try processorMessageApproval(coin: coin)
            let unavailable = ProcessorWalletSigner(result: .failure(.authorizationUnavailable))
            for signer in [nil, unavailable] as [ProcessorWalletSigner?] {
                let (permit, result) = try await executeProcessor(
                    request: request, approval: approval, signer: signer
                )
                guard case .rollback = result else {
                    return XCTFail("Unavailable authorization must return to approval")
                }
                guard case .rollback = await DappRequestProcessor().execute(permit: permit, signer: signer) else {
                    return XCTFail("A consumed permit cannot retry signing")
                }
            }
            XCTAssertEqual(unavailable.signCalls, 1)
        }
    }

    func testProcessorRejectsWrongSigningOutputs() async throws {
        let cases: [(WalletCoin, Bool, WalletSigningOutput)] = [
            (.ethereum, false, .solanaSignature("wrong-family")),
            (.solana, false, .ethereumSignature("wrong-family")),
            (.solana, true, .solanaSignatures(["wrong-count"])),
        ]
        for (coin, batch, output) in cases {
            let (request, approval) = try processorMessageApproval(coin: coin, batch: batch)
            let signer = ProcessorWalletSigner(result: .success(output))
            let (permit, result) = try await executeProcessor(
                request: request, approval: approval, signer: signer
            )
            guard case .completed(let completion) = result else {
                return XCTFail("Invalid signer output must produce a terminal failure")
            }
            let response = try XCTUnwrap(completion.response(for: permit))
            XCTAssertEqual((response.json["error"] as? [String: Any])?["code"] as? Int, -32603)
            XCTAssertNil(response.json["result"])
            XCTAssertTrue(response.approvalCommitted)
            XCTAssertEqual(signer.signCalls, 1)
        }
    }

    func testReleasedPermitDiscardsSuspendedSigningResultForBothProviders() async throws {
        for coin in [WalletCoin.ethereum, .solana] {
            let (request, approval) = try processorMessageApproval(coin: coin)
            let permit = try processorPermit(request: request, approval: approval)
            let output: WalletSigningOutput = coin == .ethereum
                ? .ethereumSignature("late") : .solanaSignature("late")
            let signer = ProcessorWalletSigner(result: .success(output))
            let started = expectation(description: "signer suspended")
            var continuation: CheckedContinuation<Void, Never>?
            signer.beforeResult = {
                await withCheckedContinuation {
                    continuation = $0
                    started.fulfill()
                }
            }
            let task = Task { await DappRequestProcessor().execute(permit: permit, signer: signer) }
            await fulfillment(of: [started], timeout: 1)
            permit.releaseLease()
            try XCTUnwrap(continuation).resume()
            guard case .rollback = await task.value else {
                return XCTFail("A released permit must discard a late signature")
            }
            XCTAssertEqual(signer.signCalls, 1)
        }
    }

    func testSignerFailuresKeepProviderErrorCodes() async throws {
        let cases: [(WalletCoin, WalletSigningFailure, Int, String)] = [
            (.ethereum, .failedToSign, ProviderResponseError.internalErrorCode, Strings.failedToSign),
            (.ethereum, .invalidTransaction, ProviderResponseError.internalErrorCode, Strings.somethingWentWrong),
            (.solana, .failedToSign, ProviderResponseError.internalErrorCode, Strings.failedToSign),
            (.solana, .invalidTransaction, 4200, Strings.somethingWentWrong),
        ]
        for (coin, failure, code, message) in cases {
            let (request, approval) = try processorMessageApproval(coin: coin)
            let signer = ProcessorWalletSigner(result: .failure(failure))
            let (permit, result) = try await executeProcessor(
                request: request, approval: approval, signer: signer
            )
            guard case .completed(let completion) = result else {
                return XCTFail("Signing failures must produce terminal provider errors")
            }
            let response = try XCTUnwrap(completion.response(for: permit))
            let error = try XCTUnwrap(response.json["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? Int, code)
            XCTAssertEqual(error["message"] as? String, message)
            XCTAssertNil(error["data"])
            XCTAssertNil(response.json["result"])
            XCTAssertTrue(response.approvalCommitted)
            XCTAssertEqual(signer.signCalls, 1)
        }
    }

    func testSolanaPreparationPreservesInvalidSendOptionsError() throws {
        let privateKey = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 2, count: 32)))
        let account = processorAccount(privateKey: privateKey, coin: .solana)
        let message = SolanaMessageFixture.wireMessage(
            accountKeys: [privateKey.publicKeyData(coin: .solana)],
            bodyAfterBlockhash: Data([0])
        )
        let request = try solanaRequest(
            method: "signAndSendTransaction",
            publicKey: account.address,
            parameters: [
                "message": WalletCrypto.base58Encode(data: message),
                "options": ["skipPreflight": true],
            ]
        )
        guard case .immediate(let responseResolution) = DappRequestProcessor().prepare(
            try requestBindingForTesting(request), catalog: processorCatalog(accounts: [account])
        ) else { return XCTFail("Invalid send options must fail before approval") }
        let response = try XCTUnwrap(responseResolution.response(for: request))
        let error = try XCTUnwrap(response.json["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, 4200)
        XCTAssertEqual(error["message"] as? String, Strings.unsupportedSolanaSendOptions)
        XCTAssertNil(error["data"])
        XCTAssertNil(response.json["result"])
    }

    func testSolanaPreparationPreservesMissingPayloadAndAuthorizationErrorOrder() throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 2, count: 32)))
        let account = processorAccount(privateKey: key, coin: .solana)
        let cases: [(String, [String: Any], Int)] = [
            ("signAllTransactions", [:], 4200),
            ("signAllTransactions", ["messages": ["not-base58!"]], 4100),
            ("signMessage", ["message": "not-hex", "messageEncoding": "hex"], 4100),
            ("signAndSendTransaction", ["message": "not-base58!", "options": ["skipPreflight": true]], 4100),
        ]
        for (method, parameters, expectedCode) in cases {
            var request = try solanaRequest(method: method, publicKey: account.address, parameters: parameters)
            request.authorizedAccount = nil
            guard case .solana(let body) = request.body else { return XCTFail("Expected a Solana request") }
            guard case .immediate(let resolution) = SolanaDappRequestProcessor.prepare(
                request: request, body: body, catalog: processorCatalog(accounts: [account])
            ) else { return XCTFail("Unapproved or malformed requests must not reach review") }
            let response = try XCTUnwrap(resolution.response(for: request))
            XCTAssertEqual((response.json["error"] as? [String: Any])?["code"] as? Int, expectedCode)
            XCTAssertEqual(response.authorizationFailure, expectedCode == 4100)
            if expectedCode == 4100 {
                XCTAssertEqual(response.mutation, .revokeSolana(account.address))
            } else {
                XCTAssertNil(response.mutation)
            }
        }
    }

    func testSolanaTypedSignerOutputsPreserveSignatureOrder() async throws {
        let (request, approval) = try processorMessageApproval(coin: .solana)
        let singleSigner = ProcessorWalletSigner(result: .success(.solanaSignature("first")))
        let (singlePermit, singleResult) = try await executeProcessor(
            request: request, approval: approval, signer: singleSigner
        )
        guard case .completed(let singleCompletion) = singleResult else {
            return XCTFail("A signature must produce a response")
        }
        let singleResponse = try XCTUnwrap(singleCompletion.response(for: singlePermit))
        XCTAssertEqual(singleResponse.json["result"] as? String, "first")

        let signatures = ["first", "second", "third"]
        let batchSigner = ProcessorWalletSigner(result: .success(.solanaSignatures(signatures)))
        let (batchRequest, batchApproval) = try processorMessageApproval(coin: .solana, batch: true)
        let (batchPermit, batchResult) = try await executeProcessor(
            request: batchRequest, approval: batchApproval, signer: batchSigner
        )
        guard case .completed(let batchCompletion) = batchResult else {
            return XCTFail("A batch must produce a response")
        }
        let batchResponse = try XCTUnwrap(batchCompletion.response(for: batchPermit))
        XCTAssertEqual(batchResponse.json["result"] as? [String], signatures)
        XCTAssertEqual(singleSigner.signCalls, 1)
        XCTAssertEqual(batchSigner.signCalls, 1)
    }

    private func processorMessageApproval(
        coin: WalletCoin,
        batch: Bool = false
    ) throws -> (SafariRequest, DappApprovalValidator.Approval) {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        let account = processorAccount(privateKey: key, coin: coin)
        let request: SafariRequest
        if coin == .ethereum {
            request = try ethereumRequest(
                method: "signPersonalMessage",
                address: account.address,
                parameters: ["data": "0x7265766965776564"]
            )
        } else if batch {
            let message = WalletCrypto.base58Encode(data: SolanaMessageFixture.wireMessage(
                accountKeys: [key.publicKeyData(coin: .solana)],
                bodyAfterBlockhash: Data([0])
            ))
            request = try solanaRequest(
                method: "signAllTransactions", publicKey: account.address,
                parameters: ["messages": [message, message, message]]
            )
        } else {
            request = try solanaRequest(
                method: "signMessage", publicKey: account.address,
                parameters: ["message": "reviewed", "messageEncoding": "utf8"]
            )
        }
        guard case .approval(let actionIntent) = DappRequestProcessor().prepare(
            try requestBindingForTesting(request), catalog: processorCatalog(accounts: [account])
        ),
              case .approveMessage(let action) = actionIntent.action else {
            throw NSError(domain: "DappRequestProcessorTests", code: 1)
        }
        return (request, try DappApprovalValidator.resolve(
            action: .approveMessage(action),
            decision: .message(.init(
                approvedAccount: WalletAccountDescriptor(walletID: action.walletId, account: account),
                solanaCluster: nil
            )),
            accounts: nil,
            networkResolver: Networks.withChainIdHex
        ).get())
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
                        coin: coin,
                        normalizedAddress: coin.normalizedAddress(address),
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
        let identity = WalletAccountDescriptor(walletID: "wallet", account: account)
        let invalidIdentities: [WalletAccountDescriptor] = [
            .init(walletID: "other", coin: .ethereum, normalizedAddress: identity.normalizedAddress,
                  derivationPath: account.derivationPath),
            .init(walletID: "wallet", coin: .ethereum,
                  normalizedAddress: "0x0000000000000000000000000000000000000000",
                  derivationPath: account.derivationPath),
            .init(walletID: "wallet", coin: .solana, normalizedAddress: identity.normalizedAddress,
                  derivationPath: account.derivationPath),
            .init(walletID: "wallet", coin: .ethereum, normalizedAddress: identity.normalizedAddress,
                  derivationPath: "m/44'/60'/0'/0/9"),
        ]
        let cases = invalidIdentities.map { ([$0], [account]) } + [
            ([identity, identity], [account]),
            ([identity], [account, account]),
            ([identity], []),
        ]
        for (identities, accounts) in cases {
            let catalog = processorCatalog(accounts: accounts)
            guard case .failure(.invalidDecision) = DappApprovalValidator.resolve(
                action: .selectAccount(action),
                decision: .accountSelection(.init(accounts: identities, ethereumChainID: nil)),
                accounts: catalog.orderedAccounts,
                networkResolver: Networks.withChainIdHex
            ) else { return XCTFail("Invalid selections must fail validation") }
        }
    }

    func testApprovalSelectionRequiresResolvedNetworksOnlyForNonemptySelection() throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        for coin in [WalletCoin.ethereum, .solana] {
            let account = processorAccount(privateKey: key, coin: coin)
            let catalog = [SpecificWalletAccount(walletId: "wallet", account: account)]
            let identity = WalletAccountDescriptor(walletID: "wallet", account: account)
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

    func testInvalidMessageDecisionsFailValidation() async throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        for coin in [WalletCoin.ethereum, .solana] {
            let account = processorAccount(privateKey: key, coin: coin)
            let action = SignMessageAction(
                subject: .signMessage, walletId: "wallet", account: account, meta: "reviewed",
                payload: coin == .ethereum ? .ethereumMessage(Data()) : .solanaMessage(Data())
            )
            for decision in [DappApprovalDecision.message(.init(approvedAccount: WalletAccountDescriptor(walletID: action.walletId, account: action.account), solanaCluster: .devnet)),
                             .addEthereumChain] {
                guard case .failure(.invalidDecision) = DappApprovalValidator.resolve(
                    action: .approveMessage(action), decision: decision,
                    accounts: nil, networkResolver: Networks.withChainIdHex
                ) else { return XCTFail("Invalid decisions must fail validation") }
            }
        }
    }

    func testMessageApprovalResolvesEveryPayloadWithOnlyItsRequiredCluster() throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        let solanaAccount = processorAccount(privateKey: key, coin: .solana)
        let messageData = SolanaMessageFixture.wireMessage(
            accountKeys: [key.publicKeyData(coin: .solana)],
            bodyAfterBlockhash: Data.encodeLength(0)
        )
        let message = WalletCrypto.base58Encode(data: messageData)
        let transaction = try Solana.shared.preparedTransactionMessageForSigning(
            message: message,
            publicKey: solanaAccount.address
        ).get()
        let legacy = try Solana.shared.preparedLegacySignAndSendTransaction(
            message: message,
            publicKey: solanaAccount.address
        ).get()
        let serialized = try Solana.shared.preparedSerializedTransactionForSignAndSend(
            serializedTransaction: WalletCrypto.base58Encode(
                data: Data([1]) + Data(repeating: 0, count: 64) + messageData
            ),
            publicKey: solanaAccount.address
        ).get()
        let options = Solana.PreparedSendOptions(
            clusterHint: .devnet,
            preflightCommitment: .confirmed,
            maxRetries: 3,
            minContextSlot: 12,
            confirmationCommitment: .finalized
        )
        let cases: [(SignMessageAction.Payload, Bool)] = [
            (.ethereumMessage(Data("digest".utf8)), false),
            (.ethereumPersonalMessage(Data("personal message".utf8)), false),
            (.ethereumTypedData("typed data"), false),
            (.solanaMessage(Data("solana message".utf8)), false),
            (.solanaTransaction(transaction), false),
            (.solanaTransactions([transaction, transaction]), false),
            (.solanaLegacyBroadcast(legacy, options), true),
            (.solanaSerializedBroadcast(serialized, options), true),
        ]
        for (payload, requiresCluster) in cases {
            let account = processorAccount(privateKey: key, coin: payload.coin)
            let descriptor = WalletAccountDescriptor(walletID: "wallet", account: account)
            let action = SignMessageAction(
                subject: .signMessage,
                walletId: descriptor.walletID,
                account: account,
                meta: "reviewed",
                payload: payload
            )
            for cluster in [nil] + Solana.Cluster.allCases.map(Optional.some) {
                let result = DappApprovalValidator.resolve(
                    action: .approveMessage(action),
                    decision: .message(.init(approvedAccount: descriptor, solanaCluster: cluster)),
                    accounts: nil,
                    networkResolver: { _ in nil }
                )
                guard requiresCluster == (cluster != nil) else {
                    guard case .failure(.invalidDecision) = result else {
                        return XCTFail("The cluster must be present exactly for broadcasts")
                    }
                    continue
                }
                let approval = try result.get()
                guard case .signing(let approvedAccount, let approvedPayload) = approval.kind else {
                    return XCTFail("Expected a resolved signing payload")
                }
                XCTAssertEqual(approvedAccount, descriptor)
                XCTAssertEqual(approvedPayload.coin, payload.coin)
                XCTAssertFalse(approvedPayload.isEthereumTransaction)
                switch (payload, approvedPayload) {
                case (.ethereumMessage(let expected), .ethereumMessage(let actual)),
                     (.ethereumPersonalMessage(let expected), .ethereumPersonalMessage(let actual)),
                     (.solanaMessage(let expected), .solanaMessage(let actual)):
                    XCTAssertEqual(actual, expected)
                case (.ethereumTypedData(let expected), .ethereumTypedData(let actual)):
                    XCTAssertEqual(actual, expected)
                case (.solanaTransaction(let expected), .solanaTransaction(let actual)):
                    XCTAssertEqual(actual.messageData, expected.messageData)
                case (.solanaTransactions(let expected), .solanaTransactions(let actual)):
                    XCTAssertEqual(actual.map(\.messageData), expected.map(\.messageData))
                case (.solanaLegacyBroadcast(let expected, _),
                      .solanaLegacyBroadcast(let actual, let actualOptions, let actualCluster)):
                    XCTAssertEqual(actual.preparedMessage.messageData, expected.preparedMessage.messageData)
                    XCTAssertEqual(actualCluster, cluster)
                    XCTAssertEqual(actualOptions.rpcOptions as NSDictionary, options.rpcOptions as NSDictionary)
                    XCTAssertEqual(actualOptions.clusterHint, options.clusterHint)
                    XCTAssertEqual(actualOptions.confirmationCommitment, options.confirmationCommitment)
                case (.solanaSerializedBroadcast(let expected, _),
                      .solanaSerializedBroadcast(let actual, let actualOptions, let actualCluster)):
                    XCTAssertEqual(actual.preparedMessage.messageData, expected.preparedMessage.messageData)
                    XCTAssertEqual(actualCluster, cluster)
                    XCTAssertEqual(actualOptions.rpcOptions as NSDictionary, options.rpcOptions as NSDictionary)
                    XCTAssertEqual(actualOptions.clusterHint, options.clusterHint)
                    XCTAssertEqual(actualOptions.confirmationCommitment, options.confirmationCommitment)
                default:
                    XCTFail("Approval must preserve the signing mode and payload")
                }
            }
        }
    }

    func testMessageDecisionChecksIdentityBeforeInvalidCluster() throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        let account = processorAccount(privateKey: key, coin: .ethereum)
        let action = SignMessageAction(
            subject: .signMessage,
            walletId: "reviewed-wallet",
            account: account,
            meta: "reviewed",
            payload: .ethereumMessage(Data())
        )
        guard case .failure(.staleAccount) = DappApprovalValidator.resolve(
            action: .approveMessage(action),
            decision: .message(.init(
                approvedAccount: WalletAccountDescriptor(walletID: "other-wallet", account: account),
                solanaCluster: .devnet
            )),
            accounts: nil,
            networkResolver: { _ in nil }
        ) else { return XCTFail("A stale account must take precedence over a malformed decision") }
    }

    func testMessageDecisionRejectsAnotherWalletWithTheSameAddress() throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        for coin in [WalletCoin.ethereum, .solana] {
            let account = processorAccount(privateKey: key, coin: coin)
            var request = try coin == .ethereum
                ? ethereumRequest(method: "signPersonalMessage", address: account.address,
                                  parameters: ["data": "0x7265766965776564"])
                : solanaRequest(method: "signMessage", publicKey: account.address,
                                parameters: ["message": "7265766965776564", "messageEncoding": "hex"])
            let original = SpecificWalletAccount(walletId: "reviewed-wallet", account: account)
            let duplicate = SpecificWalletAccount(walletId: "duplicate-wallet", account: account)
            request.authorizedAccount = WalletAccountDescriptor(walletID: original.walletId, account: original.account)
            let identity = processorCatalog(accounts: [account]).identity
            let processor = DappRequestProcessor()
            guard case .approval(let reviewedIntent) = processor.prepare(
                try requestBindingForTesting(request),
                catalog: WalletReviewCatalog(identity: identity, orderedAccounts: [original, duplicate])
            ),
              case .approveMessage(let reviewed) = reviewedIntent.action else { return XCTFail("Expected a signing review") }
            let approvedAccount = WalletAccountDescriptor(walletID: reviewed.walletId, account: reviewed.account)
            let decision = DappApprovalDecision.message(.init(
                approvedAccount: approvedAccount,
                solanaCluster: nil
            ))
            let approval = try DappApprovalValidator.resolve(
                action: .approveMessage(reviewed), decision: decision,
                accounts: nil, networkResolver: { _ in nil }
            ).get()
            XCTAssertEqual(approval.signingAccount, approvedAccount)

            guard case .approval(let rematerialized) = processor.prepare(
                try requestBindingForTesting(request),
                catalog: WalletReviewCatalog(identity: identity, orderedAccounts: [duplicate, original])
            ) else { return XCTFail("Reordering must preserve the authorized account") }
            guard case .success(let repeated) = DappApprovalValidator.resolve(
                action: rematerialized.action, decision: decision,
                accounts: nil, networkResolver: { _ in nil }
            ) else { return XCTFail("The exact grant must remain valid after reordering") }
            XCTAssertEqual(repeated.signingAccount, approvedAccount)
            guard case .immediate = processor.prepare(
                try requestBindingForTesting(request),
                catalog: WalletReviewCatalog(identity: identity, orderedAccounts: [duplicate])
            ) else { return XCTFail("A different wallet must not replace the authorized account") }
        }
    }

    func testMessageDecisionChecksAllAccountIdentityFields() throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        for coin in [WalletCoin.ethereum, .solana] {
            let account = processorAccount(privateKey: key, coin: coin)
            let action = SignMessageAction(
                subject: .signMessage, walletId: "wallet", account: account, meta: "reviewed",
                payload: coin == .ethereum ? .ethereumMessage(Data()) : .solanaMessage(Data())
            )
            let exact = WalletAccountDescriptor(walletID: action.walletId, account: account)
            let scopes: [WalletAccountDescriptor] = [
                exact,
                .init(walletID: "other", coin: coin, normalizedAddress: exact.normalizedAddress,
                      derivationPath: exact.derivationPath),
                .init(walletID: exact.walletID, coin: coin == .ethereum ? .solana : .ethereum,
                      normalizedAddress: exact.normalizedAddress, derivationPath: exact.derivationPath),
                .init(walletID: exact.walletID, coin: coin, normalizedAddress: "other-address",
                      derivationPath: exact.derivationPath),
                .init(walletID: exact.walletID, coin: coin, normalizedAddress: exact.normalizedAddress,
                      derivationPath: exact.derivationPath + "/1"),
            ]
            for scope in scopes {
                let result = DappApprovalValidator.resolve(
                    action: .approveMessage(action),
                    decision: .message(.init(approvedAccount: scope, solanaCluster: nil)),
                    accounts: nil, networkResolver: { _ in nil }
                )
                if scope == exact {
                    XCTAssertEqual(try result.get().signingAccount, exact)
                } else {
                    guard case .failure(.staleAccount) = result else {
                        return XCTFail("Every signing identity field must match")
                    }
                }
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
            transaction, reviewedNetwork: network,
            approvedAccount: WalletAccountDescriptor(walletID: action.walletId, account: action.account)
        ))
        guard case .success(let approval) = DappApprovalValidator.resolve(
            action: .approveTransaction(action), decision: .transaction(execution),
            accounts: nil, networkResolver: { _ in nil }
        ), case .signing(let approvedAccount, .ethereumTransaction(let rebuilt, let approvedNetwork)) = approval.kind else {
            return XCTFail("Expected a ready reconstructed transaction")
        }
        XCTAssertEqual(approvedAccount, execution.approvedAccount)
        XCTAssertEqual(approvedNetwork, network)
        XCTAssertEqual(rebuilt.nonce, transaction.nonce)
        XCTAssertEqual(rebuilt.gas, transaction.gas)
        XCTAssertEqual(rebuilt.preparedFee, transaction.preparedFee)

        let replacedAccountAction = SendTransactionAction(
            transaction: transaction, resolvedNetwork: network,
            walletId: "duplicate-wallet", account: account
        )
        guard case .failure(.staleAccount) = DappApprovalValidator.resolve(
            action: .approveTransaction(replacedAccountAction), decision: .transaction(execution),
            accounts: nil, networkResolver: { _ in nil }
        ) else { return XCTFail("The transaction must remain bound to the reviewed wallet") }

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
            unready, reviewedNetwork: network,
            approvedAccount: WalletAccountDescriptor(walletID: action.walletId, account: action.account)
        ))
        guard case .failure(.invalidDecision) = DappApprovalValidator.resolve(
            action: .approveTransaction(action), decision: .transaction(unreadyExecution),
            accounts: nil, networkResolver: { _ in nil }
        ) else { return XCTFail("Insufficient fees must be an invalid decision") }
    }

    func testApprovalTransactionPreservesFullWidthExecutionQuantities() throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        let account = processorAccount(privateKey: key, coin: .ethereum)
        let network = try XCTUnwrap(resolvedEthereumNetworkResolution().resolvedNetwork)
        let original = Transaction(
            from: account.address, to: account.address, nonce: "0x1", gas: "0x5208",
            value: "0x0", data: "0x", preparedFee: .legacy(gasPrice: 10)
        )
        let action = SendTransactionAction(
            transaction: original, resolvedNetwork: network,
            walletId: "wallet", account: account
        )
        let maximum = Transaction.maximumUInt256
        let fees: [PreparedTransactionFee] = [
            .legacy(gasPrice: maximum),
            .eip1559(maxPriorityFeePerGas: maximum - 1, maxFeePerGas: maximum),
        ]
        for fee in fees {
            var reviewed = original
            reviewed.nonce = "0x00" + maximum.toHexString()
            reviewed.gas = "0x00" + maximum.toHexString()
            reviewed.replacePreparedFee(fee, provenance: .init(source: .manual, for: fee))
            reviewed.currentBaseFeePerGas = 1
            reviewed.nextBaseFeePerGas = maximum
            let execution = try XCTUnwrap(DappApprovalDecision.TransactionExecution(
                reviewed, reviewedNetwork: network,
                approvedAccount: WalletAccountDescriptor(walletID: action.walletId, account: action.account)
            ))
            let rebuilt = try XCTUnwrap(execution.applying(to: action))
            XCTAssertEqual(rebuilt.nonce, maximum.toHexString(withPrefix: true))
            XCTAssertEqual(rebuilt.gas, maximum.toHexString(withPrefix: true))
            XCTAssertEqual(rebuilt.preparedFee, fee)
            XCTAssertEqual(rebuilt.feeProvenance, reviewed.feeProvenance)
            XCTAssertEqual(rebuilt.currentBaseFeePerGas, maximum)
            XCTAssertNil(rebuilt.nextBaseFeePerGas)
        }
    }

    func testApprovalTransactionRejectsInvalidExecutionQuantitiesAtConstruction() throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        let account = processorAccount(privateKey: key, coin: .ethereum)
        let network = try XCTUnwrap(resolvedEthereumNetworkResolution().resolvedNetwork)
        let transaction = Transaction(
            from: account.address, to: account.address, nonce: "0x1", gas: "0x5208",
            value: "0x0", data: "0x", preparedFee: .legacy(gasPrice: 10)
        )
        let invalidQuantities: [String?] = [
            nil,
            "0x",
            "-1",
            (Transaction.maximumUInt256 + 1).toHexString(withPrefix: true),
        ]
        for quantity in invalidQuantities {
            for field in [\Transaction.nonce, \Transaction.gas] {
                var invalid = transaction
                invalid[keyPath: field] = quantity
                XCTAssertNil(DappApprovalDecision.TransactionExecution(
                    invalid, reviewedNetwork: network,
                    approvedAccount: WalletAccountDescriptor(walletID: "wallet", account: account)
                ))
            }
        }
    }

    func testApprovalTransactionRetainsSemanticRejectionsWhenApplying() throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        let account = processorAccount(privateKey: key, coin: .ethereum)
        let network = try XCTUnwrap(resolvedEthereumNetworkResolution().resolvedNetwork)
        let original = Transaction(
            from: account.address, to: account.address, nonce: "0x1", gas: "0x5208",
            value: "0x0", data: "0x", preparedFee: .legacy(gasPrice: 10)
        )
        let action = SendTransactionAction(
            transaction: original, resolvedNetwork: network,
            walletId: "wallet", account: account
        )
        let overflow = Transaction.maximumUInt256 + 1
        let invalidEdits: [(String, (inout Transaction) -> Void)] = [
            ("zero gas", { $0.gas = "0x0" }),
            ("legacy fee overflow", { $0.preparedFee = .legacy(gasPrice: overflow) }),
            ("priority fee overflow", {
                $0.preparedFee = .eip1559(maxPriorityFeePerGas: overflow, maxFeePerGas: overflow)
            }),
            ("maximum fee overflow", {
                $0.preparedFee = .eip1559(maxPriorityFeePerGas: 1, maxFeePerGas: overflow)
            }),
            ("priority exceeds maximum", {
                $0.preparedFee = .eip1559(maxPriorityFeePerGas: 11, maxFeePerGas: 10)
            }),
            ("legacy priority provenance", { $0.feeProvenance.maxPriorityFeePerGas = .manual }),
            ("legacy maximum provenance", { $0.feeProvenance.maxFeePerGas = .manual }),
            ("dynamic legacy provenance", {
                $0.preparedFee = .eip1559(maxPriorityFeePerGas: 1, maxFeePerGas: 10)
                $0.feeProvenance.gasPrice = .manual
            }),
            ("current base fee overflow", { $0.currentBaseFeePerGas = overflow }),
            ("next base fee overflow", { $0.nextBaseFeePerGas = overflow }),
        ]
        for (name, edit) in invalidEdits {
            var invalid = original
            edit(&invalid)
            let execution = try XCTUnwrap(DappApprovalDecision.TransactionExecution(
                invalid, reviewedNetwork: network,
                approvedAccount: WalletAccountDescriptor(walletID: action.walletId, account: action.account)
            ), name)
            XCTAssertNil(execution.applying(to: action), name)
            guard case .failure(.staleTransaction) = DappApprovalValidator.resolve(
                action: .approveTransaction(action), decision: .transaction(execution),
                accounts: nil, networkResolver: { _ in nil }
            ) else { return XCTFail("Invalid execution fields must remain stale: \(name)") }
        }
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
        let (permit, result) = try await executeProcessor(
            request: request,
            approval: try DappApprovalValidator.resolve(
                action: .switchAccount(action),
                decision: .accountSelection(.init(
                    accounts: [], ethereumChainID: "0x7fffffffffffffff"
                )),
                accounts: [], networkResolver: Networks.withChainIdHex
            ).get(),
            signer: nil
        )
        guard case .completed(let completion) = result else {
            return XCTFail("Disconnecting must not broadcast")
        }
        let response = try XCTUnwrap(completion.response(for: permit))
        XCTAssertNil(response.json["error"])
        XCTAssertEqual(response.mutation, .accounts([.disconnectEthereum]))
    }

    private func executeProcessor(
        request: SafariRequest,
        approval: DappApprovalValidator.Approval,
        signer: (any WalletSigning)?
    ) async throws -> (ExtensionBridge.ApprovedExecutionPermit, ApprovedExecutionResult) {
        let permit = try processorPermit(request: request, approval: approval)
        return (permit, await DappRequestProcessor().execute(permit: permit, signer: signer))
    }

    private func processorPermit(
        request: SafariRequest,
        approval: DappApprovalValidator.Approval
    ) throws -> ExtensionBridge.ApprovedExecutionPermit {
        let fixture = try ApprovedExecutionTestFixture()
        if let account = request.authorizedAccount, account.isValid {
            try fixture.establishGrant(account)
        }
        let action: DappRequestAction
        let decision: DappApprovalDecision
        var accounts: [SpecificWalletAccount]?
        switch approval.kind {
        case .accountSelection(let selectionAction, let selection):
            action = request.provider == .unknown ? .switchAccount(selectionAction) : .selectAccount(selectionAction)
            decision = .accountSelection(.init(
                accounts: selection.accounts.map { WalletAccountDescriptor(walletID: $0.walletId, account: $0.account) },
                ethereumChainID: selection.network?.chainIdHexString
            ))
            accounts = selection.accounts
            for provider in selectionAction.initiallyConnectedProviders {
                guard let coin = WalletCoin.correspondingToInpageProvider(provider) else { continue }
                let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
                try fixture.establishGrant(WalletAccountDescriptor(
                    walletID: "wallet", account: processorAccount(privateKey: key, coin: coin)
                ))
            }
        case .signing(let account, let payload):
            let catalog = WalletReviewCatalog(
                identity: .init(generation: nil, catalogData: Data()),
                orderedAccounts: [account.specificAccount]
            )
            guard case .approval(let prepared) = DappRequestProcessor().prepare(try requestBindingForTesting(request), catalog: catalog) else {
                throw CocoaError(.coderInvalidValue)
            }
            action = prepared.action
            switch payload {
            case .ethereumTransaction(let transaction, let network):
                decision = .transaction(try XCTUnwrap(.init(
                    transaction, reviewedNetwork: network, approvedAccount: account
                )))
            case .solanaLegacyBroadcast(_, _, let cluster), .solanaSerializedBroadcast(_, _, let cluster):
                decision = .message(.init(approvedAccount: account, solanaCluster: cluster))
            default:
                decision = .message(.init(approvedAccount: account, solanaCluster: nil))
            }
        case .addEthereumChain(let addition):
            action = .addEthereumChain(addition)
            decision = .addEthereumChain
        }
        let body: [String: Any]
        switch request.body {
        case .ethereum(let ethereum):
            body = ["address": ethereum.address,
                    "chainId": String.hex(ethereum.currentChainId ?? 1, withPrefix: true),
                    "object": ethereum.parameters ?? [:]]
        case .solana(let solana):
            var parameters = [String: Any]()
            parameters["message"] = solana.message
            parameters["messages"] = solana.messages
            parameters["transaction"] = solana.transaction
            parameters["options"] = solana.sendOptions
            parameters["onlyIfTrusted"] = solana.onlyIfTrusted
            parameters["messageEncoding"] = solana.signMessageEncoding == .utf8 ? "utf8" : "hex"
            parameters["display"] = solana.displayHex ? "hex" : "utf8"
            body = ["publicKey": solana.publicKey, "object": ["params": parameters]]
        case .unknown:
            body = [:]
        }
        let snapshot = try fixture.enqueue(id: request.id, name: request.name, provider: request.provider, body: body)
        return try fixture.authorize(snapshot: snapshot, action: action, decision: decision, accounts: accounts)
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
            (response.json["error"] as? [String: Any])?["message"] as? String,
            Strings.privateBrowsingUnsupported
        )
        XCTAssertEqual((response.json["error"] as? [String: Any])?["code"] as? Int, 4200)
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
            (ethereumResponse.json["error"] as? [String: Any])?["message"] as? String,
            Strings.transactionSubmissionStatusUnknown
        )
        XCTAssertEqual(
            (ethereumResponse.json["error"] as? [String: Any])?["code"] as? Int,
            ProviderResponseError.transactionSubmissionUnknownCode
        )
        let decodedData = try XCTUnwrap(
            (ethereumResponse.json["error"] as? [String: Any])?["data"] as? [String: String]
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
            (solanaResponse.json["error"] as? [String: Any])?["message"] as? String,
            Strings.transactionSubmissionStatusUnknown
        )
        XCTAssertEqual(
            (solanaResponse.json["error"] as? [String: Any])?["code"] as? Int,
            ProviderResponseError.transactionSubmissionUnknownCode
        )
        XCTAssertEqual(((solanaResponse.json["error"] as? [String: Any])?["data"] as? [String: Any])?["signature"] as? String, signature)
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
        XCTAssertEqual((serverFailure.json["error"] as? [String: Any])?["message"] as? String, "transaction rejected")
        XCTAssertEqual((serverFailure.json["error"] as? [String: Any])?["code"] as? Int, -32_000)
        XCTAssertEqual(
            (serverFailure.json["error"] as? [String: Any])?["data"] as? [String: String],
            ["reason": "nonce"]
        )

        let notSubmitted = EthereumDappRequestProcessor
            .transactionBroadcastResponse(
                to: request,
                expectedHash: expectedHash,
                recoveryResponse: recovery,
                result: .failure(.rpc(.notSubmitted))
            )
        XCTAssertEqual((notSubmitted.json["error"] as? [String: Any])?["message"] as? String, Strings.failedToSend)
        XCTAssertEqual(
            (notSubmitted.json["error"] as? [String: Any])?["code"] as? Int,
            ProviderResponseError.internalErrorCode
        )
        XCTAssertNil((notSubmitted.json["error"] as? [String: Any])?["data"])
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
            (confirmationFailure.json["error"] as? [String: Any])?["message"] as? String,
            Strings.solanaConfirmationTimedOut
        )
        XCTAssertEqual(
            ((confirmationFailure.json["error"] as? [String: Any])?["data"] as? [String: Any])?["signature"] as? String,
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
        XCTAssertEqual((explicitFailure.json["error"] as? [String: Any])?["message"] as? String, "transaction rejected")
        XCTAssertEqual((explicitFailure.json["error"] as? [String: Any])?["code"] as? Int, -32_003)
        XCTAssertNil(((explicitFailure.json["error"] as? [String: Any])?["data"] as? [String: Any])?["signature"])

        let notSubmitted = SolanaDappRequestProcessor.transactionBroadcastResponse(
            to: request,
            expectedSignature: expectedSignature,
            recoveryResponse: recovery,
            result: .failure(.notSubmitted)
        )
        XCTAssertEqual((notSubmitted.json["error"] as? [String: Any])?["message"] as? String, Strings.failedToSend)
        XCTAssertEqual(
            (notSubmitted.json["error"] as? [String: Any])?["code"] as? Int,
            ProviderResponseError.internalErrorCode
        )
        XCTAssertNil(((notSubmitted.json["error"] as? [String: Any])?["data"] as? [String: Any])?["signature"])
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

    func testSolanaBroadcastPreservesBlockhashNotFoundError() throws {
        let request = try solanaRequest(
            method: "signAndSendTransaction",
            publicKey: "public-key"
        )
        let signature = "expected-signature"
        let response = SolanaDappRequestProcessor.transactionBroadcastResponse(
            to: request,
            expectedSignature: signature,
            recoveryResponse: SolanaDappRequestProcessor.transactionSubmissionUnknownResponse(
                to: request, signature: signature
            ),
            result: .failure(.blockhashNotFound)
        )
        let error = try XCTUnwrap(response.json["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32003)
        XCTAssertEqual(error["message"] as? String, Strings.solanaBlockhashNotFound)
        XCTAssertNil(error["data"])
        XCTAssertNil(response.json["result"])
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
            EthereumDappRequestProcessor.providerError(for: .transport).code,
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
        var request = try XCTUnwrap(SafariRequest(data: requestData))
        request.authorizedAccount = method == "requestAccounts" || address.isEmpty ? nil : WalletAccountDescriptor(
            walletID: "wallet", coin: .ethereum,
            normalizedAddress: WalletCoin.ethereum.normalizedAddress(address),
            derivationPath: "m/44'/60'/0'/0/0"
        )
        return request
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
        var request = try XCTUnwrap(SafariRequest(data: requestData))
        request.authorizedAccount = method == "connect" ? nil : WalletAccountDescriptor(
            walletID: "wallet", coin: .solana, normalizedAddress: publicKey,
            derivationPath: "m/44'/501'/0'/0'"
        )
        return request
    }

    func testAccountAndChainMutationsAreExplicit() throws {
        let address = "0x0000000000000000000000000000000000000001"
        let accounts = ResponseToExtension(
            for: try ethereumRequest(method: "requestAccounts"),
            payload: .result(.strings([address])),
            mutation: .accounts([.ethereum(address: address, chainId: "0x1")])
        )
        XCTAssertEqual(accounts.mutation, .accounts([.ethereum(address: address, chainId: "0x1")]))
        for method in ["addEthereumChain", "switchEthereumChain"] {
            let response = ResponseToExtension(
                for: try ethereumRequest(method: method), payload: .result(.null),
                mutation: .ethereumChain("0x1")
            )
            XCTAssertEqual(response.mutation, .ethereumChain("0x1"))
            XCTAssertEqual(response.addsEthereumChain, method == "addEthereumChain")
            XCTAssertTrue(response.json["result"] is NSNull)
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

        guard case .approval(let actionIntent) = DappRequestProcessor().prepare(try requestBindingForTesting(request), catalog: processorCatalog(accounts: [])),
              case .switchAccount(let action) = actionIntent.action else {
            return XCTFail("Expected switch-account action")
        }

        XCTAssertFalse(action.initiallyConnectedProviders.contains(.ethereum))
        XCTAssertEqual(action.network?.chainId, EthereumNetwork.ethMainnetChainId)
    }

    func testPrepareReturnsUnauthorizedForUnownedKnownChainSwitch() throws {
        let request = try ethereumRequest(method: "switchEthereumChain", requestedChainId: "0xa")

        guard case let .immediate(responseResolution) = DappRequestProcessor().prepare(try requestBindingForTesting(request), catalog: processorCatalog(accounts: [])) else {
            return XCTFail("Expected immediate response")
        }
        let response = try XCTUnwrap(responseResolution.response(for: request))

        XCTAssertEqual((response.json["error"] as? [String: Any])?["code"] as? Int, 4100)
        XCTAssertEqual((response.json["error"] as? [String: Any])?["message"] as? String, Strings.providerNotReady)
    }

    func testPrepareWithoutWalletsReturnsDisconnectedKnownChainSwitch() throws {
        let request = try ethereumRequest(
            method: "switchEthereumChain",
            address: "",
            requestedChainId: "0xa"
        )

        guard case let .immediate(responseResolution) =
            DappRequestProcessor().prepareWithoutWallets(try requestBindingForTesting(request)) else {
            return XCTFail("Expected wallet-independent response")
        }
        let response = try XCTUnwrap(responseResolution.response(for: request))

        XCTAssertTrue(response.json["result"] is NSNull)
        XCTAssertEqual(response.mutation, .ethereumChain("0xa"))
        XCTAssertNil(response.json["error"])
        let catalog = processorCatalog(accounts: [])
        guard case .immediate(let withWalletsResolution) = DappRequestProcessor().prepare(
            try requestBindingForTesting(request), catalog: catalog
        ) else { return XCTFail("Expected the same wallet-independent response") }
        let withWallets = try XCTUnwrap(withWalletsResolution.response(for: request))
        XCTAssertEqual(try encodedResponse(withWallets), try encodedResponse(response))
    }

    func testPrepareReturnsUnrecognizedForUnknownChainSwitch() throws {
        let request = try ethereumRequest(
            method: "switchEthereumChain",
            requestedChainId: "0x7fffffffffffffff"
        )

        let catalog = processorCatalog(accounts: [])
        for preparation in [
            DappRequestProcessor().prepare(try requestBindingForTesting(request), catalog: catalog),
            try XCTUnwrap(DappRequestProcessor().prepareWithoutWallets(try requestBindingForTesting(request))),
        ] {
            guard case let .immediate(responseResolution) = preparation else {
                return XCTFail("Expected wallet-independent response")
            }
            let response = try XCTUnwrap(responseResolution.response(for: request))
            XCTAssertEqual((response.json["error"] as? [String: Any])?["code"] as? Int, 4902)
            XCTAssertEqual((response.json["error"] as? [String: Any])?["message"] as? String, Strings.unrecognizedChainId)
        }
    }

    func testPrepareSolanaConnectReturnsApproval() async throws {
        let request = try solanaRequest(method: "connect", publicKey: "")

        guard case .approval(let actionIntent) = DappRequestProcessor().prepare(try requestBindingForTesting(request), catalog: processorCatalog(accounts: [])),
              case .selectAccount(let action) = actionIntent.action else {
            return XCTFail("Expected Solana account selection")
        }

        XCTAssertEqual(action.coinType, .solana)
    }

    func testPrepareSolanaSigningForUnknownAccountReturnsUnauthorizedResponse() throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        let publicKey = processorAccount(privateKey: key, coin: .solana).address
        let request = try solanaRequest(
            method: "signMessage",
            publicKey: publicKey,
            parameters: [
                "message": "hello",
                "messageEncoding": "utf8",
            ]
        )

        guard case let .immediate(responseResolution) = DappRequestProcessor().prepare(try requestBindingForTesting(request), catalog: processorCatalog(accounts: [])) else {
            return XCTFail("Expected unauthorized response")
        }
        let response = try XCTUnwrap(responseResolution.response(for: request))

        XCTAssertEqual(response.json["provider"] as? String, "solana")
        XCTAssertEqual((response.json["error"] as? [String: Any])?["code"] as? Int, 4100)
        XCTAssertEqual((response.json["error"] as? [String: Any])?["message"] as? String, Strings.providerNotReady)
        XCTAssertEqual(response.mutation, .revokeSolana(publicKey))
        XCTAssertNil(response.json["mutation"])
    }

    func testPrepareEthereumAccountRequestReturnsApproval() async throws {
        let request = try ethereumRequest(method: "requestAccounts")

        guard case .approval(let actionIntent) = DappRequestProcessor().prepare(try requestBindingForTesting(request), catalog: processorCatalog(accounts: [])),
              case .selectAccount(let action) = actionIntent.action else {
            return XCTFail("Expected Ethereum account selection")
        }

        XCTAssertEqual(action.coinType, .ethereum)
    }

    func testEthereumInvalidPreparationMatchesWithoutCatalog() throws {
        let cases: [(method: String, parameters: [String: Any], errorCode: Int?)] = [
            ("signMessage", [:], nil),
            ("signPersonalMessage", [:], nil),
            ("signTypedMessage", [:], nil),
            ("signTransaction", ["to": "invalid"], -32_602),
            ("signTransaction", ["to": "0x0000000000000000000000000000000000000001", "type": "0x3"], 4200),
            ("ecRecover", [:], nil),
        ]
        for testCase in cases {
            let request = try ethereumRequest(
                method: testCase.method, parameters: testCase.parameters
            )
            let catalog = processorCatalog(accounts: [])
            guard case .immediate(let responseResolution) = DappRequestProcessor().prepare(
                try requestBindingForTesting(request), catalog: catalog
            ), case .immediate(let withoutWalletsResolution) =
                DappRequestProcessor().prepareWithoutWallets(try requestBindingForTesting(request)) else {
                return XCTFail("Expected wallet-independent failure for \(testCase.method)")
            }
            let response = try XCTUnwrap(responseResolution.response(for: request))
            let withoutWallets = try XCTUnwrap(withoutWalletsResolution.response(for: request))
            XCTAssertEqual(try encodedResponse(response), try encodedResponse(withoutWallets))
            XCTAssertNotNil(response.json["error"])
            XCTAssertEqual((response.json["error"] as? [String: Any])?["code"] as? Int, testCase.errorCode ?? ProviderResponseError.internalErrorCode)
        }
    }

    func testEthereumPreparationDefersOnlyWhenCatalogIsRequired() throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        let account = processorAccount(privateKey: key, coin: .ethereum)
        let cases: [(method: String, parameters: [String: Any])] = [
            ("requestAccounts", [:]),
            ("signMessage", ["data": "0x01"]),
            ("signPersonalMessage", ["data": "0x01"]),
            ("signTypedMessage", ["raw": "{}"]),
            ("signTransaction", ["from": account.address, "to": account.address, "value": "0x1"]),
            ("switchEthereumChain", ["chainId": "0xa"]),
        ]
        for testCase in cases {
            let request = try ethereumRequest(
                method: testCase.method,
                address: account.address,
                parameters: testCase.parameters
            )
            XCTAssertNil(DappRequestProcessor().prepareWithoutWallets(try requestBindingForTesting(request)))
            let catalog = processorCatalog(accounts: [account])
            let prepared = DappRequestProcessor().prepare(try requestBindingForTesting(request), catalog: catalog)
            switch prepared {
            case .approval(let intent):
                switch (testCase.method, intent.action) {
                case ("requestAccounts", .selectAccount(let action)):
                    XCTAssertEqual(action.selectedAccounts.map(\.account), [account])
                case ("signMessage", .approveMessage(let action)),
                     ("signPersonalMessage", .approveMessage(let action)),
                     ("signTypedMessage", .approveMessage(let action)):
                    XCTAssertEqual(action.account, account)
                case ("signTransaction", .approveTransaction(let action)):
                    XCTAssertEqual(action.account, account)
                default:
                    XCTFail("Unexpected approval for \(testCase.method)")
                }
            case .immediate(let resolution):
                XCTAssertEqual(testCase.method, "switchEthereumChain")
                let response = try XCTUnwrap(resolution.response(for: request))
                XCTAssertTrue(response.json["result"] is NSNull)
                XCTAssertEqual(response.mutation, .ethereumChain("0xa"))
                XCTAssertNil(response.json["error"])
            }
        }
    }

    func testEthereumChainAdditionPreparationDoesNotRequireCatalog() throws {
        let request = try addEthereumChainRequest(chainId: "0x7ffffffffffffffe").request
        let catalog = processorCatalog(accounts: [])
        guard case .approval(let withWalletsIntent) =
                DappRequestProcessor().prepare(try requestBindingForTesting(request), catalog: catalog),
              case .addEthereumChain(let withWallets) = withWalletsIntent.action,
              case .approval(let withoutWalletsIntent) =
                DappRequestProcessor().prepareWithoutWallets(try requestBindingForTesting(request)),
              case .addEthereumChain(let withoutWallets) = withoutWalletsIntent.action else {
            return XCTFail("Expected wallet-independent chain approval")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(
            try encoder.encode(withWallets.chainToAdd),
            try encoder.encode(withoutWallets.chainToAdd)
        )
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

        XCTAssertEqual((response.json["error"] as? [String: Any])?["message"] as? String, "transaction underpriced")
        XCTAssertEqual((response.json["error"] as? [String: Any])?["code"] as? Int, -32_000)
        XCTAssertTrue((response.json["error"] as? [String: Any])?["data"] is NSNull)
        XCTAssertEqual(response.json["provider"] as? String, "ethereum")
        XCTAssertNil((response.json["mutation"] as? [String: Any])?["publicKey"])
        XCTAssertNil(((response.json["error"] as? [String: Any])?["data"] as? [String: Any])?["signature"])
        XCTAssertNil(response.mutation)

        let canceledResponse = ResponseToExtension(
            for: request,
            payload: .error(
                ProviderResponseError(
                    message: Strings.canceled,
                    code: 4001
                )
            )
        )
        XCTAssertEqual((canceledResponse.json["error"] as? [String: Any])?["message"] as? String, Strings.canceled)
        XCTAssertEqual((canceledResponse.json["error"] as? [String: Any])?["code"] as? Int, 4001)

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
            (unrecognizedChainResponse.json["error"] as? [String: Any])?["message"] as? String,
            Strings.unrecognizedChainId
        )
        XCTAssertEqual(
            (unrecognizedChainResponse.json["error"] as? [String: Any])?["code"] as? Int,
            4902
        )

        let codeLessResponse = ResponseToExtension(
            for: request,
            payload: .error(
                ProviderResponseError(message: "generic failure")
            )
        )
        XCTAssertEqual((codeLessResponse.json["error"] as? [String: Any])?["code"] as? Int, -32_603)

        let publicKeyResponse = ResponseToExtension(
            for: try solanaRequest(method: "signMessage", publicKey: "public-key", parameters: [:]),
            payload: .error(
                ProviderResponseError(
                    message: Strings.providerNotReady,
                    code: 4100,
                    context: .unauthorizedPublicKey("public-key")
                )
            ),
            mutation: .revokeSolana("public-key")
        )
        XCTAssertEqual(publicKeyResponse.mutation, .revokeSolana("public-key"))
        XCTAssertNil(publicKeyResponse.json["mutation"])
        XCTAssertNil((publicKeyResponse.json["error"] as? [String: Any])?["data"])
        XCTAssertNil(((publicKeyResponse.json["error"] as? [String: Any])?["data"] as? [String: Any])?["signature"])

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
            ((signatureResponse.json["error"] as? [String: Any])?["data"] as? [String: Any])?["signature"] as? String,
            "signature"
        )
        XCTAssertNil((signatureResponse.json["mutation"] as? [String: Any])?["publicKey"])
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

    func testSwitchAccountPreselectionPreservesExactNativeGrantForDuplicateAddresses() throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        for coin in [WalletCoin.ethereum, .solana] {
            let account = processorAccount(privateKey: key, coin: coin)
            let first = SpecificWalletAccount(walletId: "first", account: account)
            let granted = SpecificWalletAccount(walletId: "second", account: account)
            var request = try switchAccountRequest(connectedAccount: account)
            request.connectedAccounts = [WalletAccountDescriptor(walletID: granted.walletId, account: account)]
            let catalog = WalletReviewCatalog(
                identity: WalletCatalogIdentity(generation: nil, catalogData: Data()),
                orderedAccounts: [first, granted]
            )
            guard case .approval(let actionIntent) = DappRequestProcessor().prepare(try requestBindingForTesting(request), catalog: catalog),
              case .switchAccount(let action) = actionIntent.action else {
                return XCTFail("Expected manual account selection")
            }
            XCTAssertEqual(action.selectedAccounts, [granted])
        }
    }

    func testSwitchAccountDoesNotSubstituteDuplicateForUnavailableExactGrant() throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        for coin in [WalletCoin.ethereum, .solana] {
            let account = processorAccount(privateKey: key, coin: coin)
            var request = try switchAccountRequest(connectedAccount: account)
            request.connectedAccounts = [WalletAccountDescriptor(walletID: "removed", account: account)]
            guard case .approval(let actionIntent) = DappRequestProcessor().prepare(
                try requestBindingForTesting(request), catalog: processorCatalog(accounts: [account])
            ),
              case .switchAccount(let action) = actionIntent.action else { return XCTFail("Expected manual account selection") }
            XCTAssertTrue(action.selectedAccounts.isEmpty)
            XCTAssertEqual(action.initiallyConnectedProviders, [coin.correspondingInpageProvider])
        }
    }

    func testDisconnectedSwitchAccountStillSuggestsDefaultAccount() throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        let account = processorAccount(privateKey: key, coin: .ethereum)
        let request = try switchAccountRequest(connectedAccount: nil)
        guard case .approval(let actionIntent) = DappRequestProcessor().prepare(
            try requestBindingForTesting(request), catalog: processorCatalog(accounts: [account])
        ),
              case .switchAccount(let action) = actionIntent.action else { return XCTFail("Expected manual account selection") }
        XCTAssertEqual(action.selectedAccounts, [SpecificWalletAccount(walletId: "wallet", account: account)])
        XCTAssertTrue(action.initiallyConnectedProviders.isEmpty)
    }

    private func switchAccountRequest(connectedAccount: WalletAccount?) throws -> SafariRequest {
        var configuration: [String: Any] = ["provider": "ethereum", "results": [], "chainId": "0x1"]
        if let account = connectedAccount {
            configuration = account.coin == .ethereum
                ? ["provider": "ethereum", "results": [account.address], "chainId": "0x1"]
                : ["provider": "solana", "publicKey": account.address]
        }
        return try XCTUnwrap(SafariRequest(json: [
            "id": 1, "name": "switchAccount", "provider": "unknown",
            "host": "example.com", "configurationKey": "https://example.com",
            "enqueueAttempt": "00000000000000000000000000000001",
            "admissionDeadline": dappRequestAdmissionDeadline,
            "workflowVersion": ExtensionBridge.workflowVersion,
            "body": ["latestConfigurations": [configuration]],
        ]))
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

    func testExistingCustomChainAdditionAllowsLocalDefinitionMatch() throws {
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

    func testNativeAuthorityEffectsNeverCrossResponseWire() throws {
        let request = try ethereumRequest(method: "requestAccounts")
        let descriptor = WalletAccountDescriptor(
            walletID: "wallet", coin: .ethereum,
            normalizedAddress: "0x0000000000000000000000000000000000000001",
            derivationPath: "m/44'/60'/0'/0/0"
        )
        let response = ResponseToExtension(
            for: request,
            payload: .result(.strings([descriptor.normalizedAddress])),
            mutation: .accounts([.ethereum(address: descriptor.normalizedAddress, chainId: "0x1")]),
            approvedAccounts: [descriptor]
        )
        XCTAssertNotNil(response.mutation)
        XCTAssertEqual(response.approvedAccounts, [descriptor])
        XCTAssertNil(response.json["mutation"])
        XCTAssertNil(response.json["approvedAccounts"])
        for field in ["mutation", "approvedAccounts"] {
            var injected = response.json
            injected[field] = ["kind": "accounts"]
            XCTAssertNil(ResponseToExtension(json: injected))
        }
    }

    func testNativeResponsesMatchSharedJavaScriptContract() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Safari Shared/Tests/fixtures/native_response_contract.json")
        let fixtures = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [[String: Any]]])
        for fixture in try XCTUnwrap(fixtures["valid"]) {
            let name = try XCTUnwrap(fixture["name"] as? String)
            let json = try XCTUnwrap(fixture["response"] as? [String: Any])
            let response = try XCTUnwrap(ResponseToExtension(json: json), name)
            XCTAssertEqual(response.json as NSDictionary, json as NSDictionary, name)
        }
        for fixture in try XCTUnwrap(fixtures["invalid"]) {
            let name = try XCTUnwrap(fixture["name"] as? String)
            let json = try XCTUnwrap(fixture["response"] as? [String: Any])
            XCTAssertNil(ResponseToExtension(json: json), name)
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

    func testResponsePollingIsWorkerOwnedWhileRPCRemainsPageOwned() throws {
        let responseMessage: [String: Any] = [
            "subject": "pollResponse",
            "id": 42,
            "workflowVersion": ExtensionBridge.workflowVersion,
            "configurationKey": "wallet.example",
            "requestToken": "00000000-0000-0000-0000-000000000001",
            "maintenance": "none",
        ]
        let responseRequest = try decodeInternalRequest(responseMessage)
        guard case .worker(.pollResponse(let identity)) = responseRequest.command else {
            return XCTFail("expected worker response poll")
        }
        XCTAssertEqual(identity.response.configurationKey, "wallet.example")
        XCTAssertEqual(identity.response.token.rawValue, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(identity.maintenance, .none)
        for field in ["executionDeadline", "revisions"] {
            var malformed = responseMessage
            malformed[field] = field == "revisions" ? ["ethereum": 0, "solana": 0] : 1_700_000_160_000
            XCTAssertThrowsError(try decodeInternalRequest(malformed))
        }

        let rpcMessage: [String: Any] = [
            "subject": "rpc",
            "id": 42,
            "workflowVersion": ExtensionBridge.workflowVersion,
            "body": "{}",
            "chainId": "0x1",
        ]
        guard case .page(.rpc(let body, let chainId)) = try decodeInternalRequest(rpcMessage).command else {
            return XCTFail("expected page RPC")
        }
        XCTAssertEqual(body, "{}")
        XCTAssertEqual(chainId, "0x1")
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

private func processorCatalog(accounts: [WalletAccount]) -> WalletReviewCatalog {
    WalletReviewCatalog(
        identity: WalletCatalogIdentity(generation: nil, catalogData: Data()),
        orderedAccounts: accounts.map { SpecificWalletAccount(walletId: "wallet", account: $0) }
    )
}

@MainActor
private final class ProcessorWalletSigner: WalletSigning {
    nonisolated func invalidate() {}
    private let result: Result<WalletSigningOutput, WalletSigningFailure>
    private(set) var signCalls = 0
    var beforeResult: (() async -> Void)?

    init(result: Result<WalletSigningOutput, WalletSigningFailure>) {
        self.result = result
    }

    func sign() async -> Result<WalletSigningOutput, WalletSigningFailure> {
        signCalls += 1
        await beforeResult?()
        return result
    }
}

@MainActor
private final class ProcessorBroadcastSender: ApprovedBroadcastSending {
    private(set) var sends = 0

    func sendEthereum(signedTransaction: String, network: ResolvedEthereumNetwork) async -> Result<String, EthereumSendFailure> {
        sends += 1
        return Ethereum.transactionHash(signedTransaction: signedTransaction).map(Result.success) ?? .failure(.transport)
    }

    func sendSolana(signedTransaction: String, cluster: Solana.Cluster, options: Solana.PreparedSendOptions) async -> Result<String, Solana.SendTransactionError> {
        sends += 1
        return Solana.transactionSignature(signedTransaction: signedTransaction).map(Result.success) ?? .failure(.invalidMessage)
    }
}
