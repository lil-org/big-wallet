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

struct DappRequestProcessor {

    static func prepare(
        _ request: SafariRequest,
        walletAccess: WalletAccess = SourceWalletAccess.shared
    ) -> DappRequestPreparation {
        switch request.body {
        case .ethereum(let body):
            return EthereumDappRequestProcessor.prepare(
                request: request,
                body: body,
                walletAccess: walletAccess
            )
        case .solana(let body):
            return SolanaDappRequestProcessor.prepare(
                request: request,
                body: body,
                walletAccess: walletAccess
            )
        case .unknown(let body):
            return prepareSwitchAccount(
                request: request,
                body: body,
                walletAccess: walletAccess
            )
        }
    }

    static func prepareWithoutWallets(
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

    static func execute(
        request: SafariRequest,
        action: DappRequestAction,
        decision: DappApprovalDecision,
        walletAccess: WalletAccess?
    ) async -> DappExecutionResult {
        switch (action, decision) {
        case (.selectAccount(let selectionAction), .accountSelection(let selection)),
             (.switchAccount(let selectionAction), .accountSelection(let selection)):
            return .response(executeAccountSelection(
                request: request,
                action: selectionAction,
                selection: selection,
                walletAccess: walletAccess
            ))
        case (.approveMessage, .message), (.approveTransaction, .transaction),
             (.addEthereumChain, .addEthereumChain):
            switch request.body {
            case .ethereum:
                return await EthereumDappRequestProcessor.execute(
                    request: request,
                    action: action,
                    decision: decision,
                    walletAccess: walletAccess
                )
            case .solana:
                return await SolanaDappRequestProcessor.execute(
                    request: request,
                    action: action,
                    decision: decision,
                    walletAccess: walletAccess
                )
            case .unknown:
                break
            }
        default:
            break
        }
        return .response(response(to: request, error: .internalError))
    }

    private static func prepareSwitchAccount(
        request: SafariRequest,
        body: SafariRequest.Unknown,
        walletAccess: WalletAccess
    ) -> DappRequestPreparation {
        let initiallyConnectedProviders = connectedProviders(in: body.providerConfigurations)
        let preselectedAccounts = preselectedAccounts(
            for: body.providerConfigurations,
            walletAccess: walletAccess
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
        selection: DappApprovalDecision.AccountSelection,
        walletAccess: WalletAccess?
    ) -> ResponseToExtension {
        guard let walletAccess else {
            return response(to: request, error: .internalError)
        }
        var accounts = [SpecificWalletAccount]()
        var selectedCoins = Set<WalletCoin>()
        for identity in selection.accounts {
            guard let coin = WalletCoin.correspondingToInpageProvider(identity.provider),
                  action.coinType == nil || action.coinType == coin,
                  selectedCoins.insert(coin).inserted else {
                return response(to: request, error: .internalError)
            }
            let matches = walletAccess.orderedAccounts.filter {
                $0.walletId == identity.walletID &&
                    $0.account.coin == coin &&
                    coin.normalizedAddress($0.account.address) ==
                        coin.normalizedAddress(identity.address) &&
                    $0.account.derivationPath == identity.derivationPath
            }
            guard matches.count == 1 else {
                return response(to: request, error: .internalError)
            }
            accounts.append(matches[0])
        }
        let chainID = selection.ethereumChainID ?? action.network?.chainIdHexString
        let network = chainID.flatMap(Networks.withChainIdHex)
        guard !(accounts.isEmpty && action.initiallyConnectedProviders.isEmpty),
              !accounts.contains(where: { $0.account.coin == .ethereum }) || network != nil
        else { return response(to: request, error: .internalError) }

        switch request.body {
        case .unknown:
            let resolvedChain = network ?? Networks.ethereum
            let bodies = accounts.compactMap {
                selectedAccountResponseBody(for: $0.account, chain: resolvedChain)
            }
            guard bodies.count == accounts.count else {
                return response(to: request, error: .internalError)
            }
            return response(to: request, body: .multiple(.init(
                bodies: bodies,
                providersToDisconnect: Array(disconnectedProviders(
                    initiallyConnectedProviders: action.initiallyConnectedProviders,
                    selectedAccounts: accounts
                ))
            )))
        case .ethereum(let body) where body.method == .requestAccounts:
            guard let network, let account = accounts.first?.account,
                  account.coin == .ethereum else {
                return response(to: request, error: .internalError)
            }
            return response(to: request, body: .ethereum(.init(
                results: [account.address],
                chainId: network.chainIdHexString
            )))
        case .solana(let body) where body.method == .connect:
            guard let account = accounts.first?.account, account.coin == .solana else {
                return response(to: request, error: .internalError)
            }
            return response(to: request, body: .solana(.init(publicKey: account.address)))
        case .ethereum, .solana:
            return response(to: request, error: .internalError)
        }
    }

    private static func selectedAccountResponseBody(
        for account: WalletAccount,
        chain: EthereumNetwork?
    ) -> ResponseToExtension.Body? {
        switch account.coin {
        case .ethereum:
            guard let chain else { return nil }
            return .ethereum(.init(
                results: [account.address],
                chainId: chain.chainIdHexString
            ))
        case .solana:
            return .solana(.init(publicKey: account.address))
        }
    }

    private static func preselectedAccounts(
        for providerConfigurations: [SafariRequest.Unknown.ProviderConfiguration],
        walletAccess: WalletAccess
    ) -> [SpecificWalletAccount] {
        return preselectedAccounts(
            for: providerConfigurations,
            accountForConfiguration: { configuration in
                guard let coin = WalletCoin.correspondingToInpageProvider(configuration.provider),
                      let address = configuration.address,
                      !address.isEmpty else {
                    return nil
                }
                return walletAccess.specificAccount(coin: coin, address: address)
            },
            suggestedAccountsForProviders: { providers in
                walletAccess.suggestedAccounts(providers: providers)
            },
            defaultSuggestedAccounts: {
                walletAccess.suggestedAccounts()
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
        body: ResponseToExtension.Body
    ) -> ResponseToExtension {
        return ResponseToExtension(for: request, payload: .body(body))
    }

    private static func response(
        to request: SafariRequest,
        error: ProviderResponseError
    ) -> ResponseToExtension {
        return ResponseToExtension(for: request, payload: .error(error))
    }
}
