import Foundation
import WalletDomain
import WalletAuthority
import WalletNetworking

@MainActor
final class ApplicationServices {
    static let shared = ApplicationServices()

    let authority: WalletAuthoritySystem
    let authorization: any AlchemyAuthorizationProviding
    let ethereumRPC: EthereumRPC
    let ethereum: EthereumTransactionPreparation
    let solana: SolanaRPCClient
    let safariRPC: SafariRPCClient
    let prices: PriceService
    let runtimeIdentityDirectoryURL: URL?

    var wallets: WalletsManager { authority.wallets }
    var metadata: WalletsMetadataService { authority.metadata }
    var credentials: WalletCredentials { authority.credentials }
    var requests: ExtensionBridge { authority.requests }
    var networks: NetworkResolver { authority.networks }
    lazy var access = WalletAccessController(credentials: credentials)
#if os(macOS)
    lazy var nativeApprovals = NativeApprovalService(dependencies: .live(
        bridge: requests, runtimeIdentityDirectoryURL: runtimeIdentityDirectoryURL
    ))
#endif

    lazy var popupSessions = authority.makePopupRequestSessions(
        presentation: popupPresentation,
        loadTransactionContext: { [ethereum, prices] action in
            Task { await prices.update() }
            guard let balance = try? await ethereum.getBalance(network: action.chain, address: action.account.address) else { return nil }
            return balance.eth(shortest: true) + " " + action.chain.symbol
        }
    )

    private init() {
        let catalog: NetworkCatalog?
        let decodedChainIDs: Set<Int>
        do {
            catalog = try NetworkCatalog.load(in: .main)
            decodedChainIDs = []
        } catch {
            catalog = nil
            if let failure = error as? NetworkCatalogLoadError, case .invalidCatalog(let identifiers) = failure {
                decodedChainIDs = identifiers
            } else {
                decodedChainIDs = []
            }
        }
#if BW_SAFARI_VM_TESTING
        let fixtures = SafariVMFixtures.shared
        runtimeIdentityDirectoryURL = fixtures.isLocal
            ? fixtures.root.appendingPathComponent("native-runtime-identities-v1", isDirectory: true)
            : AmbientRuntimeIdentity.defaultDirectoryURL
        let services = SafariVMApplicationServices.make(
            catalog: catalog, catalogOwnedChainIds: BundledNetworkOwnership.chainIds,
            decodedChainIds: decodedChainIDs, messages: Self.authorityMessages
        )
        authority = services.authority
        authorization = services.authorization
        ethereumRPC = services.ethereumRPC
        ethereum = services.ethereum
        solana = services.solana
        safariRPC = services.safariRPC
        prices = services.prices
#else
        runtimeIdentityDirectoryURL = AmbientRuntimeIdentity.defaultDirectoryURL
        let storage = AuthorityStorageConfiguration.application
        let authorization = AlchemyJWTProvider.live(bundle: .main, containerURL: storage.containerURL)
        self.authorization = authorization
        let rpc = EthereumRPC(authorizationProvider: authorization)
        ethereumRPC = rpc
        let inspector = TransactionInspector(urlSession: .shared)
        let ethereum = EthereumTransactionPreparation(rpc: rpc, interpretTransaction: inspector.interpret)
        self.ethereum = ethereum
        let solana = SolanaRPCClient(
            urlSession: URLSession(configuration: .default),
            authorizationProvider: authorization,
            messages: .init(failedToSend: Strings.failedToSend, blockhashNotFound: Strings.solanaBlockhashNotFound)
        )
        self.solana = solana
        safariRPC = SafariRPCClient(urlSession: URLSession(configuration: .default), authorizationProvider: authorization)
        prices = PriceService(urlSession: URLSession(configuration: .ephemeral))
        authority = WalletAuthoritySystem.live(
            catalog: catalog, catalogOwnedChainIds: BundledNetworkOwnership.chainIds,
            decodedChainIds: decodedChainIDs,
            solanaEndpoints: SolanaRPCClient.RPCConfiguration.bundled,
            broadcaster: SignedBroadcastClient(ethereum: EthereumBroadcastClient(rpc: rpc), solana: solana),
            preparation: ethereum.makePreparationOperations(), storage: storage,
            messages: Self.authorityMessages
        )
#endif
    }

