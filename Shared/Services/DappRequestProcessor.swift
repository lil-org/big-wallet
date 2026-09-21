// ∅ 2026 lil org

import Foundation

private final class CancellableCallbackState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?
    private var isFinished = false

    func install(_ continuation: CheckedContinuation<Value?, Never>) -> Bool {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            continuation.resume(returning: nil)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func resume(returning value: Value?) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

func awaitCancellableCallback<Value: Sendable>(
    isolation: isolated (any Actor)? = #isolation,
    _ start: (@escaping @Sendable (Value) -> Void) -> Void
) async -> Value? {
    let state = CancellableCallbackState<Value>()
    return await withTaskCancellationHandler(
        operation: {
            await withCheckedContinuation(isolation: isolation) { continuation in
                guard state.install(continuation) else { return }
                start { state.resume(returning: $0) }
            }
        },
        onCancel: {
            state.resume(returning: nil)
        },
        isolation: isolation
    )
}

func awaitBackgroundOperation<Value: Sendable>(
    _ operation: @escaping @Sendable () -> Value
) async -> Value? {
    return await withTaskGroup(of: Value?.self) { group in
        group.addTask {
            guard !Task.isCancelled else { return nil }
            let value = operation()
            return Task.isCancelled ? nil : value
        }
        return await group.next() ?? nil
    }
}

func awaitBackgroundOptionalOperation<Value: Sendable>(
    _ operation: @escaping @Sendable () -> Value?
) async -> Value? {
    let value = await awaitBackgroundOperation(operation)
    return value ?? nil
}

struct DappRequestProcessor: DappRequestProcessing {

    func prepare(
        _ request: SafariRequest,
        catalog: WalletReviewCatalog
    ) -> DappRequestPreparation {
        switch request.body {
        case .ethereum(let body):
            return EthereumDappRequestProcessor.prepare(
                request: request,
                body: body,
                catalog: catalog
            )
        case .solana(let body):
            return SolanaDappRequestProcessor.prepare(
                request: request,
                body: body,
                catalog: catalog
            )
        case .unknown(let body):
            return Self.prepareSwitchAccount(
                request: request,
                body: body,
                catalog: catalog
            )
        }
    }

    func prepareWithoutWallets(
        _ request: SafariRequest
    ) -> DappRequestPreparation? {
        switch request.body {
        case .ethereum(let body):
            return EthereumDappRequestProcessor.prepareWithoutWallets(
                request: request,
                body: body
            )
        case .solana(let body):
            return SolanaDappRequestProcessor.prepareWithoutWallets(
                request: request,
                body: body
            )
        case .unknown:
            return nil
        }
    }

    func execute(
        request: SafariRequest,
        approval: DappApprovalValidator.Approval,
        signer: (any WalletSigning)?
    ) async -> DappExecutionResult {
        switch approval {
        case .accountSelection(let selectionAction, let selection):
            return .response(Self.executeAccountSelection(
                request: request,
                action: selectionAction,
                selection: selection
            ))
        case .message, .transaction, .addEthereumChain:
            switch request.body {
            case .ethereum:
                return await EthereumDappRequestProcessor.execute(
                    request: request,
                    approval: approval,
                    signer: signer
                )
            case .solana:
                return await SolanaDappRequestProcessor.execute(
                    request: request,
                    approval: approval,
                    signer: signer
                )
            case .unknown:
                break
            }
        }
        return .response(Self.response(to: request, error: .internalError))
    }

    private static func prepareSwitchAccount(
        request: SafariRequest,
        body: SafariRequest.Unknown,
        catalog: WalletReviewCatalog
    ) -> DappRequestPreparation {
        let initiallyConnectedProviders = connectedProviders(in: body.providerConfigurations)
        let preselectedAccounts = preselectedAccounts(
            for: body.providerConfigurations,
            catalog: catalog
        )
        let chainId = body.providerConfigurations.compactMap(\.chainId).first
        let network = Networks.withChainIdHex(chainId)
        let action = SelectAccountAction(
            coinType: nil,
            selectedAccounts: Set(preselectedAccounts),
            initiallyConnectedProviders: initiallyConnectedProviders,
            network: network
        )
        return .approval(.switchAccount(action))
    }

    private static func executeAccountSelection(
        request: SafariRequest,
        action: SelectAccountAction,
        selection: DappApprovalValidator.Selection
    ) -> ResponseToExtension {
        let accounts = selection.accounts
        let network = selection.network

        switch request.body {
        case .unknown:
            let resolvedChain = network ?? Networks.ethereum
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
                for: request, payload: .result(.null), mutation: .accounts(updates)
            )
        case .ethereum(let body) where body.method == .requestAccounts:
            guard let network, let account = accounts.first?.account,
                  account.coin == .ethereum else {
                return response(to: request, error: .internalError)
            }
            return ResponseToExtension(
                for: request,
                payload: .result(.strings([account.address])),
                mutation: .accounts([.ethereum(address: account.address, chainId: network.chainIdHexString)])
            )
        case .solana(let body) where body.method == .connect:
            guard let account = accounts.first?.account, account.coin == .solana else {
                return response(to: request, error: .internalError)
            }
            return ResponseToExtension(
                for: request,
                payload: .result(.solanaPublicKey(account.address)),
                mutation: .accounts([.solana(publicKey: account.address)])
            )
        case .ethereum, .solana:
            return response(to: request, error: .internalError)
        }
    }

    private static func selectedAccountUpdate(
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

    private static func preselectedAccounts(
        for providerConfigurations: [SafariRequest.Unknown.ProviderConfiguration],
        catalog: WalletReviewCatalog
    ) -> [SpecificWalletAccount] {
        return preselectedAccounts(
            for: providerConfigurations,
            accountForConfiguration: { configuration in
                guard let coin = WalletCoin.correspondingToInpageProvider(configuration.provider),
                      let address = configuration.address,
                      !address.isEmpty else {
                    return nil
                }
                return catalog.specificAccount(coin: coin, address: address)
            },
            suggestedAccountsForProviders: { providers in
                catalog.suggestedAccounts(providers: providers)
            },
            defaultSuggestedAccounts: {
                catalog.suggestedAccounts()
            }
        )
    }

    static func preselectedAccounts(
        for providerConfigurations: [SafariRequest.Unknown.ProviderConfiguration],
        accountForConfiguration: (SafariRequest.Unknown.ProviderConfiguration) -> SpecificWalletAccount?,
        suggestedAccountsForProviders: (Set<InpageProvider>) -> [SpecificWalletAccount],
        defaultSuggestedAccounts: () -> [SpecificWalletAccount]
    ) -> [SpecificWalletAccount] {
        return preselectedAccounts(
            for: providerConfigurations,
            accountForConfiguration: accountForConfiguration,
            suggestedValuesForProviders: suggestedAccountsForProviders,
            defaultSuggestedValues: defaultSuggestedAccounts
        )
    }

    static func preselectedAccounts<Value>(
        for providerConfigurations: [SafariRequest.Unknown.ProviderConfiguration],
        accountForConfiguration: (SafariRequest.Unknown.ProviderConfiguration) -> Value?,
        suggestedValuesForProviders: (Set<InpageProvider>) -> [Value],
        defaultSuggestedValues: () -> [Value]
    ) -> [Value] {
        let connectedProviders = connectedProviders(in: providerConfigurations)
        guard !connectedProviders.isEmpty else {
            return defaultSuggestedValues()
        }

        var values = [Value]()
        var resolvedProviders = Set<InpageProvider>()
        for configuration in providerConfigurations {
            guard !resolvedProviders.contains(configuration.provider),
                  WalletCoin.correspondingToInpageProvider(configuration.provider) != nil,
                  let value = accountForConfiguration(configuration) else {
                continue
            }
            values.append(value)
            resolvedProviders.insert(configuration.provider)
        }

        let missingProviders = connectedProviders.subtracting(resolvedProviders)
        guard !missingProviders.isEmpty else { return values }
        return values + suggestedValuesForProviders(missingProviders)
    }

    private static func disconnectedProviders(
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

    private static func connectedProviders(
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

    private static func response(
        to request: SafariRequest,
        error: ProviderResponseError
    ) -> ResponseToExtension {
        return ResponseToExtension(for: request, payload: .error(error))
    }
}
