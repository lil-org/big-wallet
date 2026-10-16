// ∅ 2026 lil org

import Foundation

@concurrent
func awaitBackgroundOperation<Value: Sendable>(
    _ operation: @escaping @Sendable () -> Value
) async -> Value? {
    guard !Task.isCancelled else { return nil }
    let value = operation()
    return Task.isCancelled ? nil : value
}

struct BoundApprovalIntent: Sendable {
    let binding: ExtensionBridge.RequestBinding
    let action: DappRequestAction

    fileprivate init(binding: ExtensionBridge.RequestBinding, action: DappRequestAction) {
        self.binding = binding
        self.action = action
    }
}

struct DappRequestProcessor: DappRequestProcessing {

    private let ethereumNetworkResolver: @MainActor @Sendable (Int) -> ApprovalNetworkResolution
    private let selectionNetworkResolver: @MainActor @Sendable (String?) -> EthereumNetwork?
    private let customDefinitionResult: @MainActor @Sendable (EthereumNetworkFromDapp) -> CustomNetworkInsertionResult
    private let solana: Solana?

    nonisolated init(
        ethereumNetworkResolver: @escaping @MainActor @Sendable (Int) -> ApprovalNetworkResolution = {
            NetworkResolver.main.approvalResolution(chainId: $0)
        },
        selectionNetworkResolver: @escaping @MainActor @Sendable (String?) -> EthereumNetwork? = { Networks.withChainIdHex($0) },
        customDefinitionResult: @escaping @MainActor @Sendable (EthereumNetworkFromDapp) -> CustomNetworkInsertionResult = {
            Networks.existingCustomDefinitionResult(networkFromDapp: $0)
        },
        solana: Solana? = nil
    ) {
        self.ethereumNetworkResolver = ethereumNetworkResolver
        self.selectionNetworkResolver = selectionNetworkResolver
        self.customDefinitionResult = customDefinitionResult
        self.solana = solana
    }

    func prepare(
        _ binding: ExtensionBridge.RequestBinding,
        catalog: WalletReviewCatalog?
    ) -> DappRequestPreparation {
        let request = binding.request
        let preparation: UnboundDappRequestPreparation
        switch request.body {
        case .ethereum(let body):
            preparation = EthereumDappRequestProcessor.prepare(
                request: request,
                body: body,
                catalog: catalog,
                networkResolver: ethereumNetworkResolver,
                customDefinitionResult: customDefinitionResult
            )
        case .solana(let body):
            preparation = SolanaDappRequestProcessor.prepare(
                request: request,
                body: body,
                catalog: catalog,
                solana: solana
            )
        case .unknown(let body):
            guard let catalog else { return .needsCatalog }
            preparation = Self.prepareSwitchAccount(
                request: request,
                body: body,
                catalog: catalog,
                networkResolver: selectionNetworkResolver
            )
        }
        return bind(preparation, to: binding)
    }

    private func bind(
        _ preparation: UnboundDappRequestPreparation,
        to binding: ExtensionBridge.RequestBinding
    ) -> DappRequestPreparation {
        switch preparation {
        case .needsCatalog:
            return .needsCatalog
        case .unavailable:
            return .unavailable
        case .immediate(let resolution):
            return .immediate(resolution)
        case .approval(let action):
            return .approval(BoundApprovalIntent(binding: binding, action: action))
        }
    }

    func execute(
        permit: ExtensionBridge.ApprovedExecutionPermit,
        signer: (any WalletSigning)?
    ) async -> ApprovedExecutionResult {
        guard permit.consumeExecution() else { return .rollback }
        switch permit.approval.kind {
        case .accountSelection:
            return ApprovedCompletion.accountSelection(permit: permit, fallbackNetwork: {
                selectionNetworkResolver("0x1")
            }).map(ApprovedExecutionResult.completed) ?? .rollback
        case .signing(_, let payload):
            guard permit.isExecuting,
                  payload.coin.correspondingInpageProvider == permit.request.provider,
                  let signer else { return .rollback }
            switch await signer.sign() {
            case .success(let output):
                guard permit.isExecuting else { return .rollback }
                guard output.executionID == permit.executionID else {
                    return Self.approvedFailure(.internalError, permit: permit)
                }
                switch output {
                case .response(let completion):
                    return .completed(completion)
                case .broadcast(let broadcast):
                    return .broadcast(broadcast)
                }
            case .failure(.authorizationUnavailable):
                return .rollback
            case .failure(.failedToSign):
                return Self.approvedFailure(
                    .init(message: Strings.failedToSign, code: ProviderResponseError.internalErrorCode),
                    permit: permit
                )
            case .failure(.invalidTransaction):
                let error: ProviderResponseError = payload.coin == .solana
                    ? .init(message: Strings.somethingWentWrong, code: 4200)
                    : .internalError
                return Self.approvedFailure(error, permit: permit)
            }
        case .addEthereumChain:
            guard let completion = ApprovedCompletion.chainAdded(permit: permit) else {
                return Self.approvedFailure(.init(message: Strings.somethingWentWrong), permit: permit)
            }
            return .completed(completion)
        }
    }

