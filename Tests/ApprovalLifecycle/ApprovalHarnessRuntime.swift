import Darwin
import Foundation
import Synchronization

private final class HarnessRejectNetworkProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: HarnessError.invalid("Unexpected network access in approval worker"))
    }
    override func stopLoading() {}
}

final class HarnessNetworks: Sendable {
    private let file: URL
    private let lock: CrossProcessFileLock

    init(root: URL) throws {
        file = root.appendingPathComponent("networks.json")
        lock = CrossProcessFileLock(fileURL: root.appendingPathComponent("fixture-networks.lock"))
        if !FileManager.default.fileExists(atPath: file.path) {
            try save(Dictionary(uniqueKeysWithValues: [1, 10].map { id in
                (String(id), EthereumNetworkFromDapp(chainId: String.hex(id, withPrefix: true),
                    rpcUrls: ["https://rpc.fixture.invalid/\(id)"], blockExplorerUrls: [],
                    nativeCurrency: .init(decimals: 18, name: "Ether", symbol: "ETH"), chainName: "Fixture \(id)"))
            }))
        }
    }

    func resolved(_ id: Int) -> ResolvedEthereumNetwork? {
        guard let definition = try? load()[String(id)], let url = definition.defaultRpcURL else { return nil }
        return .init(network: EthereumNetwork(chainId: id, name: definition.chainName, symbol: definition.nativeCurrency.symbol,
            rpcEndpoint: .unauthenticated(url), isTestnet: true, mightShowPrice: false, explorer: nil), source: .custom)
    }

    func approval(_ id: Int) -> ApprovalNetworkResolution { resolved(id).map(ApprovalNetworkResolution.resolved) ?? .missing }
    func resolution(_ id: Int) -> EthereumNetworkResolution { resolved(id).map(EthereumNetworkResolution.resolved) ?? .unknown }
    func network(_ value: String?) -> EthereumNetwork? { value.flatMap { Int(hexString: $0) }.flatMap { resolved($0)?.network } }
    func all() -> [EthereumNetwork] { ((try? load().keys.compactMap { Int($0) }.sorted()) ?? []).compactMap { resolved($0)?.network } }

    func matches(_ requested: EthereumNetworkFromDapp) -> CustomNetworkInsertionResult {
        guard let id = Int(hexString: requested.chainId), let existing = try? load()[String(id)],
              let existingURL = existing.defaultRpcURL else { return .unavailable }
        return CustomNetworkDefinition.requestedRPCURLs(for: requested).contains {
            CustomNetworkDefinition.matches(requested: requested, requestedRPCURL: $0, existing: existing, existingRPCURL: existingURL)
        } ? .matching : .conflict
    }

    func insert(_ definition: EthereumNetworkFromDapp) -> CustomNetworkInsertionResult {
        do {
            try lock.acquire(timeoutNanoseconds: 1_000_000_000, pollNanoseconds: 1_000_000)
            defer { lock.release() }
            guard let id = Int(hexString: definition.chainId), definition.defaultRpcURL != nil else { return .unavailable }
            var records = try load()
            if records[String(id)] != nil { return matches(definition) }
            records[String(id)] = definition
            try save(records)
            return .inserted
        } catch { return .unavailable }
    }

    func change(_ payload: HarnessValue) throws {
        guard let id = payload["chainId"].int, id > 0 else { throw HarnessError.invalid("Invalid chainId") }
        try lock.acquire(timeoutNanoseconds: 1_000_000_000, pollNanoseconds: 1_000_000)
        defer { lock.release() }
        var records = try load()
        if payload["action"].string == "remove" { records[String(id)] = nil }
        else {
            records[String(id)] = EthereumNetworkFromDapp(chainId: String.hex(id, withPrefix: true),
                rpcUrls: [payload["rpcURL"].string ?? "https://changed.fixture.invalid/\(id)"], blockExplorerUrls: [],
                nativeCurrency: .init(decimals: 18, name: "Ether", symbol: "ETH"), chainName: "Fixture \(id)")
        }
        try save(records)
    }

    private func load() throws -> [String: EthereumNetworkFromDapp] {
        try JSONDecoder().decode([String: EthereumNetworkFromDapp].self, from: Data(contentsOf: file))
    }
    private func save(_ records: [String: EthereumNetworkFromDapp]) throws { try JSONEncoder().encode(records).write(to: file, options: .atomic) }
}

private final class HarnessPopupSigningSource: WalletSigningSource {
    let approvedAccount: WalletAccountDescriptor
    var commit: WalletSigningCommit {
        .vault(acquire: { [weak self] in
            self?.isCurrent() == true ? WalletExecutionLease(release: {}) : nil
        })
    }
    private let repository: WalletRepository
    private struct State { var source: WalletRepository.Source?; var invalidated = false }
    private let state = Mutex(State())

    init(approvedAccount: WalletAccountDescriptor, repository: WalletRepository) {
        self.approvedAccount = approvedAccount
        self.repository = repository
    }

