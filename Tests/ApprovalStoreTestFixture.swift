import CryptoKit
import Foundation
import Synchronization
import XCTest
@testable import Big_Wallet

final class LockedTestValue<Value: Sendable>: Sendable {
    private let state: Mutex<Value>

    init(_ value: Value) { state = Mutex(value) }

    var value: Value {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    @discardableResult
    func withValue<Result: Sendable>(_ operation: (inout Value) throws -> Result) rethrows -> Result {
        try state.withLock { try operation(&$0) }
    }
}

extension ExtensionRequestFileStore {
    func withRevokedWalletAuthority<Result>(
        matching removal: WalletAuthorityRemoval,
        sourceMutation: () throws -> Result
    ) throws -> Result {
        try perform(
            preparing: { PreparedWalletSourceMutation(payload: (), authorityRemovals: [removal]) },
            beforeCommit: {},
            commit: { _ in try sourceMutation() }
        )
    }
}

enum ApprovalStoreTestPersistence {
    static func write(_ data: Data, _ url: URL) throws {
        try fixturePersistence(for: url).replace(data, at: url)
    }

    static func synchronize(_ url: URL) throws {
        try fixturePersistence(for: url).synchronizePublishedFile(at: url)
    }

    private static func fixturePersistence(for url: URL) -> DurableProfilePersistence {
        DurableProfilePersistence(directoryBoundary: url
            .deletingLastPathComponent()
            .deletingLastPathComponent())
    }
}

@MainActor
func reviewCatalogForTesting(
    action: DappRequestAction,
    accounts: [SpecificWalletAccount]? = nil
) -> WalletReviewCatalog {
    let derivedAccounts: [SpecificWalletAccount]
    if let accounts {
        derivedAccounts = accounts
    } else {
        switch action {
        case .selectAccount(let selection), .switchAccount(let selection):
            derivedAccounts = Array(selection.selectedAccounts)
        case .approveMessage(let message):
            derivedAccounts = [.init(walletId: message.walletId, account: message.account)]
        case .approveTransaction(let transaction):
            derivedAccounts = [.init(walletId: transaction.walletId, account: transaction.account)]
        case .addEthereumChain:
            derivedAccounts = []
        }
    }
    return WalletReviewCatalog(
        identity: .init(generation: nil, catalogData: Data()),
        orderedAccounts: derivedAccounts
    )
}

@MainActor
func preparationForTesting(
    binding: ExtensionBridge.RequestBinding,
    action: DappRequestAction,
    accounts: [SpecificWalletAccount]? = nil
) -> DappRequestPreparation {
    let processor = DappRequestProcessor(ethereumNetworkResolver: { chainID in
        if case .approveTransaction(let transaction) = action,
           transaction.chain.chainId == chainID {
            return .resolved(transaction.resolvedNetwork)
        }
        return Nodes.resolution(chainId: chainID)
    })
    return processor.prepare(binding, catalog: reviewCatalogForTesting(action: action, accounts: accounts))
}

@MainActor
func reviewIntentForTesting(
    binding: ExtensionBridge.RequestBinding,
    action: DappRequestAction,
    accounts: [SpecificWalletAccount]? = nil
) throws -> BoundApprovalIntent {
    guard case .approval(let intent) = preparationForTesting(binding: binding, action: action, accounts: accounts) else {
        throw CocoaError(.coderInvalidValue)
    }
    return intent
}

func requestBodyForTesting(_ request: SafariRequest) -> [String: Any] {
    switch request.body {
    case .ethereum(let body):
        var value: [String: Any] = ["address": body.address]
        value["chainId"] = body.currentChainId.map { String.hex($0, withPrefix: true) }
        value["object"] = body.parameters
        return value
    case .solana(let body):
        var parameters: [String: Any] = ["onlyIfTrusted": body.onlyIfTrusted]
        parameters["message"] = body.message
        parameters["messages"] = body.messages
        parameters["transaction"] = body.transaction
        parameters["options"] = body.sendOptions
        switch body.signMessageEncoding {
        case .hex?: parameters["messageEncoding"] = "hex"
        case .utf8?: parameters["messageEncoding"] = "utf8"
        case nil: parameters["messageEncoding"] = "unsupported"
        }
        if body.displayHex { parameters["display"] = "hex" }
        return ["publicKey": body.publicKey, "object": ["params": parameters]]
    case .unknown(let body):
        return ["latestConfigurations": body.providerConfigurations.map { configuration in
            var value: [String: Any] = ["provider": configuration.provider.rawValue]
            if configuration.provider == .ethereum {
                value["results"] = configuration.address.map { [$0] } ?? []
                value["chainId"] = configuration.chainId
            } else {
                value["publicKey"] = configuration.address
            }
            return value
        }]
    }
}

@MainActor
func requestBindingForTesting(_ request: SafariRequest) throws -> ExtensionBridge.RequestBinding {
    let fixture = try ApprovedExecutionTestFixture()
    let origin = request.configurationKey.contains("://")
        ? request.configurationKey : "https://" + request.configurationKey
    let chainID: Int
    if case .ethereum(let body) = request.body { chainID = body.currentChainId ?? 1 }
    else { chainID = 1 }
    let network = Networks.withChainIdHex(String.hex(chainID, withPrefix: true)) ?? EthereumNetwork(
        chainId: chainID, name: "Fixture", symbol: "ETH",
        rpcEndpoint: .unauthenticated(URL(string: "https://rpc.example")!),
        isTestnet: true, mightShowPrice: false, explorer: nil
    )
    let accounts = Set(request.connectedAccounts + [request.authorizedAccount].compactMap { $0 })
    for account in accounts {
        try fixture.establishGrant(account, configurationKey: origin, network: network)
    }
    let snapshot = try fixture.enqueue(
        id: request.id, name: request.name, provider: request.provider,
        body: requestBodyForTesting(request), configurationKey: origin
    )
    return try XCTUnwrap(snapshot.requestBinding)
}

@MainActor
func reviewConsentForTesting(
    snapshot: ExtensionBridge.Snapshot,
    action: DappRequestAction,
    decision: DappApprovalDecision,
    approvedAt: Date,
    nativeReceipt: ExtensionBridge.NativeDeliveryReceipt? = nil
) throws -> ReviewConsent {
    let accounts: [SpecificWalletAccount]?
    if case .accountSelection(let selection) = decision {
        accounts = selection.accounts.map(\.specificAccount)
    } else {
        accounts = nil
    }
    let intent = try reviewIntentForTesting(
        binding: XCTUnwrap(snapshot.requestBinding), action: action, accounts: accounts
    )
    let review = ApprovalReview(intent: intent)
    let consent: ReviewConsent?
    switch decision {
    case .accountSelection(let selection):
        consent = review.acceptAccounts(
            selection: selection, approvedAt: approvedAt,
            nativeReceipt: nativeReceipt
        )
    case .message(let message):
        consent = review.acceptMessage(
            cluster: message.solanaCluster, approvedAt: approvedAt,
            nativeReceipt: nativeReceipt
        )
    case .transaction(let execution):
        consent = review.acceptTransaction(
            execution: execution, approvedAt: approvedAt,
            nativeReceipt: nativeReceipt
        )
    case .addEthereumChain:
        consent = review.acceptAddEthereumChain(
            approvedAt: approvedAt, nativeReceipt: nativeReceipt
        )
    }
    return try XCTUnwrap(consent)
}

@MainActor
func approvalResolutionContextForTesting(
    action: DappRequestAction,
    decision: DappApprovalDecision,
    accounts: [SpecificWalletAccount]? = nil,
    networkResolver: (String) -> EthereumNetwork? = Networks.withChainIdHex
) -> ApprovalResolutionContext {
    let selectionNetwork: EthereumNetwork?
    switch (action, decision) {
    case (.selectAccount(let action), .accountSelection(let selection)),
         (.switchAccount(let action), .accountSelection(let selection)):
        selectionNetwork = (selection.ethereumChainID ?? action.network?.chainIdHexString)
            .flatMap(networkResolver)
    default:
        selectionNetwork = nil
    }
    let transactionNetwork: ResolvedEthereumNetwork?
    if case .approveTransaction(let transaction) = action {
        transactionNetwork = transaction.resolvedNetwork
    } else {
        transactionNetwork = nil
    }
    return ApprovalResolutionContext(
        accounts: reviewCatalogForTesting(action: action, accounts: accounts).orderedAccounts,
        selectionNetwork: selectionNetwork,
        transactionNetwork: transactionNetwork
    )
}

@MainActor
func resolvedApprovalForTesting(
    snapshot: ExtensionBridge.Snapshot,
    action: DappRequestAction,
    decision: DappApprovalDecision,
    accounts: [SpecificWalletAccount]? = nil,
    networkResolver: (String) -> EthereumNetwork? = Networks.withChainIdHex,
    approvedAt: Date,
    nativeReceipt: ExtensionBridge.NativeDeliveryReceipt? = nil
) throws -> ResolvedDappApproval {
    let consent = try reviewConsentForTesting(
        snapshot: snapshot, action: action, decision: decision,
        approvedAt: approvedAt, nativeReceipt: nativeReceipt
    )
    return try consent.resolve(context: approvalResolutionContextForTesting(
        action: consent.intent.action,
        decision: consent.decision,
        accounts: accounts,
        networkResolver: networkResolver
    )).get()
}

func approvedFailureForTesting(
    _ error: ProviderResponseError,
    permit: ExtensionBridge.ApprovedExecutionPermit
) -> ApprovedExecutionResult {
    ApprovedCompletion.failure(error, permit: permit).map(ApprovedExecutionResult.completed) ?? .rollback
}

@MainActor
func reviewActionForTesting(
    binding: ExtensionBridge.RequestBinding,
    decision: DappApprovalDecision
) throws -> DappRequestAction {
    let request = binding.request
    switch decision {
    case .accountSelection(let selection):
        let initiallyConnected = Set(request.connectedAccounts.map(\.coin.correspondingInpageProvider))
        let action = SelectAccountAction(
            coinType: WalletCoin.correspondingToInpageProvider(request.provider),
            selectedAccounts: [],
            initiallyConnectedProviders: request.provider == .unknown ? initiallyConnected : [],
            network: selection.ethereumChainID.flatMap(Networks.withChainIdHex)
        )
        return request.provider == .unknown ? .switchAccount(action) : .selectAccount(action)
    case .message(let approval):
        let catalog = WalletReviewCatalog(
            identity: .init(generation: nil, catalogData: Data()),
            orderedAccounts: [approval.approvedAccount.specificAccount]
        )
        guard case .approval(let intent) = DappRequestProcessor().prepare(binding, catalog: catalog) else {
            throw CocoaError(.coderInvalidValue)
        }
        return intent.action
    case .transaction(let execution):
        guard case .ethereum(let body) = request.body,
              case .success(let transaction) = body.transactionParsingResult,
              let url = URL(string: execution.reviewedNetwork.canonicalRPCURL) else {
            throw CocoaError(.coderInvalidValue)
        }
        let identity = execution.reviewedNetwork
        let source: RPCSource
        switch identity.source {
        case .alchemy: source = .alchemy
        case .fallback: source = .fallback
        case .custom: source = .custom
        }
        let network = EthereumNetwork(
            chainId: identity.chainID, name: "Reviewed network", symbol: "ETH",
            rpcEndpoint: .unauthenticated(url), isTestnet: true,
            mightShowPrice: false, explorer: nil
        )
        let account = execution.approvedAccount
        return .approveTransaction(.init(
            transaction: transaction, resolvedNetwork: .init(network: network, source: source),
            walletId: account.walletID, account: account.account
        ))
    case .addEthereumChain:
        guard case .ethereum(let body) = request.body,
              let network = EthereumNetworkFromDapp.from(body.parameters) else {
            throw CocoaError(.coderInvalidValue)
        }
        return .addEthereumChain(.init(chainToAdd: network))
    }
}

private final class ApprovalFixtureResources: NSObject, XCTestObservation, Sendable {
    static let shared = ApprovalFixtureResources()
    private let directories = Mutex([URL]())

