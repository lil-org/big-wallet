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

    private static let walletsManager = WalletsManager.shared

    static func prepare(_ request: SafariRequest) -> DappRequestPreparation {
        switch request.body {
        case .ethereum(let body):
            return EthereumDappRequestProcessor.prepare(request: request, body: body)
        case .solana(let body):
            return SolanaDappRequestProcessor.prepare(request: request, body: body)
        case .unknown(let body):
            return prepareSwitchAccount(request: request, body: body)
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

    private static func prepareSwitchAccount(
        request: SafariRequest,
        body: SafariRequest.Unknown
    ) -> DappRequestPreparation {
        let initiallyConnectedProviders = connectedProviders(in: body.providerConfigurations)
        let preselectedAccounts = preselectedAccounts(for: body.providerConfigurations)
        let chainId = body.providerConfigurations.compactMap(\.chainId).first
        let network = Networks.withChainIdHex(chainId)
        let action = SelectAccountAction(
            coinType: nil,
            selectedAccounts: Set(preselectedAccounts),
            initiallyConnectedProviders: initiallyConnectedProviders,
            network: network
        ) { chain, selectedAccounts in
            guard let selectedAccounts else {
                return response(to: request, error: .userRejected)
            }

            let resolvedChain = chain ?? network ?? Networks.ethereum
            let bodies = selectedAccounts.compactMap {
                selectedAccountResponseBody(for: $0.account, chain: resolvedChain)
            }
            guard bodies.count == selectedAccounts.count else {
                return response(
                    to: request,
                    error: .init(message: Strings.somethingWentWrong)
                )
            }

            let disconnected = disconnectedProviders(
                initiallyConnectedProviders: initiallyConnectedProviders,
                selectedAccounts: selectedAccounts
            )
            let body = ResponseToExtension.Multiple(
                bodies: bodies,
                providersToDisconnect: Array(disconnected)
            )
            return response(to: request, body: .multiple(body))
        }
        return .approval(.switchAccount(action))
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
        for providerConfigurations: [SafariRequest.Unknown.ProviderConfiguration]
    ) -> [SpecificWalletAccount] {
        return preselectedAccounts(
            for: providerConfigurations,
            accountForConfiguration: { configuration in
                guard let coin = WalletCoin.correspondingToInpageProvider(configuration.provider),
                      let address = configuration.address,
                      !address.isEmpty else {
                    return nil
                }
                return walletsManager.getSpecificAccount(coin: coin, address: address)
            },
            suggestedAccountsForProviders: { providers in
                walletsManager.suggestedAccounts(providers: providers)
            },
            defaultSuggestedAccounts: {
                walletsManager.suggestedAccounts()
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