    func isCurrent() -> Bool {
        let current = state.withLock { $0 }
        guard !current.invalidated else { return false }
        return current.source.map { (try? repository.sourceIsCurrent($0)) == true } ?? approvedAccount.isValid
    }

    @MainActor
    func sign(_ operation: ApprovedWalletSigningOperation) async -> Result<WalletSigningOutput, WalletSigningFailure> {
        guard isCurrent(), operation.approvedAccount == approvedAccount else { return .failure(.authorizationUnavailable) }
        let attempt = await repository.sign(operation)
        state.withLock { $0.source = attempt.source }
        return isCurrent() ? attempt.result : .failure(.authorizationUnavailable)
    }

    func retireSigningMaterial() {}
    func invalidate() { state.withLock { $0.invalidated = true } }
}

@MainActor
final class HarnessRuntime {
    let options: HarnessWorkerOptions
    let ipc: HarnessIPC
    let fixtures: HarnessFixtureStorage
    let networks: HarnessNetworks
    let fileStore: ExtensionRequestFileStore
    let bridge: ExtensionBridge
    let store: HarnessObservedStore
    let wallets: WalletsManager
    let processor: HarnessObservedProcessor
    let identity: AmbientRuntimeIdentity
    private var registeredRuntime: AmbientRuntimeIdentity?
    private var coordinators = [ExtensionBridge.Handle: NativeApprovalCoordinator]()
    private var savedConsents = [String: ReviewConsent]()
    private var consentLabels = [ExtensionBridge.Handle: String]()
    private var reviewedRevisions = [ExtensionBridge.Handle: UInt64]()
    private var configurationKeys = Set<String>()
    private var heldClaims = [String: ExtensionBridge.ApprovalClaim]()
    private var activeCommands = Set<String>()
    private var authenticationResult = true