    override private init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func retain(_ directory: URL) {
        directories.withLock { $0.append(directory) }
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        let directories = directories.withLock { directories in
            let retained = directories
            directories.removeAll()
            return retained
        }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
    }
}

@MainActor
final class ApprovedExecutionTestFixture {
    private final class Identifiers: Sendable {
        private let state = Mutex<UUID?>(nil)
        var next: UUID? {
            get { state.withLock { $0 } }
            set { state.withLock { $0 = newValue } }
        }
        func take() -> UUID {
            state.withLock { next in
                defer { next = nil }
                return next ?? UUID()
            }
        }
    }

    nonisolated let store: ExtensionRequestFileStore
    let now: Date
    private let identifiers: Identifiers

    init(now: Date = Date()) throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "approved-execution-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        ApprovalFixtureResources.shared.retain(rootURL)
        let identifiers = Identifiers()
        self.identifiers = identifiers
        self.now = now
        store = ExtensionRequestFileStore(
            rootURL: rootURL,
            directoryBoundary: rootURL,
            dependencies: .init(
                clock: { now }, token: identifiers.take,
                atomicWrite: ApprovalStoreTestPersistence.write
            )
        )
    }

    func enqueue(
        id: Int,
        name: String,
        provider: InpageProvider,
        body: [String: Any],
        handle: ExtensionBridge.Handle? = nil,
        configurationKey: String = "https://wallet.example"
    ) throws -> ExtensionBridge.Snapshot {
        let profileIdentifier = handle?.profileIdentifier
        guard case .snapshot(let authority) = store.configurationSnapshot(
            configurationKey: configurationKey, profileIdentifier: profileIdentifier
        ) else { throw CocoaError(.fileReadUnknown) }
        let raw: [String: Any] = [
            "id": id, "name": name, "provider": provider.rawValue,
            "body": body,
            "host": configurationKey.components(separatedBy: "://").last!,
            "configurationKey": configurationKey,
            "enqueueAttempt": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "admissionDeadline": Int(ceil(now.addingTimeInterval(150).timeIntervalSince1970 * 1_000)),
            "workflowVersion": ExtensionBridge.workflowVersion,
            "authority": authority.version.json,
        ]
        let request = try XCTUnwrap(SafariRequest(json: raw))
        guard case .accepted(let ingress) = ExtensionBridge.dappIngressResult(request: request, rawObject: raw) else {
            throw CocoaError(.coderInvalidValue)
        }
        identifiers.next = handle?.token.value
        guard case .accepted(let admitted, _, _, _, _) = store.enqueue(
            ingress: ingress, profileIdentifier: profileIdentifier
        ), case .found(let snapshot) = store.load(handle: admitted) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if let handle { XCTAssertEqual(admitted, handle) }
        return snapshot
    }

