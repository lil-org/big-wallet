@testable import WalletFlows
import CryptoKit
import Foundation
import Synchronization
import WalletDomain
@testable import WalletAuthority

final class NetworkAttempts: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func record() { value.withLock { $0 += 1 } }
}

private struct RejectingBroadcaster: SignedTransactionBroadcasting {
    let attempts: NetworkAttempts

    func broadcast(_ request: BroadcastRequest) async -> BroadcastResult {
        attempts.record()
        switch request {
        case .ethereum: return .notSubmitted(.ethereum(.rpc(.notSubmitted)))
        case .solana: return .notSubmitted(.solana(.notSubmitted))
        }
    }
}

private struct OfflineSolanaEndpoints: SolanaEndpointResolving {
    func endpoint(for cluster: Solana.Cluster) -> SolanaRPCEndpoint? { nil }
}

@MainActor
final class ConsumerServices {
    let storage: FixtureStorage
    let preferences: FixturePreferences
    let credentials: WalletCredentials
    let wallets: WalletsManager
    let metadata: WalletsMetadataService
    let bridge: ExtensionBridge
    let networks: NetworkResolver
    let attempts: NetworkAttempts
    private let processor: DappRequestProcessor
    private let finalizer: NativeApprovalFinalizer
    private let authorityID: UUID
    private var requestID = 0
    private let owner: NativeDeliveryOwner

    init(storage: FixtureStorage, fixtureStorage: FixtureStorage, attempts: NetworkAttempts) throws {
        let authorityID = UUID()
        self.authorityID = authorityID
        self.storage = storage
        self.attempts = attempts
        preferences = storage.preferences(domain: SharedDefaults.suiteName)
        let fixturePreferences = fixtureStorage.preferences(domain: SharedDefaults.suiteName)
        guard case .loaded(let signingNetworks) = SharedDefaults.loadCustomNetworkSnapshotResult(from: fixturePreferences),
              signingNetworks.entriesByChainId[31337] != nil else { throw UpgradeFailure.invalid("Missing fixture signing network") }
        let networks = NetworkResolver(catalog: nil, catalogOwnedChainIds: [], customSnapshot: { signingNetworks },
            freshCustomSnapshot: { .loaded(signingNetworks) })
        self.networks = networks
        metadata = WalletsMetadataService(storage: preferences)
        let metadata = metadata
        let fileStore = ExtensionRequestFileStore(containerURL: storage.root.appendingPathComponent("authority", isDirectory: true),
            dependencies: .init(resolveImmediate: { resolution, request in
                resolution.response(for: request, networkResolver: networks.resolution)
            }))
        let bridge = ExtensionBridge(store: fileStore)
        self.bridge = bridge
        wallets = WalletsManager(keychain: storage.keychain, reloadMetadata: { metadata.reload() },
            walletSourceMutator: fileStore,
            notifications: .init(postLocalChange: {}, postMutation: {}, startObserving: { _, _ in }, stopObserving: { _ in },
                isExternalChange: { _ in false }), metadataMutations: metadata.mutations, authorityID: authorityID)
        credentials = WalletCredentials(keychain: storage.keychain, messages: .testingEnglish, authorityID: authorityID,
            authentication: .init(canUseBiometrics: { false }, attemptBiometrics: { _ in
                attempts.record()
                return .failed
            }))
        let processor = DappRequestProcessor(ethereumNetworkResolver: networks.approvalResolution,
            selectionNetworkResolver: networks.network, customDefinitionResult: { _ in .unavailable },
            solanaEndpoints: OfflineSolanaEndpoints())
        self.processor = processor
        let wallets = wallets
        finalizer = NativeApprovalFinalizer(store: bridge,
            executionEnvironment: .init(requestProcessor: processor, broadcaster: RejectingBroadcaster(attempts: attempts)),
            refreshWalletCatalog: {
                guard await wallets.reloadFromStore() else { return nil }
                return wallets.reviewCatalog()
            }, makeSigningPreparation: { WalletSigningPreparation.fromSource(scope: $0, walletsManager: wallets) },
            networkResolver: networks.approvalResolution, customDefinitionResult: { _ in .unavailable })
        guard let owner = NativeDeliveryOwner(runtimeInstanceIdentifier: UUID(), processIdentifier: ProcessInfo.processInfo.processIdentifier,
            processStartDate: Date(), bundleURL: storage.root.appendingPathComponent("Consumer.app"),
            marketingVersion: "upgrade-consumer", buildVersion: "1") else {
            throw UpgradeFailure.invalid("Cannot create consumer approval owner")
        }
        self.owner = owner
    }

    func authenticate(password: String) throws -> WalletAccessSession {
        let challenge = credentials.makeWalletAccessChallenge()
        guard let grant = try credentials.verify(password: password, challenge: challenge),
              let session = credentials.accessSession(authorization: grant) else {
            throw UpgradeFailure.invalid("Fixture password was not accepted")
        }
        return session
    }