    init(options: HarnessWorkerOptions, ipc: HarnessIPC) throws {
        self.options = options
        self.ipc = ipc
        let fixtures = try HarnessFixtureStorage(root: options.root, role: options.role)
        self.fixtures = fixtures
        let networks = try HarnessNetworks(root: fixtures.root)
        self.networks = networks
        let persistence = HarnessPersistence(ipc: ipc)
        let fileStore = ExtensionRequestFileStore(rootURL: fixtures.root.appendingPathComponent("bridge", isDirectory: true),
            directoryBoundary: fixtures.root, dependencies: .init(clock: fixtures.clock.now,
                fileIO: persistence.fileIO(directoryBoundary: fixtures.root),
                completeChainAddition: { permit in
                    EthereumDappRequestProcessor.completeApprovedChainAddition(permit: permit,
                        networkResolver: networks.resolution, customDefinitionResult: networks.matches, insertNetwork: networks.insert)
                }, resolveImmediate: { resolution, request in
                    resolution.response(for: request, networkResolver: networks.resolution, customDefinitionResult: networks.matches)
                }))
        self.fileStore = fileStore
        let bridge = ExtensionBridge(store: fileStore)
        self.bridge = bridge
        store = HarnessObservedStore(bridge: bridge, ipc: ipc)
        wallets = WalletsManager(keychain: fixtures.keychain, reloadMetadata: {}, publishLocalChange: {},
            walletSourceMutator: HarnessWalletMutator(store: fileStore, ipc: ipc),
            notifications: .init(postLocalChange: {}, postMutation: {}, startObserving: { _, _ in }, stopObserving: { _ in }, isExternalChange: { _ in false }),
            metadataMutations: .init(removeWallet: { _ in }, removeAccounts: { _, _ in }))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HarnessRejectNetworkProtocol.self]
        let solana = Solana(urlSession: URLSession(configuration: configuration),
            rpcConfiguration: .init(trustsAlchemyURLBuilderOutput: false, urlBuilder: { _ in URL(string: "https://solana.fixture.invalid") }),
            authorizationProvider: HarnessRejectAuthorization(), timing: .init(now: fixtures.clock.now,
                sleep: { [clock = fixtures.clock] seconds in try await clock.sleep(until: clock.now().addingTimeInterval(seconds)) }))
        processor = HarnessObservedProcessor(base: DappRequestProcessor(ethereumNetworkResolver: networks.approval,
            selectionNetworkResolver: networks.network, customDefinitionResult: networks.matches, solana: solana), ipc: ipc)
        identity = AmbientRuntimeIdentity(instanceIdentifier: UUID(), processIdentifier: Int32(ProcessInfo.processInfo.processIdentifier),
            bundlePath: fixtures.helperURL.path, version: .init(marketing: "1.0.0", build: "1"), workflowVersion: ExtensionBridge.workflowVersion,
            launchedAt: AmbientRuntimeIdentity.processStartDate(processIdentifier: Int32(ProcessInfo.processInfo.processIdentifier)) ?? Date())
        fixtures.clock.observeWaits { id, deadline, active in
            ipc.event("timer", details: .object(["id": .string(id.uuidString.lowercased()),
                "deadlineMilliseconds": .number(deadline), "active": .bool(active)]))
        }
    }

    func start() async throws {
        guard await wallets.start() else { throw HarnessError.invalid("Cannot read isolated wallet fixtures") }
        let encodedIdentity = try JSONEncoder().encode(identity)
        ipc.event("ready", details: .object(["role": .string(options.role), "mode": .string(options.mode),
            "pid": .number(Double(identity.processIdentifier)), "identity": try JSONDecoder().decode(HarnessValue.self, from: encodedIdentity),
            "clockMilliseconds": .number(fixtures.clock.now().timeIntervalSince1970 * 1_000), "accounts": accountsJSON(),
            "workflowVersion": .number(Double(ExtensionBridge.workflowVersion))]))
    }

    func receive(_ envelope: HarnessValue) async {
        let id = envelope["id"]
        do {
            guard envelope["kind"].string == "command", envelope["epoch"].string == options.epoch else {
                throw HarnessError.invalid("Wrong command epoch or kind")
            }
            let key = String(decoding: try JSONEncoder().encode(id), as: UTF8.self)
            guard activeCommands.insert(key).inserted else { throw HarnessError.invalid("Duplicate active command id") }
            defer { activeCommands.remove(key) }
            let operation = try envelope.requiredString("operation")
            let result = try await command(operation, payload: envelope["payload"])
            ipc.reply(id: id, result: .success(result))
            if operation == "shutdown" { ipc.close(); Darwin.exit(0) }
        } catch { ipc.reply(id: id, result: .failure(error)) }
    }

    private lazy var executionEnvironment = makeExecutionEnvironment()

    private func makeExecutionEnvironment() -> DurableApprovalExecutor.Environment {
        DurableApprovalExecutor.Environment(
            requestProcessor: processor,
            makeBroadcastSender: { [ipc, clock = fixtures.clock] permit in
                HarnessBroadcastSender(
                    ipc: ipc,
                    identity: .object([
                        "handle": harnessHandle(permit.handle),
                        "executionID": .string(permit.executionID.uuidString.lowercased()),
                        "enqueueAttempt": .string(permit.request.enqueueAttempt),
                    ]), clock: clock)
            },
            broadcastTimeoutNanoseconds: 10_000_000_000,
            clock: fixtures.clock.now,
            waitForExecutionDeadline: { [clock = fixtures.clock] deadline in
                try? await clock.sleep(until: deadline)
            },
            waitForBroadcastTimeout: { [clock = fixtures.clock] duration in
                try? await clock.sleep(for: duration)
            }
        )
    }

    private lazy var finalizer = NativeApprovalFinalizer(store: store, executionEnvironment: executionEnvironment,
        refreshWalletCatalog: { [wallets] in guard await wallets.reloadFromStore() else { return nil }; return wallets.reviewCatalog() },
        makeSigningSession: { [wallets, clock = fixtures.clock] authorization in
            WalletSigningSession.fromSource(authorization: authorization, walletsManager: wallets, clock: clock.now)
        }, networkResolver: networks.approval, customDefinitionResult: networks.matches)

    private lazy var admission = DappRequestAdmission(store: store, requestProcessor: processor,
        reviewCatalog: options.mode == "popup" ? { [wallets] in wallets.reviewCatalog() } : nil)

    private lazy var popupSessions = PopupRequestSessions(store: store, walletEnvironment: PopupWalletEnvironment(
        reviewCatalog: { [wallets] in wallets.reviewCatalog() }, approvalCatalog: { [wallets] in wallets.reviewCatalog() },
        unlockWallets: { [weak self] _, authorization in
            guard let self else { return .canceled }
            do { try await ipc.checkpoint("authentication.before", details: .object(["handle": harnessHandle(authorization.handle)])) }
            catch { return .canceled }
            guard authenticationResult else { return .canceled }
            guard await wallets.reloadFromStore(), let catalog = wallets.reviewCatalog() else { return .unavailable }
            let source = HarnessPopupSigningSource(approvedAccount: authorization.approvedAccount, repository: wallets.repository)
            return .unlocked(catalog: catalog, session: WalletSigningSession(source: source, authorization: authorization, clock: fixtures.clock.now))
        }, reloadMetadata: {}), loadsTransactionContext: false, transactionApprovalOperations: transactionOperations,
        invalidateNetworkCache: {}, selectionNetworkResolver: { [networks] in networks.network($0) },
        approvalNetworkResolver: networks.approval, executionEnvironment: executionEnvironment,
        presentationEnvironment: .init(networks: networks.all, customNetworks: networks.all, price: { _ in nil },
            accountName: { _, account in account.address }, icon: { _ in nil }), customDefinitionResult: networks.matches)

    private lazy var launcher = makeLauncher()

    private func makeLauncher() -> NativeAgentLauncher {
        NativeAgentLauncher(dependencies: .init(helperURL: { [fixtures] in fixtures.helperURL },
        validate: { [fixtures] in $0.standardizedFileURL == fixtures.helperURL.standardizedFileURL },
        helpers: { [weak self] in self?.runtimeHelper().map { [$0] } ?? [] },
        helper: { [weak self] pid in guard let helper = self?.runtimeHelper(), helper.processIdentifier == pid else { return nil }; return helper },
        identity: { [weak self] pid in self?.registeredRuntime.flatMap { $0.processIdentifier == pid ? $0 : nil } },
        launch: { [weak self] target, route in
            guard let self else { return false }
            do {
                let response = try await ipc.request("launch", details: .object(["url": .string(route.absoluteString),
                    "target": .string(target.url.path)]))
                if case .object = response["identity"] { registeredRuntime = try decodeIdentity(response["identity"]) }
                return response["success"].bool == true
            } catch { return false }
        }, uptime: fixtures.clock.uptime, sleepUntil: { [clock = fixtures.clock] deadline in
            try? await clock.sleep(until: deadline)
        }))
    }

    private lazy var nativeService = makeNativeService()

    private func makeNativeService() -> NativeApprovalService {
        NativeApprovalService(dependencies: .init(launcher: launcher,
        load: { [bridge] in await bridge.load(handle: $0) },
        responseStatus: { [bridge] in await bridge.responseStatus(handle: $0, configurationKey: $1) },
        maintainProfile: { [bridge] in await bridge.performMaintenance(profileIdentifier: $0) },
        clearReceipt: { [bridge] handle, receipt in
            await bridge.clearNativeDeliveryReceipt(handle: handle, nativeDeliveryNonce: receipt.nativeDeliveryNonce,
                runtimeInstanceIdentifier: receipt.owner.runtimeInstanceIdentifier)
        }, uptime: fixtures.clock.uptime, sleepUntil: { [clock = fixtures.clock] deadline in
            try? await clock.sleep(until: deadline)
        }), launchTimeoutNanoseconds: 5_000_000_000)
    }

    private lazy var poller = ResponseDeliveryPoller(
        responseStatus: { [bridge] in await bridge.responseStatus(handle: $0, configurationKey: $1) },
        maintain: { [weak self] handle, key, maintenance in
            guard let self else { return .unavailable }
            if options.mode == "native" {
                let result = await nativeService.reconcile(.init(handle: handle, configurationKey: key),
                    intent: .maintenance(allowDelivery: maintenance == .interactive))
                switch result {
                case .opened, .pending: return .pending
                case .responseReady: return .ready
                case .missing: return .missing
                case .unavailable: return .unavailable
                }
            }
            await bridge.performMaintenance(profileIdentifier: handle.profileIdentifier)
            return await bridge.responseStatus(handle: handle, configurationKey: key)
        }, prepareDelivery: { [store] in await store.prepareDelivery(handle: $0, configurationKey: $1) })

    private lazy var dispatcher = NativeMessageDispatcher(policy: options.mode == "native" ? .native : .popup,
        dependencies: .init(bridge: store, materialize: { [weak self] handle in
            guard let self else { return .unavailable }
            return await admission.materialize(handle: handle)
        }, reconcile: { [weak self] reference, intent in
            guard let self else { return .unavailable }
            let result = await nativeService.reconcile(.init(handle: reference.handle, configurationKey: reference.configurationKey,
                expectedNonce: reference.expectedNonce), intent: intent == .admission ? .admission : .focus)
            switch result {
            case .pending: return .pending
            case .responseReady: return .responseReady
            case .opened: return .opened
            case .missing: return .missing
            case .unavailable: return .unavailable
            }
        }, pollResponse: { [weak self] handle, key, maintenance in
            guard let self else { return .unavailable }
            return await poller.poll(handle: handle, configurationKey: key, maintenance: maintenance)
        }, rpcNetwork: networks.resolved, sendRPC: { [ipc] endpoint, body, _ in
            let request = try JSONDecoder().decode(HarnessValue.self, from: body)
            let response = try await ipc.request("rpc", details: .object(["request": request, "endpoint": .string(endpoint.url.absoluteString)]))
            guard let object = WireProtocol.JSONObject(response.foundation) else { throw HarnessError.invalid("Invalid fixture RPC reply") }
            return object
        }, popup: { [weak self] request, profile in
            guard let self else { return .command(.init(status: .unavailable, approvalState: nil)) }
            return await popupSessions.dispatch(request: request, profileIdentifier: profile)
        }, privatePopup: { [weak self] request in
            guard let self else { return .command(.init(status: .unavailable, approvalState: nil)) }
            return await popupSessions.privateBrowsingResponse(for: request)
        }, openApp: { [weak self] in
            guard let self else { return false }
            return await nativeService.openWallet()
        }, invalidateNetworkCache: {}))

    private func runtimeHelper() -> NativeAgentLauncher.RuntimeHelper? {
        guard let runtime = registeredRuntime,
              let start = AmbientRuntimeIdentity.processStartDate(processIdentifier: runtime.processIdentifier),
              runtime.matches(processIdentifier: runtime.processIdentifier, bundleURL: runtime.bundleURL, processStartDate: start) else { return nil }
        return .init(processIdentifier: runtime.processIdentifier, bundleURL: runtime.bundleURL, processStartDate: runtime.launchedAt,
            isRunning: {
                guard let current = AmbientRuntimeIdentity.processStartDate(processIdentifier: runtime.processIdentifier) else { return false }
                return runtime.matches(processIdentifier: runtime.processIdentifier, bundleURL: runtime.bundleURL, processStartDate: current)
            }, requestQuit: { false })
    }

    private func decodeIdentity(_ value: HarnessValue) throws -> AmbientRuntimeIdentity {
        let identity = try JSONDecoder().decode(AmbientRuntimeIdentity.self, from: JSONEncoder().encode(value))
        guard identity.bundleURL == fixtures.helperURL.standardizedFileURL else { throw HarnessError.invalid("Unrelated runtime identity") }
        return identity
    }

    private func command(_ operation: String, payload: HarnessValue) async throws -> HarnessValue {
        switch operation {
        case "native":
            guard let input = WireProtocol.JSONObject(payload["message"].foundation) else { throw HarnessError.invalid("Invalid native message") }
            var json = input.json
            guard case .value(let privateBrowsing) = ExtensionBridge.takePrivateBrowsing(from: &json),
                  payload["privateBrowsing"].bool == nil || payload["privateBrowsing"].bool == privateBrowsing,
                  let message = WireProtocol.JSONObject(json) else { throw HarnessError.invalid("Invalid private-browsing metadata") }
            if let key = payload["message"]["configurationKey"].string { configurationKeys.insert(key) }
            let reply = try await dispatcher.dispatch(message: message,
                profileIdentifier: payload["profileIdentifier"].string.flatMap(UUID.init(uuidString:)), privateBrowsing: privateBrowsing)
            return try HarnessValue.convert(reply.json)
        case "inspect": return try await inspect(profile: payload["profileIdentifier"].string.flatMap(UUID.init(uuidString:)))
        case "route":
            guard let url = URL(string: try payload.requiredString("url")), let route = NativeAgentRoute(url: url) else { throw HarnessError.invalid("Invalid native route") }
            try startRoute(route)
            return .object(["accepted": .bool(true)])
        case "decide": return try await decide(payload)
        case "checkpoints": try ipc.configure(payload); return .object(["configured": .bool(true)])
        case "clock":
            try fixtures.clock.set(milliseconds: payload["nowMilliseconds"].number ?? fixtures.clock.now().timeIntervalSince1970 * 1_000 + (payload["advanceMilliseconds"].number ?? 0))
            return .object(["clockMilliseconds": .number(fixtures.clock.now().timeIntervalSince1970 * 1_000)])
        case "runtime":
            registeredRuntime = payload["identity"].object.isEmpty ? nil : try decodeIdentity(payload["identity"])
            return .object(["registered": .bool(registeredRuntime != nil)])
        case "wallet": return try await HarnessOperation.$name.withValue("walletMutation") { try await mutateWallet(payload) }
        case "network": try networks.change(payload); return .object(["changed": .bool(true)])
        case "authenticate": authenticationResult = payload["success"].bool ?? false; return .object(["configured": .bool(true)])
        case "maintain":
            await bridge.performMaintenance(profileIdentifier: payload["profileIdentifier"].string.flatMap(UUID.init(uuidString:)))
            return .object(["maintained": .bool(true)])
        case "claim":
            let handle = try harnessDecodeHandle(payload["handle"])
            let label = payload["label"].string ?? "held"
            switch await store.claim(handle: handle) {
            case .claimed(let claim): heldClaims[label] = claim; return .string("claimed")
            case .executing: return .string("executing")
            case .responded: return .string("responded")
            case .missing: return .string("missing")
            case .unavailable: return .string("unavailable")
            }
        case "releaseClaim":
            heldClaims.removeValue(forKey: payload["label"].string ?? "held")?.releaseUnapproved()
            return .object(["released": .bool(true)])
        case "shutdown": return .object(["stopped": .bool(true)])
        default: throw HarnessError.invalid("Unknown harness operation: \(operation)")
        }
    }

    private func startRoute(_ route: NativeAgentRoute) throws {
        guard options.role == "approval" else { throw HarnessError.invalid("Routes require approval worker") }
        guard case .approval(_, let handle, let nonce) = route else { return }
        if let existing = coordinators[handle], existing.nativeDeliveryNonce == nonce {
            if existing.isPaused && !existing.requiresExplicitReviewRetry {
                existing.retryRecovery()
            }
            return
        }
        guard let owner = identity.nativeDeliveryOwner else { throw HarnessError.invalid("Invalid fixture delivery owner") }
        let clock = fixtures.clock
        let coordinator = NativeApprovalCoordinator(handle: handle, nativeDeliveryNonce: nonce, store: store,
            environment: .init(now: clock.now, uptime: { Double(clock.uptime()) / 1_000_000_000 },
                wait: { duration in try? await clock.sleep(for: duration) },
                waitForAuthenticationExpiry: { seconds in try await clock.sleep(until: clock.now().addingTimeInterval(seconds)) },
                prepare: { [processor] binding, catalog in processor.prepare(binding, catalog: catalog) },
                reloadWallets: { [wallets] in await wallets.reloadFromStore() },
                currentReviewCatalog: { [wallets] in wallets.reviewCatalog() },
                attemptNativeDecision: { [weak self] consent in
                    guard let self else { return .interruptionRequired }
                    let label = consentLabels[handle] ?? UUID().uuidString.lowercased()
                    savedConsents[label] = consent
                    ipc.event("consent", details: .object(["label": .string(label), "handle": harnessHandle(handle),
                        "revision": .number(Double(reviewedRevisions[handle] ?? 0)),
                        "reviewedRevision": .number(Double(reviewedRevisions[handle] ?? 0))]))
                    return await HarnessOperation.$identity.withValue(harnessHandle(handle)) { await finalizer.attempt(consent: consent) }
                }))
        coordinators[handle] = coordinator
        coordinator.onEvent = { [weak self, weak coordinator] event in
            guard let self, let coordinator else { return }
            if case .authenticationRequired = event {
                Task { [weak self, weak coordinator, ipc] in
                    let accepted: Bool
                    do {
                        try await ipc.checkpoint("authentication.before", details: .object(["handle": harnessHandle(handle)]))
                        accepted = true
                    } catch { accepted = false }
                    guard let self, let coordinator, coordinator.isAwaitingAuthentication else { return }
                    if accepted, authenticationResult { coordinator.resumeAfterAuthentication() }
                    else { coordinator.cancelBeforeAuthentication() }
                }
            }
            ipc.event("presentation", details: coordinatorJSON(coordinator))
        }
        coordinator.start(nativeDeliveryOwner: owner)
    }

    private func decide(_ payload: HarnessValue) async throws -> HarnessValue {
        if let label = payload["useSaved"].string {
            guard let consent = savedConsents[label] else { throw HarnessError.invalid("Unknown process-local consent label") }
            return .object(["replayed": .string(label), "result": .string(String(describing: await finalizer.attempt(consent: consent)))])
        }
        let handle = try harnessDecodeHandle(payload["handle"])
        guard let coordinator = coordinators[handle] else { return .object(["accepted": .bool(false), "reason": .string("missing")]) }
        if let revision = payload["revision"].int, UInt64(exactly: revision) != coordinator.currentPresentation?.revision {
            return .object(["accepted": .bool(false), "reason": .string("staleReview")])
        }
        let decision = payload["decision"].string ?? "approve"
        if decision == "reject" { coordinator.reject(); return .object(["accepted": .bool(true)]) }
        if decision == "retry" { coordinator.retryRecovery(); return .object(["accepted": .bool(true)]) }
        guard decision == "approve", case .approval(_, let action) = coordinator.currentPresentation?.presentation else {
            return .object(["accepted": .bool(false), "reason": .string("notReviewing")])
        }
        consentLabels[handle] = payload["saveAs"].string ?? UUID().uuidString.lowercased()
        reviewedRevisions[handle] = coordinator.currentPresentation?.revision
        switch action {
        case .selectAccount(let selection), .switchAccount(let selection):
            guard case .array(let choices) = payload["selectedAccounts"] else {
                throw HarnessError.invalid("Missing explicit selected accounts")
            }
            let candidates = wallets.wallets.flatMap { wallet in wallet.accounts.map { SpecificWalletAccount(walletId: wallet.id, account: $0) } }
            var coins = Set<WalletCoin>()
            let selected = try choices.map { choice -> SpecificWalletAccount in
                let walletId = try choice.requiredString("walletId")
                let coin = try choice.requiredString("coin")
                let address = try choice.requiredString("address")
                let path = try choice.requiredString("derivationPath")
                guard let candidate = candidates.first(where: {
                    $0.walletId == walletId && $0.account.coin.correspondingInpageProvider.rawValue == coin &&
                        $0.account.coin.normalizedAddress($0.account.address) == $0.account.coin.normalizedAddress(address) &&
                        $0.account.derivationPath == path
                }), (selection.coinType == nil || selection.coinType == candidate.account.coin),
                    coins.insert(candidate.account.coin).inserted else {
                    throw HarnessError.invalid("Selected account is absent or duplicated in this review")
                }
                return candidate
            }
            coordinator.approveAccounts(selected, ethereumNetwork: networks.resolved(payload["chainId"].int ?? 1)?.network)
        case .approveMessage(let action):
            coordinator.approveMessage(solanaCluster: action.solanaClusterOptions == nil ? nil : .devnet)
        case .approveTransaction(let action):
            coordinator.approveTransaction(Self.preparedTransaction(action.transaction), reviewedNetwork: action.resolvedNetwork)
        case .addEthereumChain: coordinator.approveAddEthereumChain()
        }
        return .object(["accepted": .bool(true), "label": .string(consentLabels[handle]!)])
    }

    private func mutateWallet(_ payload: HarnessValue) async throws -> HarnessValue {
        let id = try payload.requiredString("walletID")
        guard await wallets.reloadFromStore() else { throw HarnessError.invalid("Cannot load fixture wallets") }
        let action = try payload.requiredString("action")
        if action == "restore" {
            try fileStore.perform(preparing: { PreparedWalletSourceMutation(payload: (), authorityRemovals: []) }, beforeCommit: {}) { _ in
                try fixtures.restore(walletID: id)
            }
        } else {
            guard let wallet = wallets.currentWallet(id: id) else {
                return .object(["changed": .bool(false), "reason": .string("missingWallet"), "accounts": accountsJSON()])
            }
            if action == "removeWallet" { try await wallets.delete(wallet: wallet) }
            else if action == "removeAccount" {
                guard wallet.accounts.count > 1 else {
                    return .object(["changed": .bool(false), "reason": .string("lastAccountRequiresWalletRemoval"), "accounts": accountsJSON()])
                }
                guard let account = wallet.accounts.first(where: { account in
                    (payload["coin"].string == nil || payload["coin"].string == account.coin.correspondingInpageProvider.rawValue) &&
                        (payload["address"].string == nil || payload["address"].string == account.address)
                }) else { return .object(["changed": .bool(false), "reason": .string("missingAccount"), "accounts": accountsJSON()]) }
                try await wallets.update(wallet: wallet, removeAccounts: [account])
            } else { throw HarnessError.invalid("Unknown wallet action") }
        }
        await wallets.reloadFromStore()
        return .object(["changed": .bool(true), "accounts": accountsJSON()])
    }

    private func inspect(profile: UUID?) async throws -> HarnessValue {
        await wallets.reloadFromStore()
        let snapshots: [ExtensionBridge.Snapshot]
        switch await bridge.list(profileIdentifier: profile) {
        case .available(let values): snapshots = values.values.sorted { $0.sequence < $1.sequence }
        case .unavailable: throw HarnessError.invalid("Store unavailable")
        }
        var configurations = [HarnessValue]()
        for key in configurationKeys.sorted() {
            if case .snapshot(let state) = await bridge.configurationSnapshot(configurationKey: key, profileIdentifier: profile) {
                configurations.append(.object(["configurationKey": .string(key), "state": try HarnessValue.convert(state.json)]))
            }
        }
        let facts = durableFacts(profile: profile)
        var requests = snapshots.map { snapshot -> HarnessValue in
            var object: [String: HarnessValue] = ["handle": harnessHandle(snapshot.handle), "id": .number(Double(snapshot.handle.id)),
                "name": snapshot.request.map { .string($0.name) } ?? .null,
                "provider": snapshot.request.map { .string($0.provider.rawValue) } ?? .null,
                "enqueueAttempt": .string(snapshot.enqueueAttempt),
                "configurationKey": .string(snapshot.configurationKey), "phase": .string(snapshot.phase.rawValue),
                "nativeDeliveryNonce": .string(snapshot.nativeDeliveryNonce.value.uuidString.lowercased())]
            if let fact = facts?[snapshot.handle] { object.merge(fact.object) { _, new in new } }
            if let coordinator = coordinators[snapshot.handle] { object.merge(coordinatorJSON(coordinator).object) { _, new in new } }
            return .object(object)
        }
        let visibleHandles = Set(snapshots.map(\.handle))
        for handle in (facts?.keys.filter { !visibleHandles.contains($0) } ?? []).sorted(by: {
            $0.id == $1.id ? $0.requestToken < $1.requestToken : $0.id < $1.id
        }) {
            if let fact = facts?[handle] { requests.append(fact) }
        }
        return .object(["clockMilliseconds": .number(fixtures.clock.now().timeIntervalSince1970 * 1_000),
            "pendingSleeps": .number(Double(fixtures.clock.pendingSleeps)),
            "durableObservationAvailable": .bool(facts != nil),
            "accounts": accountsJSON(), "requests": .array(requests), "configurations": .array(configurations)])
    }

    private func durableFacts(profile: UUID?) -> [ExtensionBridge.Handle: HarnessValue]? {
        let files = ExtensionRequestStoreFiles(rootURL: fixtures.root.appendingPathComponent("bridge", isDirectory: true),
            directoryBoundary: fixtures.root, dependencies: .init(clock: fixtures.clock.now, completeChainAddition: { _ in false }))
        return files.withExistingStoreLock(unavailable: nil, missing: [:]) {
            let data: Data
            switch files.readProfileDataLocked(at: files.profileURL(profile)) {
            case .missing: return [:]
            case .data(let value): data = value
            case .corrupt, .unavailable: return nil
            }
            var codec = ExtensionRequestProfileCodec()
            guard let decoded = codec.decodeProfile(data, expectedIdentifier: profile, recoverAuthority: false, now: fixtures.clock.now()) else { return nil }
            return Dictionary(uniqueKeysWithValues: decoded.profile.state.records.map { record in
                var committed = false
                var terminal = false
                var transactionID: String?
                switch record.state {
                case .broadcastPrepared: committed = true
                case .completed: terminal = true
                case .pending, .claimed: break
                }
                let responseJSON = record.state.responseData.flatMap { ExtensionRequestProfileCodec.responseJSON($0, id: record.id) }
                let response = responseJSON.flatMap(ResponseToExtension.init(json:))
                if let responseJSON, let response = ResponseToExtension(json: responseJSON),
                   (response.provider == .ethereum && response.name == "signTransaction") ||
                    (response.provider == .solana && response.name == "signAndSendTransaction") {
                    switch response.payload {
                    case .result(.string(let value)): transactionID = value; committed = true
                    case .error(let error):
                        switch error.context {
                        case .transactionHash(let value), .transactionSignature(let value): transactionID = value; committed = true
                        default: break
                        }
                        if let errorObject = responseJSON["error"] as? [String: Any],
                           let context = errorObject["data"] as? [String: Any],
                           let value = context[response.provider == .ethereum ? "transactionHash" : "signature"] as? String {
                            transactionID = value
                            committed = true
                        }
                    default: break
                    }
                }
                let phase: String
                switch record.state {
                case .pending: phase = "queued"
                case .claimed, .broadcastPrepared: phase = "approving"
                case .completed: phase = "responded"
                }
                let requestName = record.state.request?.name ?? response?.name
                let requestProvider = requestName == "switchAccount" ? InpageProvider.unknown : (record.state.request?.provider ?? response?.provider)
                var object: [String: HarnessValue] = ["handle": harnessHandle(record.handle), "id": .number(Double(record.id)),
                    "configurationKey": .string(record.configurationKey), "host": .string(record.host),
                    "enqueueAttempt": .string(record.enqueueAttempt), "phase": .string(phase),
                    "name": requestName.map(HarnessValue.string) ?? .null,
                    "provider": requestProvider.map { .string($0.rawValue) } ?? .null,
                    "nativeDeliveryNonce": .string(record.nativeDeliveryNonce.rawValue),
                    "broadcastCheckpointed": .bool(committed),
                    "requestFingerprint": .string(WalletCrypto.hexString(data: record.requestFingerprint)),
                    "terminal": .bool(terminal), "transactionID": transactionID.map(HarnessValue.string) ?? .null]
                if let responseJSON, let response = try? HarnessValue.convert(responseJSON) {
                    object[terminal ? "terminalResponse" : "recoveryResponse"] = response
                }
                if let request = record.state.request?.wireObject(for: record), let request = try? HarnessValue.convert(request) {
                    object["request"] = request
                }
                return (record.handle, .object(object))
            })
        }
    }

    private func coordinatorJSON(_ coordinator: NativeApprovalCoordinator) -> HarnessValue {
        let presentation: String
        switch coordinator.currentPresentation?.presentation {
        case .approval: presentation = "review"
        case .waiting: presentation = "waiting"
        case .retryRequired: presentation = "retryRequired"
        case .rejecting: presentation = "rejecting"
        case .interrupted: presentation = "interrupted"
        case .finished: presentation = "finished"
        case .superseded: presentation = "superseded"
        case nil: presentation = "none"
        }
        return .object(["handle": harnessHandle(coordinator.handle), "revision": .number(Double(coordinator.currentPresentation?.revision ?? 0)),
            "presentation": .string(presentation), "coordinatorPhase": .string(String(describing: coordinator.phase))])
    }

    private func accountsJSON() -> HarnessValue {
        .array(wallets.wallets.flatMap { wallet in wallet.accounts.map { account in
            .object(["walletID": .string(wallet.id), "coin": .string(account.coin.correspondingInpageProvider.rawValue),
                "address": .string(account.address), "path": .string(account.derivationPath)])
        } })
    }

    private static func preparedTransaction(_ transaction: Transaction) -> Transaction {
        var prepared = transaction
        prepared.nonce = prepared.nonce ?? "0x0"
        prepared.gas = prepared.gas ?? "0x5208"
        if prepared.preparedFee == nil {
            let requested = prepared.feeIntent.preparedFee
            let fee = requested ?? .legacy(gasPrice: 10)
            prepared.replacePreparedFee(fee, provenance: .init(source: requested == nil ? .automatic : .dapp, for: fee))
        }
        return prepared
    }

    private var transactionOperations: TransactionApprovalOperations {
        .init(prepare: { transaction, _, network in
            AsyncThrowingStream { continuation in
                continuation.yield(.feeEstimate(.init(info: nil, nextBaseFee: nil, support: .legacy, gasPrice: 10,
                    endpointChainID: BigUInt(UInt64(network.chainId)))))
                let prepared = Self.preparedTransaction(transaction)
                continuation.yield(.transactionUpdated(prepared))
                continuation.yield(.ready(prepared))
                continuation.finish()
            }
        }, preflight: { transaction, network in
            .safe(Self.preparedTransaction(transaction), .init(info: nil, nextBaseFee: nil, support: .legacy,
                gasPrice: 10, endpointChainID: BigUInt(UInt64(network.chainId))))
        })
    }
}
