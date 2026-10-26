import Foundation
import WalletDomain
import XCTest
@testable import WalletAuthority
#if SWIFT_PACKAGE
import WalletRuntimeTestSupport
#endif

enum AuthorityTestNetworks {
    static let resolver = RuntimeTestCatalog.resolver()

    static var ethereum: EthereumNetwork? { resolver.network(chainId: 1) }
    static var pinned: [EthereumNetwork] { [1, 7777777, 10, 8453, 42161].compactMap { resolver.network(chainId: $0) } }
    static var ordered: [EthereumNetwork] { resolver.allNetworks }
    static var custom: [EthereumNetwork] { resolver.visibleCustomNetworks }
    static var mainnets: [EthereumNetwork] { resolver.bundledNetworks.filter { !$0.isTestnet && ![1, 7777777, 10, 8453, 42161].contains($0.chainId) } }
    static var testnets: [EthereumNetwork] { resolver.bundledNetworks.filter(\.isTestnet) }

    static func withChainIdHex(_ chainID: String?) -> EthereumNetwork? {
        resolver.network(chainIdHex: chainID)
    }
}

struct AuthorityTestSolanaEndpoints: SolanaEndpointResolving {
    func endpoint(for cluster: Solana.Cluster) -> SolanaRPCEndpoint? {
        SolanaRPCEndpoint(url: URL(string: "https://solana.example/\(cluster.rawValue)")!, allowsAlchemyAuthorization: false)
    }

    var snapshot: [Solana.Cluster: SolanaRPCEndpoint] {
        Dictionary(uniqueKeysWithValues: Solana.Cluster.allCases.compactMap { cluster in
            endpoint(for: cluster).map { (cluster, $0) }
        })
    }
}

@MainActor
func requestProcessorForTesting(
    ethereumNetworkResolver: @escaping @MainActor @Sendable (Int) -> ApprovalNetworkResolution = {
        AuthorityTestNetworks.resolver.approvalResolution(chainId: $0)
    },
    selectionNetworkResolver: @escaping @MainActor @Sendable (String?) -> EthereumNetwork? = {
        AuthorityTestNetworks.withChainIdHex($0)
    },
    customDefinitionResult: @escaping @MainActor @Sendable (EthereumNetworkFromDapp) -> CustomNetworkInsertionResult = { _ in .unavailable },
    solanaEndpoints: any SolanaEndpointResolving = AuthorityTestSolanaEndpoints(),
    solana: SolanaSigner? = nil
) -> DappRequestProcessor {
    DappRequestProcessor(
        ethereumNetworkResolver: ethereumNetworkResolver,
        selectionNetworkResolver: selectionNetworkResolver,
        customDefinitionResult: customDefinitionResult,
        solanaEndpoints: solanaEndpoints,
        solana: solana ?? SolanaSigner()
    )
}

@MainActor
func resolveApprovalForTesting(
    _ consent: ReviewConsent,
    refreshWalletCatalog: @MainActor () async -> WalletReviewCatalog?,
    networkResolver: (Int) -> ApprovalNetworkResolution = { AuthorityTestNetworks.resolver.approvalResolution(chainId: $0) },
    customDefinitionResult: @MainActor @Sendable (EthereumNetworkFromDapp) -> CustomNetworkInsertionResult = { _ in .unavailable },
    isCurrent: @MainActor () -> Bool = { true }
) async -> DurableApprovalExecutor.Resolution {
    await DappApprovalResolver.resolve(consent, refreshWalletCatalog: refreshWalletCatalog,
        networkResolver: networkResolver, customDefinitionResult: customDefinitionResult, isCurrent: isCurrent)
}

func accountSelectionCompletionForTesting(
    permit: ExtensionBridge.ApprovedExecutionPermit,
    fallbackNetwork: () -> EthereumNetwork? = { AuthorityTestNetworks.ethereum }
) -> ApprovedCompletion? {
    ApprovedCompletion.accountSelection(permit: permit, fallbackNetwork: fallbackNetwork)
}