    func prewarm() {
        guard let authorization = authorization as? AlchemyJWTProvider else { return }
        AlchemyJWTProvider.prewarmForApplicationLifecycle(provider: { authorization })
    }

    var popupPresentation: PopupApprovalStatePresenter.Environment {
        let networks = networks
        let prices = prices
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        return .init(
            networks: { networks.allNetworks }, customNetworks: { networks.visibleCustomNetworks },
            price: { prices.forNetwork($0) },
            accountName: { $1.nameOrCroppedAddress(walletId: $0) },
            icon: { account in
                guard let data = account.image?.pngDataRepresentation else { return nil }
                return "data:image/png;base64," + data.base64EncodedString()
            },
            transactionValue: { $0.valueWithSymbol(chain: $1, price: $2, withLabel: true) },
            transactionFeeLines: { $0.feeSummaryLines(chain: $1, price: $2) },
            transactionDataInterpretation: { $0.diplayDataInterpretation },
            solanaClusterDescription: { $0.description(for: $1) },
            approvalSubjectTitle: { $0.title },
            transactionNotice: { PopupTransactionNotice(title: $0.title, message: $0.message) },
            popupStrings: Strings.popup,
            layoutDirection: Locale.Language(identifier: language).characterDirection == .rightToLeft ? .rtl : .ltr
        )
    }

    private static var authorityMessages: AuthorityMessages {
        AuthorityMessages(values: [
            .manualSwitchCapacityReached: Strings.manualSwitchCapacityReached,
            .addAccountToConnect: Strings.addAccountToConnect,
            .addNetwork: Strings.addNetwork,
            .approvalInterrupted: Strings.approvalInterrupted,
            .calculating: Strings.calculating,
            .cancel: Strings.cancel,
            .canceled: Strings.canceled,
            .connect: Strings.connect,
            .connectWallet: Strings.connectWallet,
            .data: Strings.data,
            .failedToLoad: Strings.failedToLoad,
            .failedToSend: Strings.failedToSend,
            .failedToSign: Strings.failedToSign,
            .failedToVerify: Strings.failedToVerify,
            .feesUpdated: Strings.feesUpdated,
            .feesUpdatedReview: Strings.feesUpdatedReview,
            .privateBrowsingUnsupported: Strings.privateBrowsingUnsupported,
            .providerNotReady: Strings.providerNotReady,
            .rawSolanaTransactionWarning: Strings.rawSolanaTransactionWarning,
            .secureApprovalSetupRequired: Strings.secureApprovalSetupRequired,
            .sendTransaction: Strings.sendTransaction,
            .solanaBlockhashNotFound: Strings.solanaBlockhashNotFound,
            .solanaConfirmationTimedOut: Strings.solanaConfirmationTimedOut,
            .somethingWentWrong: Strings.somethingWentWrong,
            .switchAccount: Strings.switchAccount,
            .transactionSubmissionStatusUnknown: Strings.transactionSubmissionStatusUnknown,
            .unrecognizedChainId: Strings.unrecognizedChainId,
            .unsafeFees: Strings.unsafeFees,
            .unsafeFeesEdit: Strings.unsafeFeesEdit,
            .unsupportedSolanaSendOptions: Strings.unsupportedSolanaSendOptions,
        ])
    }
}

extension NetworkCatalog {
    static func load(in bundle: Bundle = .main) throws -> NetworkCatalog {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw NetworkCatalogLoadError.missingResource
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw NetworkCatalogLoadError.unreadableResource
        }

        do {
            return try NetworkCatalog(data: data)
        } catch {
            throw NetworkCatalogLoadError.invalidCatalog(
                decodedChainIds: decodedChainIds(from: data)
            )
        }
    }

}