    func authorize(
        snapshot: ExtensionBridge.Snapshot,
        action: DappRequestAction,
        decision: DappApprovalDecision,
        accounts: [SpecificWalletAccount]? = nil,
        networkResolver: (String) -> EthereumNetwork? = Networks.withChainIdHex
    ) throws -> ExtensionBridge.ApprovedExecutionPermit {
        let approved = try resolvedApprovalForTesting(
            snapshot: snapshot, action: action, decision: decision,
            accounts: accounts, networkResolver: networkResolver,
            approvedAt: now
        )
        guard case .claimed(let claim) = store.claim(handle: snapshot.handle),
              claim.adoptForExecution(),
              case .authorized(let permit) = store.authorize(claim: claim, approval: approved) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return permit
    }

    func establishGrant(
        _ account: WalletAccountDescriptor,
        profileIdentifier: UUID? = nil,
        configurationKey: String = "https://wallet.example",
        network: EthereumNetwork? = nil
    ) throws {
        let network = try XCTUnwrap(network ?? Networks.ethereum)
        let ethereum = account.coin == .ethereum
        let id = Int.random(in: 1_000_000...2_000_000)
        let snapshot = try enqueue(
            id: id, name: ethereum ? "requestAccounts" : "connect",
            provider: ethereum ? .ethereum : .solana,
            body: ethereum ? ["address": "", "chainId": "0x1"] : ["publicKey": "", "object": [:]],
            handle: .init(id: id, token: .init(value: UUID()), profileIdentifier: profileIdentifier),
            configurationKey: configurationKey
        )
        let permit = try authorize(
            snapshot: snapshot,
            action: .selectAccount(.init(
                coinType: account.coin, selectedAccounts: [],
                initiallyConnectedProviders: [], network: network
            )),
            decision: .accountSelection(.init(accounts: [account], ethereumChainID: network.chainIdHexString)),
            accounts: [.init(walletId: account.walletID, account: account.account)],
            networkResolver: { $0 == network.chainIdHexString ? network : nil }
        )
        XCTAssertTrue(permit.consumeExecution())
        let completion = try XCTUnwrap(ApprovedCompletion.accountSelection(permit: permit))
        guard store.complete(permit: permit, result: completion) == .persisted else {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = store.acknowledgeResponse(handle: snapshot.handle, configurationKey: configurationKey)
    }
}

extension XCTestCase {
    func makeApprovalClaimForTesting(
        handle: ExtensionBridge.Handle,
        deadline: Date = Date().addingTimeInterval(150)
    ) throws -> ExtensionBridge.ApprovalClaim {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "approval-claim-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = deadline.addingTimeInterval(-150)
        let identifiers = LockedTestValue([UUID(), handle.token.value, UUID(), UUID()])
        let store = ExtensionRequestFileStore(
            rootURL: directory,
            directoryBoundary: directory,
            dependencies: .init(
                clock: { now },
                token: { identifiers.withValue { $0.removeFirst() } },
                atomicWrite: ApprovalStoreTestPersistence.write
            )
        )
        let configurationKey = "https://wallet.example"
        guard case .snapshot(let authority) = store.configurationSnapshot(
            configurationKey: configurationKey,
            profileIdentifier: handle.profileIdentifier
        ) else { throw CocoaError(.fileReadUnknown) }
        let raw: [String: Any] = [
            "id": handle.id,
            "name": "requestAccounts",
            "provider": "ethereum",
            "body": ["address": "", "chainId": "0x1"],
            "host": "wallet.example",
            "configurationKey": configurationKey,
            "enqueueAttempt": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "admissionDeadline": Int(ceil(deadline.timeIntervalSince1970 * 1_000)),
            "workflowVersion": ExtensionBridge.workflowVersion,
            "authority": authority.version.json,
        ]
        let request = try XCTUnwrap(SafariRequest(json: raw))
        guard case .accepted(let ingress) = ExtensionBridge.dappIngressResult(request: request, rawObject: raw),
              case .accepted(let admitted, _, _, _, _) = store.enqueue(
                ingress: ingress, profileIdentifier: handle.profileIdentifier
              ), admitted == handle,
              case .claimed(let claim) = store.claim(handle: admitted) else {
            throw CocoaError(.fileWriteUnknown)
        }
        addTeardownBlock {
            claim.releaseUnapproved()
            try FileManager.default.removeItem(at: directory)
        }
        return claim
    }
}

func walletSigningAuthorizationForTesting(
    approvedAccount: WalletAccountDescriptor,
    handle: ExtensionBridge.Handle = .init(
        id: 1,
        token: .init(value: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
        profileIdentifier: nil
    ),
    deadline: Date = .distantFuture
) -> WalletSigningAuthorization {
    WalletSigningAuthorization(handle: handle, approvedAccount: approvedAccount, signingDeadline: deadline)
}

func makeWalletSigningSessionForTesting(
    _ access: any OwnedWalletSigningAccess = TestWalletSigningAccess(),
    authorization: WalletSigningAuthorization,
    isCurrent: @escaping @Sendable () -> Bool = { true },
    acquireCommitLease: (@MainActor @Sendable () async -> WalletExecutionLease?)? = nil,
    clock: @escaping @MainActor @Sendable () -> Date = { Date() }
) -> WalletSigningSession {
    WalletSigningSession(
        BorrowedWalletSignerForTesting(access),
        authorization: authorization,
        isCurrent: isCurrent,
        acquireCommitLease: acquireCommitLease ?? {
            isCurrent() ? WalletExecutionLease(release: {}) : nil
        },
        clock: clock
    )
}

final class TestWalletSigner: WalletSigning {
    func invalidate() {}

    @MainActor
    func sign() async -> Result<WalletSigningOutput, WalletSigningFailure> {
        .failure(.failedToSign)
    }
}

final class TestWalletSigningAccess: OwnedWalletSigningAccess {
    @MainActor
    func sign(_ operation: ApprovedWalletSigningOperation) async -> Result<WalletSigningOutput, WalletSigningFailure> {
        .failure(.failedToSign)
    }

    func invalidate() {}
}

final class BorrowedWalletSignerForTesting: OwnedWalletSigningAccess {
    private struct State {
        var access: (any OwnedWalletSigningAccess)?
        var invalidations = 0
    }
    private let state: Mutex<State>

    var invalidationCount: Int { state.withLock { $0.invalidations } }

    init(_ access: any OwnedWalletSigningAccess = TestWalletSigningAccess()) {
        state = Mutex(State(access: access))
    }

    @MainActor
    func sign(_ operation: ApprovedWalletSigningOperation) async -> Result<WalletSigningOutput, WalletSigningFailure> {
        guard let access = state.withLock({ $0.access }) else { return .failure(.authorizationUnavailable) }
        return await access.sign(operation)
    }

    func invalidate() {
        let access = state.withLock { state in
            state.invalidations += 1
            let access = state.access
            state.access = nil
            return access
        }
        access?.invalidate()
    }
}

let walletSigningTestMessage = Data("Bound wallet signing operation".utf8)

@MainActor
func approvedWalletSigningOperationForTesting(
    approvedAccount: WalletAccountDescriptor,
    payload: SignMessageAction.Payload? = nil,
    deadline: Date = .distantFuture,
    requestID: Int = 1,
    authorization: WalletSigningAuthorization? = nil,
    serializedTransaction: String? = nil
) throws -> ApprovedWalletSigningOperation {
    let requestID = authorization?.handle.id ?? requestID
    let deadline = authorization?.signingDeadline ?? deadline
    let ethereum = approvedAccount.coin == .ethereum
    let payload = payload ?? (ethereum
        ? .signature(.ethereumPersonalMessage(walletSigningTestMessage))
        : .signature(.solanaMessage(walletSigningTestMessage)))
    let name: String
    let subject: ApprovalSubject
    let parameters: [String: Any]
    switch payload {
    case .signature(.ethereumPersonalMessage(let data)):
        name = "signPersonalMessage"
        subject = .signPersonalMessage
        parameters = ["data": WalletCrypto.hexString(data: data)]
    case .signature(.ethereumTypedData(let raw)):
        name = "signTypedMessage"
        subject = .signTypedData
        parameters = ["raw": raw]
    case .signature(.solanaMessage(let data)):
        name = "signMessage"
        subject = .signMessage
        parameters = ["message": WalletCrypto.hexString(data: data), "messageEncoding": "hex"]
    case .signature(.solanaTransaction(let transaction)):
        name = "signTransaction"
        subject = .approveTransaction
        parameters = ["message": WalletCrypto.base58Encode(data: transaction.messageData)]
    case .signature(.solanaTransactions(let transactions)):
        name = "signAllTransactions"
        subject = .approveTransaction
        parameters = ["messages": transactions.map { WalletCrypto.base58Encode(data: $0.messageData) }]
    case .solanaLegacyBroadcast(let transaction, let options):
        name = "signAndSendTransaction"
        subject = .approveTransaction
        parameters = ["message": transaction.approvalMessage, "options": signingOptionsForTesting(options)]
    case .solanaSerializedBroadcast(let transaction, let options):
        name = "signAndSendTransaction"
        subject = .approveTransaction
        let message = transaction.preparedMessage.messageData
        let signatureCount = transaction.preparedMessage.parsedMessage.requiredSignaturesCount
        let wire = Data.encodeLength(signatureCount) + Data(repeating: 0, count: signatureCount * 64) + message
        parameters = [
            "transaction": serializedTransaction ?? WalletCrypto.base58Encode(data: wire),
            "options": signingOptionsForTesting(options),
        ]
    }
    let body: [String: Any] = ethereum
        ? ["address": approvedAccount.normalizedAddress, "chainId": "0x1", "object": parameters]
        : ["publicKey": approvedAccount.normalizedAddress, "object": ["params": parameters]]
    let requestedHandle = authorization?.handle ?? ExtensionBridge.Handle(
        id: requestID,
        token: .init(value: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
        profileIdentifier: nil
    )
    let fixture = try ApprovedExecutionTestFixture(now: deadline.addingTimeInterval(-150))
    try fixture.establishGrant(approvedAccount, profileIdentifier: requestedHandle.profileIdentifier)
    let snapshot = try fixture.enqueue(
        id: requestID, name: name, provider: ethereum ? .ethereum : .solana,
        body: body, handle: requestedHandle
    )
    let catalog = WalletReviewCatalog(
        identity: .init(generation: nil, catalogData: Data()),
        orderedAccounts: [approvedAccount.specificAccount]
    )
    guard case .approval(let intent) = DappRequestProcessor().prepare(
        try XCTUnwrap(snapshot.requestBinding), catalog: catalog
    ), case .approveMessage(let action) = intent.action else { throw CocoaError(.coderInvalidValue) }
    XCTAssertEqual(action.subject, subject)
    let permit = try fixture.authorize(
        snapshot: snapshot,
        action: .approveMessage(action),
        decision: .message(.init(
            approvedAccount: approvedAccount,
            solanaCluster: action.solanaClusterOptions == nil ? nil : .devnet
        ))
    )
    XCTAssertTrue(permit.consumeExecution())
    return try XCTUnwrap(ApprovedWalletSigningOperation(permit: permit))
}

private func signingOptionsForTesting(_ options: Solana.PreparedSendOptions) -> [String: Any] {
    var result = [String: Any]()
    result["cluster"] = options.clusterHint?.rawValue
    result["preflightCommitment"] = options.preflightCommitment?.rawValue
    result["maxRetries"] = options.maxRetries
    result["minContextSlot"] = options.minContextSlot
    result["commitment"] = options.confirmationCommitment?.rawValue
    return result
}

func assertWalletSigningSuccessForTesting(
    _ result: Result<WalletSigningOutput, WalletSigningFailure>,
    account: WalletAccount,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    switch try result.get() {
    case .ethereumSignature(let signature):
        let signatureData = try XCTUnwrap(WalletCrypto.hexData(signature), file: file, line: line)
        let prefix = Data("\u{19}Ethereum Signed Message:\n\(walletSigningTestMessage.count)".utf8)
        let digest = WalletCrypto.keccak256(parts: [prefix, walletSigningTestMessage])
        XCTAssertEqual(
            WalletCrypto.recoverEthereumAddress(signature: signatureData, messageHash: digest)?.lowercased(),
            account.address.lowercased(),
            file: file, line: line
        )
    case .solanaSignature(let signature):
        let signatureData = try XCTUnwrap(WalletCrypto.base58Decode(string: signature), file: file, line: line)
        let publicKeyData = try XCTUnwrap(WalletCrypto.base58Decode(string: account.address), file: file, line: line)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        XCTAssertTrue(publicKey.isValidSignature(signatureData, for: walletSigningTestMessage), file: file, line: line)
    default:
        XCTFail("Expected a signature for the approved message", file: file, line: line)
    }
}

private final class ApprovalStoreWrites: Sendable {
    private let failures = Mutex([Bool]())

    func failNext(afterWriting: Bool = false) {
        failures.withLock { $0.append(afterWriting) }
    }

    func write(_ data: Data, to url: URL) throws {
        let failure = failures.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        if failure == false { throw CocoaError(.fileWriteUnknown) }
        try ApprovalStoreTestPersistence.write(data, url)
        if failure == true { throw CocoaError(.fileWriteUnknown) }
    }

}

actor ApprovalStoreTestFixture: NativeApprovalStore {
    let bridge: ExtensionBridge
    private let rootURL: URL
    private let clock: @Sendable () -> Date
    private let writes: ApprovalStoreWrites
    private var retainedClaims = [ExtensionBridge.ApprovalClaim]()
    private var authorityCurrent = true
    private var eventValues = [String]()
    private var loadCountValue = 0
    private var activeOperations = 0
    private var isClosing = false
    private var cleanupContinuation: CheckedContinuation<Void, Never>?
    private var nextClaimObserver: (@MainActor (ExtensionBridge.ApprovalClaim) -> Void)?
    private var nextRejectResult: ExtensionBridge.StoreMutationResult?
    private var nextAbandonResult: ExtensionBridge.StoreMutationResult?
    private var nextClaimResult: ExtensionBridge.ApprovalClaimResult?
    private var nextLoadTransform: (@Sendable (ExtensionBridge.Snapshot) -> ExtensionBridge.Snapshot)?
    private var nextCompletionReceipt: ExtensionBridge.NativeDeliveryReceipt?
    private var shouldFailNextCompletion = false
    private var shouldFailNextAuthorization = false
    private var checkpointFailureAfterWriting: Bool?
    private var authorizationHook: (@MainActor () -> Void)?
    private var permitCompletionHook: (@Sendable () -> Void)?
    private var broadcastCheckpointHook: (@Sendable () -> Void)?
    private var broadcastCheckpointCommittedHook: (@Sendable () -> Void)?
    private var committedCheckpoints = Set<ExtensionBridge.Handle>()
    private var suspendAuthorityCheck = false
    private var authorityCheckContinuation: CheckedContinuation<Void, Never>?
    private var suspendClaim = false
    private var claimContinuation: CheckedContinuation<Void, Never>?
    private var suspendCompletion = false
    private var completionContinuation: CheckedContinuation<ExtensionBridge.StoreMutationResult?, Never>?

    init(clock: @escaping @Sendable () -> Date = { Date() }) throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "approval-store-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        self.clock = clock
        let writes = ApprovalStoreWrites()
        self.writes = writes
        bridge = ExtensionBridge(store: ExtensionRequestFileStore(
            rootURL: rootURL,
            directoryBoundary: rootURL,
            dependencies: .init(clock: clock, atomicWrite: writes.write)
        ))
    }

    func cleanup() async throws {
        isClosing = true
        resumeAuthorityCheck()
        resumeClaim()
        resumeCompletion(result: .ownershipLost)
        if activeOperations > 0 {
            await withCheckedContinuation { cleanupContinuation = $0 }
        }
        for claim in retainedClaims { _ = await bridge.abandon(claim: claim) }
        retainedClaims.removeAll()
        try FileManager.default.removeItem(at: rootURL)
    }

    nonisolated(nonsending) func enqueue(
        rawObject: [String: Any],
        profileIdentifier: UUID? = nil,
        approvedAccount: WalletAccountDescriptor? = nil
    ) async throws -> ExtensionBridge.Snapshot {
        guard let object = WireProtocol.JSONObject(rawObject) else { throw CocoaError(.coderInvalidValue) }
        return try await enqueue(object: object, profileIdentifier: profileIdentifier, approvedAccount: approvedAccount)
    }

    private func enqueue(
        object: WireProtocol.JSONObject,
        profileIdentifier: UUID?,
        approvedAccount: WalletAccountDescriptor?
    ) async throws -> ExtensionBridge.Snapshot {
        var rawObject = object.json
        rawObject["admissionDeadline"] = Int(clock().addingTimeInterval(
            ExtensionBridge.requestTTL
        ).timeIntervalSince1970 * 1_000)
        guard let configurationKey = rawObject["configurationKey"] as? String else { throw CocoaError(.coderInvalidValue) }
        if let approvedAccount {
            let chainID = (rawObject["body"] as? [String: Any])?["chainId"] as? String ?? "0x1"
            try await establishGrant(
                approvedAccount, configurationKey: configurationKey,
                profileIdentifier: profileIdentifier, chainID: chainID
            )
        }
        guard case .snapshot(let authority) = await bridge.configurationSnapshot(
            configurationKey: configurationKey, profileIdentifier: profileIdentifier
        ) else { throw CocoaError(.fileReadUnknown) }
        rawObject["revisions"] = nil
        rawObject["authority"] = authority.version.json
        let request = try XCTUnwrap(SafariRequest(json: rawObject))
        guard case .accepted(let ingress) = ExtensionBridge.dappIngressResult(
            request: request, rawObject: rawObject
        ) else { throw CocoaError(.coderInvalidValue) }
        guard case .accepted(let handle, _, _, _, _) = await bridge.enqueue(
            ingress: ingress, profileIdentifier: profileIdentifier
        ) else { throw CocoaError(.fileWriteUnknown) }
        return try await snapshot(handle: handle)
    }

    func snapshot(handle: ExtensionBridge.Handle) async throws -> ExtensionBridge.Snapshot {
        guard case .found(let value) = await bridge.load(handle: handle) else {
            throw CocoaError(.fileReadUnknown)
        }
        return value
    }

    func makeObserverBridge(
        atomicWrite: @escaping ExtensionRequestFileStore.AtomicWrite =
            ApprovalStoreTestPersistence.write
    ) -> ExtensionBridge {
        ExtensionBridge(store: ExtensionRequestFileStore(
            rootURL: rootURL,
            directoryBoundary: rootURL,
            dependencies: .init(clock: clock, atomicWrite: atomicWrite)
        ))
    }

    func operationLockURL(handle: ExtensionBridge.Handle) -> URL {
        let profile = handle.profileIdentifier?.uuidString.lowercased() ?? "default"
        return rootURL.appendingPathComponent("operation-locks-v9", isDirectory: true)
            .appendingPathComponent("\(profile)-\(handle.requestToken).lock")
    }

    func holdForeignClaim(handle: ExtensionBridge.Handle) async throws {
        guard case .claimed(let claim) = await bridge.claim(handle: handle) else {
            throw CocoaError(.fileWriteUnknown)
        }
        retainedClaims.append(claim)
    }

    func setNativeDeliveryReceipt(
        _ receipt: ExtensionBridge.NativeDeliveryReceipt?,
        handle: ExtensionBridge.Handle
    ) async {
        guard let snapshot = try? await snapshot(handle: handle) else {
            XCTFail("Missing receipt request")
            return
        }
        let result: ExtensionBridge.StoreMutationResult
        if let receipt {
            result = await bridge.recordNativeDeliveryReceipt(
                handle: handle,
                nativeDeliveryNonce: snapshot.nativeDeliveryNonce,
                owner: receipt.owner
            )
        } else if let receipt = snapshot.nativeDeliveryReceipt {
            result = await bridge.clearNativeDeliveryReceipt(
                handle: handle,
                nativeDeliveryNonce: receipt.nativeDeliveryNonce,
                runtimeInstanceIdentifier: receipt.owner.runtimeInstanceIdentifier
            )
        } else { return }
        XCTAssertEqual(result, .persisted)
    }

    func prepareNativeApproval(
        handle: ExtensionBridge.Handle,
        decision: DappApprovalDecision,
        approvedAt: Date? = nil,
        action: DappRequestAction? = nil
    ) async throws -> ReviewConsent {
        let snapshot = try await snapshot(handle: handle)
        let runtime = snapshot.nativeDeliveryReceipt?.owner.runtimeInstanceIdentifier ?? UUID()
        let owner = snapshot.nativeDeliveryReceipt?.owner ?? ExtensionBridge.NativeDeliveryOwner(
            runtimeInstanceIdentifier: runtime,
            processIdentifier: 42,
            processStartDate: clock(),
            bundleURL: rootURL.appendingPathComponent("Helper.app"),
            marketingVersion: "1.0.99", buildVersion: "148"
        )!
        let delivered = await bridge.recordNativeDeliveryReceipt(
            handle: handle, nativeDeliveryNonce: snapshot.nativeDeliveryNonce,
            owner: owner
        )
        guard delivered == .persisted else { throw CocoaError(.fileWriteUnknown) }
        let approvedAt = approvedAt ?? clock()
        return try await MainActor.run {
            let reviewed = try action ?? reviewActionForTesting(
                binding: XCTUnwrap(snapshot.requestBinding), decision: decision
            )
            return try reviewConsentForTesting(
                snapshot: snapshot, action: reviewed, decision: decision,
                approvedAt: approvedAt,
                nativeReceipt: .init(nativeDeliveryNonce: snapshot.nativeDeliveryNonce, owner: owner)
            )
        }
    }

    func setAuthorityCurrent(_ value: Bool) { authorityCurrent = value }

    func authorityIsCurrent(handle: ExtensionBridge.Handle) async -> Bool {
        guard !isClosing else { return false }
        activeOperations += 1
        defer { finishOperation() }
        if suspendAuthorityCheck {
            suspendAuthorityCheck = false
            await withCheckedContinuation { continuation in
                eventValues.append("authorityCheckStarted")
                authorityCheckContinuation = continuation
            }
        }
        guard !isClosing, authorityCurrent else { return false }
        return await bridge.authorityIsCurrent(handle: handle)
    }

    func establishGrant(
        _ account: WalletAccountDescriptor,
        configurationKey: String,
        profileIdentifier: UUID?,
        chainID: String = "0x1"
    ) async throws {
        guard case .snapshot(let authority) = await bridge.configurationSnapshot(
            configurationKey: configurationKey, profileIdentifier: profileIdentifier
        ) else { throw CocoaError(.fileReadUnknown) }
        if account.coin == .ethereum && authority.ethereumAccount == account && authority.ethereumChainId == chainID ||
            account.coin == .solana && authority.solanaAccount == account { return }
        let ethereum = account.coin == .ethereum
        let id = Int.random(in: 1_000_000...2_000_000)
        let body = try XCTUnwrap(WireProtocol.JSONObject(ethereum
            ? ["address": "", "chainId": chainID]
            : ["publicKey": "", "object": [String: Any]()]))
        let request = try XCTUnwrap(SafariRequest(json: [
            "id": id, "name": ethereum ? "requestAccounts" : "connect",
            "provider": ethereum ? "ethereum" : "solana",
            "host": configurationKey.components(separatedBy: "://").last!,
            "configurationKey": configurationKey,
            "enqueueAttempt": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "admissionDeadline": Int(clock().addingTimeInterval(ExtensionBridge.requestTTL).timeIntervalSince1970 * 1_000),
            "workflowVersion": ExtensionBridge.workflowVersion,
            "authority": authority.version.json,
            "body": body.json,
        ]))
        let raw: [String: Any] = [
            "id": request.id, "name": request.name, "provider": request.provider.rawValue,
            "host": request.host, "configurationKey": request.configurationKey,
            "enqueueAttempt": request.enqueueAttempt,
            "admissionDeadline": Int(request.admissionDeadline.timeIntervalSince1970 * 1_000),
            "workflowVersion": request.workflowVersion, "authority": authority.version.json,
            "body": body.json,
        ]
        guard case .accepted(let ingress) = ExtensionBridge.dappIngressResult(request: request, rawObject: raw),
              case .accepted(let handle, _, _, _, _) = await bridge.enqueue(ingress: ingress, profileIdentifier: profileIdentifier) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let loaded = try await snapshot(handle: handle)
        let selectedAccount = SpecificWalletAccount(walletId: account.walletID, account: account.account)
        let approval = try await resolvedApprovalForTesting(
            snapshot: loaded,
            action: .selectAccount(.init(
                coinType: account.coin, selectedAccounts: [],
                initiallyConnectedProviders: [], network: Networks.withChainIdHex(chainID)
            )),
            decision: .accountSelection(.init(accounts: [account], ethereumChainID: chainID)),
            accounts: [selectedAccount], approvedAt: clock()
        )
        guard case .claimed(let claim) = await bridge.claim(handle: handle),
              claim.adoptForExecution(),
              case .authorized(let permit) = await bridge.authorize(claim: claim, approval: approval),
              permit.consumeExecution(),
              let completion = ApprovedCompletion.accountSelection(permit: permit),
              await bridge.complete(permit: permit, result: completion) == .persisted else {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = await bridge.acknowledgeResponse(handle: handle, configurationKey: configurationKey)
    }

    func transformNextLoad(_ transform: @escaping @Sendable (ExtensionBridge.Snapshot) -> ExtensionBridge.Snapshot) {
        nextLoadTransform = transform
    }

    func events() -> [String] { eventValues }
    func loadCount() -> Int { loadCountValue }
    func record(_ event: String) { eventValues.append(event) }
    func completedErrorCode(handle: ExtensionBridge.Handle) async -> Int? {
        (await response(handle: handle)?["error"] as? [String: Any])?["code"] as? Int
    }
    func completedApprovalWasCommitted(handle: ExtensionBridge.Handle) async -> Bool {
        await response(handle: handle)?["approvalCommitted"] as? Bool == true
    }
    func checkpointApprovalWasCommitted(handle: ExtensionBridge.Handle) -> Bool {
        committedCheckpoints.contains(handle)
    }
    nonisolated(nonsending) func response(handle: ExtensionBridge.Handle) async -> [String: Any]? {
        guard let snapshot = try? await snapshot(handle: handle),
              case .response(let response) = await bridge.prepareResponseDelivery(
                id: handle.id, configurationKey: snapshot.configurationKey,
                requestToken: handle.requestToken, profileIdentifier: handle.profileIdentifier
              ) else { return nil }
        return response["response"] as? [String: Any]
    }

    func observeNextClaim(_ observer: @escaping @MainActor (ExtensionBridge.ApprovalClaim) -> Void) {
        nextClaimObserver = observer
    }
    func forceNextRejectResult(_ result: ExtensionBridge.StoreMutationResult) { nextRejectResult = result }
    func forceNextAbandonResult(_ result: ExtensionBridge.StoreMutationResult) { nextAbandonResult = result }
    func forceNextClaimResult(_ result: ExtensionBridge.ApprovalClaimResult) { nextClaimResult = result }
    func forceNextCompletionOwnershipLoss(receipt: ExtensionBridge.NativeDeliveryReceipt) { nextCompletionReceipt = receipt }
    func failNextCompletion() { shouldFailNextCompletion = true }
    func failNextAuthorization() { shouldFailNextAuthorization = true }
    func failNextCheckpoint(afterWriting: Bool) { checkpointFailureAfterWriting = afterWriting }
    func setAuthorizationHook(_ hook: @escaping @MainActor () -> Void) { authorizationHook = hook }
    func setPermitCompletionHook(_ hook: @escaping @Sendable () -> Void) { permitCompletionHook = hook }
    func setBroadcastCheckpointHook(_ hook: @escaping @Sendable () -> Void) { broadcastCheckpointHook = hook }
    func setBroadcastCheckpointCommittedHook(_ hook: @escaping @Sendable () -> Void) {
        broadcastCheckpointCommittedHook = hook
    }
    func suspendNextAuthorityCheck() { suspendAuthorityCheck = true }
    func resumeAuthorityCheck() {
        let continuation = authorityCheckContinuation
        authorityCheckContinuation = nil
        continuation?.resume()
    }
    func suspendNextClaim() { suspendClaim = true }
    func resumeClaim() {
        let continuation = claimContinuation
        claimContinuation = nil
        continuation?.resume()
    }
    func suspendNextCompletion() { suspendCompletion = true }
    func resumeCompletion(result: ExtensionBridge.StoreMutationResult? = nil) {
        let continuation = completionContinuation
        completionContinuation = nil
        continuation?.resume(returning: result)
    }

    func list(profileIdentifier: UUID?) async -> ExtensionBridge.SnapshotsResult {
        guard !isClosing else { return .unavailable }
        activeOperations += 1
        defer { finishOperation() }
        return await bridge.list(profileIdentifier: profileIdentifier)
    }
    func load(handle: ExtensionBridge.Handle) async -> ExtensionBridge.SnapshotResult {
        guard !isClosing else { return .unavailable }
        activeOperations += 1
        defer { finishOperation() }
        loadCountValue += 1
        let result = await bridge.load(handle: handle)
        if case .found(let snapshot) = result, let transform = nextLoadTransform {
            nextLoadTransform = nil
            return .found(transform(snapshot))
        }
        return result
    }
    func claim(handle: ExtensionBridge.Handle) async -> ExtensionBridge.ApprovalClaimResult {
        guard !isClosing else { return .unavailable }
        activeOperations += 1
        defer { finishOperation() }
        if let result = nextClaimResult {
            nextClaimResult = nil
            return result
        }
        if suspendClaim {
            suspendClaim = false
            await withCheckedContinuation { continuation in
                eventValues.append("claimStarted")
                claimContinuation = continuation
            }
        }
        guard !isClosing else { return .unavailable }
        let result = await bridge.claim(handle: handle)
        if case .claimed(let claim) = result {
            eventValues.append("claim")
            let observer = nextClaimObserver
            nextClaimObserver = nil
            await observer?(claim)
        }
        return result
    }
    func claimNativeExecution(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID,
        approvedAt: Date
    ) async -> ExtensionBridge.NativeExecutionClaimResult {
        guard !isClosing else { return .unavailable }
        activeOperations += 1
        defer { finishOperation() }
        let result = await bridge.claimNativeExecution(
            handle: handle, nativeDeliveryNonce: nativeDeliveryNonce,
            runtimeInstanceIdentifier: runtimeInstanceIdentifier, approvedAt: approvedAt
        )
        if case .claimed(let claim) = result {
            eventValues.append("nativeClaim")
            let observer = nextClaimObserver
            nextClaimObserver = nil
            await observer?(claim)
        }
        return result
    }
    func interruptNativeApproval(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID
    ) async -> ExtensionBridge.NativeInterruptionResult {
        guard !isClosing else { return .ownershipLost }
        activeOperations += 1
        defer { finishOperation() }
        return await bridge.interruptNativeApproval(
            handle: handle, nativeDeliveryNonce: nativeDeliveryNonce,
            runtimeInstanceIdentifier: runtimeInstanceIdentifier
        )
    }
    func completeImmediate(handle: ExtensionBridge.Handle, resolution: ImmediateResolution) async -> ExtensionBridge.StoreMutationResult {
        guard !isClosing else { return .ownershipLost }
        activeOperations += 1
        defer { finishOperation() }
        if let receipt = nextCompletionReceipt {
            nextCompletionReceipt = nil
            await setNativeDeliveryReceipt(receipt, handle: handle)
        }
        if let result = await beforeCompletion() { return result }
        let result = await bridge.completeImmediate(handle: handle, resolution: resolution)
        recordCompletion(result)
        return result
    }
    func reject(handle: ExtensionBridge.Handle) async -> ExtensionBridge.StoreMutationResult {
        guard !isClosing else { return .ownershipLost }
        activeOperations += 1
        defer { finishOperation() }
        eventValues.append("reject")
        if let result = nextRejectResult {
            nextRejectResult = nil
            return result
        }
        return await bridge.reject(handle: handle)
    }
    func abandon(claim: ExtensionBridge.ApprovalClaim) async -> ExtensionBridge.StoreMutationResult {
        guard !isClosing else { return .ownershipLost }
        activeOperations += 1
        defer { finishOperation() }
        eventValues.append("abandon")
        if let result = nextAbandonResult {
            nextAbandonResult = nil
            return result
        }
        return await bridge.abandon(claim: claim)
    }
    func authorize(
        claim: ExtensionBridge.ApprovalClaim,
        approval: ResolvedDappApproval
    ) async -> ExtensionBridge.AuthorizeExecutionResult {
        guard !isClosing, authorityCurrent else { return .ownershipLost }
        activeOperations += 1
        defer { finishOperation() }
        await authorizationHook?()
        if shouldFailNextAuthorization {
            shouldFailNextAuthorization = false
            return .retryablePersistenceFailure
        }
        return await bridge.authorize(claim: claim, approval: approval)
    }

    func complete(
        claim: ExtensionBridge.ApprovalClaim,
        resolution: ImmediateResolution
    ) async -> ExtensionBridge.StoreMutationResult {
        guard !isClosing else { return .ownershipLost }
        activeOperations += 1
        defer { finishOperation() }
        permitCompletionHook?()
        if let result = await beforeCompletion() { return result }
        let result = await bridge.complete(claim: claim, resolution: resolution)
        recordCompletion(result)
        return result
    }

    func complete(permit: ExtensionBridge.ApprovedExecutionPermit, result completion: ApprovedCompletion) async -> ExtensionBridge.StoreMutationResult {
        guard !isClosing else { return .ownershipLost }
        activeOperations += 1
        defer { finishOperation() }
        permitCompletionHook?()
        if let result = await beforeCompletion() { return result }
        let result = await bridge.complete(permit: permit, result: completion)
        recordCompletion(result)
        return result
    }
    func prepareBroadcast(permit: ExtensionBridge.ApprovedExecutionPermit, broadcast: PreparedBroadcast) async -> ExtensionBridge.BroadcastPreparationResult {
        guard !isClosing else { return .ownershipLost }
        activeOperations += 1
        defer { finishOperation() }
        broadcastCheckpointHook?()
        if let afterWriting = checkpointFailureAfterWriting {
            checkpointFailureAfterWriting = nil
            writes.failNext(afterWriting: afterWriting)
        }
        let result = await bridge.prepareBroadcast(permit: permit, broadcast: broadcast)
        if case .prepared = result {
            eventValues.append("checkpoint")
            committedCheckpoints.insert(permit.handle)
            let committed = broadcastCheckpointCommittedHook
            broadcastCheckpointCommittedHook = nil
            committed?()
        }
        return result
    }
    func abandon(permit: ExtensionBridge.ApprovedExecutionPermit) async -> ExtensionBridge.StoreMutationResult {
        guard !isClosing else { return .ownershipLost }
        activeOperations += 1
        defer { finishOperation() }
        let result = await bridge.abandon(permit: permit)
        eventValues.append("abandon")
        return result
    }

    private func finishOperation() {
        activeOperations -= 1
        if activeOperations == 0 {
            let continuation = cleanupContinuation
            cleanupContinuation = nil
            continuation?.resume()
        }
    }

    private func beforeCompletion() async -> ExtensionBridge.StoreMutationResult? {
        guard !isClosing else { return .ownershipLost }
        if suspendCompletion {
            suspendCompletion = false
            let result = await withCheckedContinuation { continuation in
                eventValues.append("completeStarted")
                completionContinuation = continuation
            }
            if let result {
                eventValues.append("completeResumed")
                return result
            }
        }
        if shouldFailNextCompletion {
            shouldFailNextCompletion = false
            writes.failNext()
        }
        return nil
    }

    private func recordCompletion(_ result: ExtensionBridge.StoreMutationResult) {
        switch result {
        case .persisted: eventValues.append("complete")
        case .retryablePersistenceFailure: eventValues.append("completeFailed")
        case .ownershipLost: break
        }
    }
}