func storeDependenciesForTesting(
    messages: AuthorityMessages = .testingEnglish,
    clock: @escaping @Sendable () -> Date = Date.init,
    token: @escaping @Sendable () -> UUID = UUID.init,
    revocationEpoch: @escaping @Sendable () -> UUID = UUID.init,
    crossProcessLock: AuthorityFileLock? = nil,
    crossProcessLockTimeoutNanoseconds: UInt64 = 1_000_000_000,
    crossProcessLockPollNanoseconds: UInt64 = 10_000_000,
    fileIO: ExtensionRequestStoreFiles.IO? = nil,
    completeChainAddition: @escaping ExtensionRequestFileStore.CompleteChainAddition = { _ in false },
    resolveImmediate: @escaping ExtensionRequestFileStore.ResolveImmediate = {
        $0.response(for: $1, networkResolver: AuthorityTestNetworks.resolver.resolution)
    }
) -> ExtensionRequestFileStore.Dependencies {
    .init(messages: messages, clock: clock, token: token, revocationEpoch: revocationEpoch,
        crossProcessLock: crossProcessLock,
        crossProcessLockTimeoutNanoseconds: crossProcessLockTimeoutNanoseconds,
        crossProcessLockPollNanoseconds: crossProcessLockPollNanoseconds, fileIO: fileIO,
        completeChainAddition: completeChainAddition, resolveImmediate: resolveImmediate)
}

func broadcastResultForTesting(_ result: Result<String, EthereumSendFailure>) -> BroadcastResult {
    switch result {
    case .success(let identity): return .accepted(identity)
    case .failure(let error):
        switch error {
        case .transport, .rpc(.unknown): return .submissionUnknown(.ethereum(error))
        case .rpc(.notSubmitted): return .notSubmitted(.ethereum(error))
        case .rpc(.serverError): return .rejected(.ethereum(error))
        }
    }
}

func broadcastResultForTesting(_ result: Result<String, Solana.SendTransactionError>) -> BroadcastResult {
    switch result {
    case .success(let identity): return .accepted(identity)
    case .failure(let error):
        switch error {
        case .unknown, .rpcUnavailable, .confirmationTimedOut: return .submissionUnknown(.solana(error))
        case .notSubmitted: return .notSubmitted(.solana(error))
        case .confirmationFailed(let signature, _, _):
            return .confirmationFailed(transactionID: signature, failure: .solana(error))
        case .invalidMessage, .unsupportedMultiSignature, .blockhashNotFound, .invalidSendOptions, .rpcError:
            return .rejected(.solana(error))
        }
    }
}

struct RejectingBroadcastForTesting: SignedTransactionBroadcasting {
    func broadcast(_ request: BroadcastRequest) async -> BroadcastResult {
        XCTFail("Unexpected transaction broadcast")
        switch request {
        case .ethereum: return .notSubmitted(.ethereum(.rpc(.notSubmitted)))
        case .solana: return .notSubmitted(.solana(.notSubmitted))
        }
    }
}

@MainActor
func exportMnemonicForTesting(manager: WalletsManager, wallet: WalletSnapshot) async throws -> String {
    let challenge = try await manager.makeExportChallenge(wallet: wallet, kind: .mnemonic)
    let authorization = try XCTUnwrap(challenge.issueGrant(for: challenge.authorityID, credentialIdentity: .init(status: { .current })))
    return try await manager.exportMnemonic(wallet: wallet, authorization: authorization)
}

@MainActor
func exportPrivateKeyForTesting(manager: WalletsManager, wallet: WalletSnapshot, account: WalletAccount? = nil) async throws -> String {
    let challenge = try await manager.makeExportChallenge(wallet: wallet, account: account, kind: .privateKey)
    let authorization = try XCTUnwrap(challenge.issueGrant(for: challenge.authorityID, credentialIdentity: .init(status: { .current })))
    return try await manager.exportPrivateKey(wallet: wallet, account: account, authorization: authorization)
}