    func export(wallet: WalletSnapshot, account: WalletAccount?, password: String, mnemonic: Bool) async throws -> String {
        let challenge = try await wallets.makeExportChallenge(wallet: wallet, account: account, kind: mnemonic ? .mnemonic : .privateKey)
        defer { challenge.invalidate() }
        guard let grant = try credentials.verify(password: password, challenge: challenge) else {
            throw UpgradeFailure.invalid("Export authentication failed")
        }
        let secret: WalletExportedSecret
        if mnemonic { secret = try await wallets.exportMnemonic(wallet: wallet, authorization: grant) }
        else { secret = try await wallets.exportPrivateKey(wallet: wallet, account: account, authorization: grant) }
        defer { secret.invalidate() }
        var text: String?
        guard secret.withText({ text = $0 }), let text else { throw UpgradeFailure.invalid("Export was retired") }
        return text
    }

    func sign(account: SpecificWalletAccount, expected: FixtureExpectations.Account, password: String, solanaMessage: Data) async throws {
        let host = "upgrade-\(UUID().uuidString.lowercased()).invalid"
        let origin = "https://" + host
        let provider = account.account.coin.correspondingInpageProvider
        let connectBody: [String: Any] = provider == .ethereum ? ["address": ""] : ["publicKey": "", "object": [String: Any]()]
        let connected = try await request(name: provider == .ethereum ? "requestAccounts" : "connect", provider: provider,
            body: connectBody, host: host, origin: origin, password: password, account: account)
        switch connected.payload {
        case .result: break
        case .error: throw UpgradeFailure.invalid("Native connection approval failed")
        }
        let ethereumMessage = Data("Big Wallet shipped-state recovery fixture v1".utf8)
        let message = provider == .ethereum ? ethereumMessage : solanaMessage
        let body: [String: Any] = provider == .ethereum
            ? ["address": account.account.address, "chainId": "0x7a69", "object": ["data": "0x" + WalletEncoding.hexString(data: message)]]
            : ["publicKey": account.account.address, "object": ["params": ["message": WalletEncoding.hexString(data: message), "messageEncoding": "hex"]]]
        let response = try await request(name: provider == .ethereum ? "signPersonalMessage" : "signMessage", provider: provider,
            body: body, host: host, origin: origin, password: password, account: account)
        guard case .result(.string(let signature)) = response.payload else { throw UpgradeFailure.invalid("Native signing did not return a signature") }
        let publicKey = try hexData(expected.signing.publicKeyHex)
        if provider == .ethereum {
            guard let bytes = WalletEncoding.hexData(signature),
                  let recovered = EthereumSigner.recover(signature: bytes, message: message) else {
                throw UpgradeFailure.invalid("Approved Ethereum signature could not be recovered")
            }
            let oldAddress = WalletCrypto.addressFromPublicKeyData(publicKey, coin: .ethereum)
            try require(recovered.lowercased() == oldAddress.lowercased() && recovered.lowercased() == expected.address.lowercased(),
                "Approved Ethereum signature changed historical identity")
        } else {
            guard let bytes = WalletEncoding.base58Decode(string: signature), bytes.count == 64 else {
                throw UpgradeFailure.invalid("Approved Solana signature is not a 64-byte base58 value")
            }
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
            try require(WalletEncoding.base58Encode(publicKey) == expected.address, "Historical Solana public key does not match its address")
            try require(key.isValidSignature(try hexData(expected.signing.signatureHex), for: message),
                "Historical Solana signature is invalid for the approved message")
            // CryptoKit randomizes Ed25519 signatures; equivalence is the verified key and message.
            try require(key.isValidSignature(bytes, for: message), "Approved Solana signature is invalid for the historical public key and message")
        }
    }