    private static func approvedFailure(
        _ error: ProviderResponseError,
        permit: ExtensionBridge.ApprovedExecutionPermit
    ) -> ApprovedExecutionResult {
        ApprovedCompletion.failure(error, permit: permit).map(ApprovedExecutionResult.completed) ?? .rollback
    }

    private static func prepareSwitchAccount(
        request: SafariRequest,
        body: SafariRequest.Unknown,
        catalog: WalletReviewCatalog,
        networkResolver: @MainActor (String?) -> EthereumNetwork?
    ) -> UnboundDappRequestPreparation {
        let initiallyConnectedProviders = connectedProviders(in: body.providerConfigurations)
        let preselectedAccounts = initiallyConnectedProviders.isEmpty
            ? catalog.suggestedAccounts()
            : request.connectedAccounts.compactMap { catalog.specificAccount(descriptor: $0) }
        let chainId = body.providerConfigurations.compactMap(\.chainId).first
        let network = networkResolver(chainId)
        let action = SelectAccountAction(
            coinType: nil,
            selectedAccounts: Set(preselectedAccounts),
            initiallyConnectedProviders: initiallyConnectedProviders,
            network: network
        )
        return .approval(.switchAccount(action))
    }

    nonisolated static func accountSelectionResponse(
        request: SafariRequest,
        action: SelectAccountAction,
        selection: ResolvedDappApproval.Selection,
        fallbackNetwork: () -> EthereumNetwork? = { Networks.ethereum }
    ) -> ResponseToExtension {
        let accounts = selection.accounts
        let network = selection.network
        let descriptors = accounts.map { WalletAccountDescriptor(walletID: $0.walletId, account: $0.account) }

        switch request.body {
        case .unknown:
            let resolvedChain = network ?? fallbackNetwork()
            var updates = accounts.compactMap {
                selectedAccountUpdate(for: $0.account, chain: resolvedChain)
            }
            guard updates.count == accounts.count else {
                return response(to: request, error: .internalError)
            }
            for provider in disconnectedProviders(
                initiallyConnectedProviders: action.initiallyConnectedProviders,
                selectedAccounts: accounts
            ) {
                switch provider {
                case .ethereum: updates.append(.disconnectEthereum)
                case .solana: updates.append(.disconnectSolana)
                case .unknown, .multiple: break
                }
            }
            return ResponseToExtension(
                for: request, payload: .result(.null), mutation: .accounts(updates),
                approvedAccounts: descriptors
            )
        case .ethereum(let body) where body.method == .requestAccounts:
            guard let network, let account = accounts.first?.account,
                  account.coin == .ethereum else {
                return response(to: request, error: .internalError)
            }
            return ResponseToExtension(
                for: request,
                payload: .result(.strings([account.address])),
                mutation: .accounts([.ethereum(address: account.address, chainId: network.chainIdHexString)]),
                approvedAccounts: descriptors
            )
        case .solana(let body) where body.method == .connect:
            guard let account = accounts.first?.account, account.coin == .solana else {
                return response(to: request, error: .internalError)
            }
            return ResponseToExtension(
                for: request,
                payload: .result(.solanaPublicKey(account.address)),
                mutation: .accounts([.solana(publicKey: account.address)]),
                approvedAccounts: descriptors
            )
        case .ethereum, .solana:
            return response(to: request, error: .internalError)
        }
    }

    nonisolated private static func selectedAccountUpdate(
        for account: WalletAccount,
        chain: EthereumNetwork?
    ) -> ResponseToExtension.AccountUpdate? {
        switch account.coin {
        case .ethereum:
            guard let chain else { return nil }
            return .ethereum(address: account.address, chainId: chain.chainIdHexString)
        case .solana:
            return .solana(publicKey: account.address)
        }
    }

    nonisolated private static func disconnectedProviders(
        initiallyConnectedProviders: Set<InpageProvider>,
        selectedAccounts: [SpecificWalletAccount]
    ) -> Set<InpageProvider> {
        let selectedCoins = Set(selectedAccounts.map { $0.account.coin })
        return initiallyConnectedProviders.filter { provider in
            guard let coin = WalletCoin.correspondingToInpageProvider(provider) else {
                return true
            }
            return !selectedCoins.contains(coin)
        }
    }

    nonisolated private static func connectedProviders(
        in providerConfigurations: [SafariRequest.Unknown.ProviderConfiguration]
    ) -> Set<InpageProvider> {
        return Set(providerConfigurations.compactMap { configuration in
            guard WalletCoin.correspondingToInpageProvider(configuration.provider) != nil else {
                return nil
            }
            if configuration.provider == .ethereum,
               configuration.address?.isEmpty ?? true {
                return nil
            }
            return configuration.provider
        })
    }

    nonisolated private static func response(
        to request: SafariRequest,
        error: ProviderResponseError
    ) -> ResponseToExtension {
        return ResponseToExtension(for: request, payload: .error(error))
    }
}