    private func request(
        name: String, provider: InpageProvider, body: [String: Any], host: String, origin: String,
        password: String, account: SpecificWalletAccount
    ) async throws -> ResponseToExtension {
        requestID += 1
        guard case .snapshot(let authority) = await bridge.configurationSnapshot(configurationKey: origin, profileIdentifier: nil) else {
            throw UpgradeFailure.invalid("Native configuration is unavailable")
        }
        let raw: [String: Any] = ["id": requestID, "name": name, "provider": provider.rawValue,
            "body": body, "host": host, "configurationKey": origin,
            "workflowVersion": ExtensionBridge.workflowVersion, "authority": authority.version.json,
            "enqueueAttempt": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "admissionDeadline": Int(Date().addingTimeInterval(120).timeIntervalSince1970 * 1_000)]
        let context = "Native \(provider.rawValue).\(name)"
        guard let request = SafariRequest(json: raw) else {
            throw UpgradeFailure.invalid("\(context) request parsing failed")
        }
        let ingress: ExtensionBridge.Ingress
        switch ExtensionBridge.dappIngressResult(request: request, rawObject: raw, responseOwner: .document(.init(tabID: 1, frameID: 0, documentID: nil, documentSession: "0123456789abcdef0123456789abcdef"))) {
        case .accepted(let value): ingress = value
        case .payloadTooLarge: throw UpgradeFailure.invalid("\(context) ingress payload exceeded limit")
        case .invalid: throw UpgradeFailure.invalid("\(context) ingress validation failed")
        }
        let handle: RequestHandle
        let nonce: NativeDeliveryNonce
        switch await bridge.enqueue(ingress: ingress, profileIdentifier: nil) {
        case .accepted(let admittedHandle, _, _, _, let admittedNonce):
            handle = admittedHandle
            nonce = admittedNonce
        case .unauthorized: throw UpgradeFailure.invalid("\(context) admission unauthorized")
        case .expired: throw UpgradeFailure.invalid("\(context) admission expired")
        case .rejected: throw UpgradeFailure.invalid("\(context) admission rejected")
        case .manualSwitchCapacityReached: throw UpgradeFailure.invalid("\(context) admission capacity reached")
        case .unavailable: throw UpgradeFailure.invalid("\(context) admission store unavailable")
        }
        let coordinator = NativeApprovalCoordinator(authority: NativeApprovalAuthority(handle: handle, nativeDeliveryNonce: nonce, store: bridge,
            environment: .live(processor: processor, wallets: wallets, finalizer: finalizer, messages: .testingEnglish,
                authorityID: authorityID, clock: Date.init, monotonicClock: { .now }, hooks: .none)))
        let resolved = ApprovalResolution<Result<Void, UpgradeFailure>>()
        var decided = false
        let credentials = credentials
        let network = networks.network(chainId: 31337)
        coordinator.onEvent = { [weak coordinator] event in
            guard let coordinator else { return }
            let snapshot = coordinator.currentPresentation
            Task { @MainActor [weak coordinator] in
                guard let coordinator else { return }
                var step = "presentation"
                do {
                    switch event {
                    case .authenticationRequired:
                        guard coordinator.isAwaitingAuthentication else { return }
                        step = "wallet authentication"
                        let challenge = credentials.makeWalletAccessChallenge()
                        guard let grant = try credentials.verify(password: password, challenge: challenge),
                              let access = credentials.accessSession(authorization: grant) else {
                            throw UpgradeFailure.invalid("Native wallet authentication failed")
                        }
                        coordinator.resumeAfterAuthentication(authorization: access)
                    case .presentationChanged:
                        guard let snapshot, coordinator.currentPresentation?.revision == snapshot.revision else { return }
                        switch snapshot.presentation {
                        case .approval(let review):
                            guard !decided else { throw UpgradeFailure.invalid("Native approval was replayed") }
                            decided = true
                            switch review.action {
                            case .selectAccount:
                                coordinator.approveAccounts([account], ethereumNetwork: provider == .ethereum ? network : nil, review: review)
                            case .approveMessage(let action):
                                step = "message authentication"
                                try require(action.walletId == account.walletId && action.account == account.account,
                                    "Native review selected another account")
                                guard let challenge = review.makeMessageAuthenticationChallenge(solanaCluster: nil),
                                      let grant = try credentials.verify(password: password, challenge: challenge) else {
                                    throw UpgradeFailure.invalid("Native signing authentication failed")
                                }
                                coordinator.approveMessage(solanaCluster: nil, review: review, authorization: grant)
                            default: throw UpgradeFailure.invalid("Unexpected native review action")
                            }
                        case .finished:
                            await resolved.resolve(.success(()))
                        case .waiting: break
                        case .retryRequired, .rejecting, .interrupted, .superseded:
                            throw UpgradeFailure.invalid("Native approval could not complete")
                        }
                    }
                } catch {
                    await resolved.resolve(.failure(.invalid("Native \(name) \(step) failed: \(error)")))
                }
            }
        }
        defer { coordinator.onEvent = nil }
        coordinator.start(nativeDeliveryOwner: owner)
        let result = await ApprovalResolution<Result<Void, UpgradeFailure>>().value(
            timeoutValue: .failure(.invalid("Native approval timed out")), callerCancellation: .resolveTimeout,
            waitForTimeout: { try? await Task.sleep(for: .seconds(30)) }, operation: { await resolved.value() })
        try result.get()
        guard case .response(let delivery) = await bridge.prepareResponseDelivery(id: handle.id, configurationKey: origin,
            requestToken: handle.requestToken, profileIdentifier: nil, access: .worker),
              let json = delivery["response"] as? [String: Any], let response = ResponseToExtension(json: json),
              response.approvalCommitted else { throw UpgradeFailure.invalid("Native response was not durably approved") }
        try require(attempts.count == 0, "Unexpected network or biometric attempt")
        return response
    }
}
