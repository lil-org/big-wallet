// ∅ 2026 lil org

import Foundation
actor NativeAgentLauncher {
    enum ApprovalDeliveryResult: Equatable {
        case pending, responseReady, unavailable
    }

    private enum ReceiptStatus: Sendable {
        case delivered, responseReady, needsDelivery, terminal, unavailable
    }

    private enum ReceiptPolicy {
        case delivery, pageRead, manualRecovery
    }

    enum HelperTarget: Equatable, Sendable {
        case running(
            url: URL,
            processIdentifier: Int32,
            runtimeInstanceIdentifier: UUID
        )
        case launch(url: URL)

        var url: URL {
            switch self {
            case .running(let url, _, _), .launch(let url):
                return url
            }
        }
    }

    typealias Launch = @MainActor (
        HelperTarget,
        URL,
        @escaping (Bool) -> Void
    ) -> Void
    struct RuntimeHelper {
        let processIdentifier: Int32
        let bundleURL: URL?
        let processStartDate: Date?
        let isRunning: () -> Bool
        let requestQuit: () -> Bool

        init(
            processIdentifier: Int32,
            bundleURL: URL?,
            processStartDate: Date? = nil,
            isRunning: @escaping () -> Bool = { false },
            requestQuit: @escaping () -> Bool = { false }
        ) {
            self.processIdentifier = processIdentifier
            self.bundleURL = bundleURL
            self.processStartDate = processStartDate
            self.isRunning = isRunning
            self.requestQuit = requestQuit
        }
    }

    private struct ExpectedRuntime {
        let url: URL
        let version: AmbientRuntimeIdentity.Version

        init(url: URL, version: AmbientRuntimeIdentity.Version) {
            self.url = url.standardizedFileURL
            self.version = version
        }

        init?(url: URL) {
            let url = url.standardizedFileURL
            guard let version = AmbientRuntimeIdentity.bundleVersion(
                at: url
            ) else { return nil }
            self.init(url: url, version: version)
        }

        func isCompatible(
            _ identity: AmbientRuntimeIdentity,
            runtimeURL: URL?
        ) -> Bool {
            runtimeURL?.standardizedFileURL == url && identity.isCompatible(
                withWorkflowVersion: ExtensionBridge.workflowVersion,
                expectedVersion: version
            )
        }

        var installedVersionMatches: Bool {
            AmbientRuntimeIdentity.bundleVersion(at: url) == version
        }
    }

    private enum RuntimeSubject {
        case candidate(RuntimeHelper)
        case receiptOwner(ExtensionBridge.NativeDeliveryOwner)
    }

    struct IdentifiedRuntime {
        let helper: RuntimeHelper
        let identity: AmbientRuntimeIdentity

        var target: HelperTarget {
            .running(
                url: URL(fileURLWithPath: identity.bundlePath).standardizedFileURL,
                processIdentifier: helper.processIdentifier,
                runtimeInstanceIdentifier: identity.instanceIdentifier
            )
        }
    }

    enum RuntimeAssessment {
        case absent
        case unidentified(RuntimeHelper?)
        case compatible(IdentifiedRuntime)
        case incompatible(IdentifiedRuntime)
    }

    private struct RuntimeProcessKey: Hashable {
        let processIdentifier: Int32
        let processStartDate: Date?

        init(_ helper: RuntimeHelper) {
            processIdentifier = helper.processIdentifier
            processStartDate = helper.processStartDate
        }
    }

    struct Dependencies {
        let helperURL: () -> URL?
        let validate: (URL) async -> Bool
        let helpers: @MainActor () -> [RuntimeHelper]
        let helper: @MainActor (Int32) -> RuntimeHelper?
        let identity: (Int32) -> AmbientRuntimeIdentity?
        let launch: Launch
        let load: (ExtensionBridge.Handle) async -> ExtensionBridge.SnapshotResult
        let loadManualSwitch: (
            ExtensionBridge.Handle, String
        ) async -> ExtensionBridge.SnapshotResult
        let beginExecutionRead: (
            ExtensionBridge.Handle, String, ExtensionBridge.ProviderRevisions, Date
        ) async -> ExtensionBridge.NativeExecutionReadResult
        let readResponse: (
            ExtensionBridge.Handle, String
        ) async -> ExtensionBridge.ResponseReadResult
        let clearReceipt: (
            ExtensionBridge.Handle,
            ExtensionBridge.NativeDeliveryReceipt
        ) async -> ExtensionBridge.StoreMutationResult
        let uptime: () -> UInt64
        let wallClock: () -> Date
        let sleepUntil: (UInt64) async -> Void

        static var live: Self {
            Self(
                helperURL: NativeAgentRuntime.embeddedHelperURL,
                validate: NativeAgentRuntime.validateEmbeddedHelper,
                helpers: {
#if os(macOS)
                    NativeAgentRuntime.runningHelpers()
#else
                    []
#endif
                },
                helper: { identifier in
#if os(macOS)
                    NativeAgentRuntime.runningHelper(processIdentifier: identifier)
#else
                    nil
#endif
                },
                identity: { AmbientRuntimeIdentity.load(processIdentifier: $0) },
                launch: NativeAgentRuntime.launchApplication,
                load: { await ExtensionBridge.shared.load(handle: $0) },
                loadManualSwitch: {
                    await ExtensionBridge.shared.loadManualSwitch(handle: $0, configurationKey: $1)
                },
                beginExecutionRead: {
                    await ExtensionBridge.shared.beginNativeExecutionRead(
                        handle: $0, configurationKey: $1, revisions: $2, executionDeadline: $3
                    )
                },
                readResponse: {
                    await ExtensionBridge.shared.readResponse(
                        id: $0.id, configurationKey: $1,
                        requestToken: $0.requestToken, profileIdentifier: $0.profileIdentifier
                    )
                },
                clearReceipt: { handle, receipt in
                    await ExtensionBridge.shared.clearNativeDeliveryReceipt(
                        handle: handle,
                        nativeDeliveryNonce: receipt.nativeDeliveryNonce,
                        runtimeInstanceIdentifier: receipt.owner.runtimeInstanceIdentifier
                    )
                },
                uptime: { DispatchTime.now().uptimeNanoseconds },
                wallClock: Date.init,
                sleepUntil: { deadline in
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard deadline > now else { return }
                    try? await Task.sleep(nanoseconds: deadline - now)
                }
            )
        }

        func deadline(after interval: UInt64) -> UInt64 {
            let result = uptime().addingReportingOverflow(interval)
            return result.overflow ? UInt64.max : result.partialValue
        }

        func wait(_ interval: UInt64) async {
            await sleepUntil(deadline(after: interval))
        }

        @MainActor
        func receiptRuntimeStatus(
            _ receipt: ExtensionBridge.NativeDeliveryReceipt
        ) async -> RuntimeAssessment {
#if os(macOS)
            guard let url = helperURL(), let expected = ExpectedRuntime(url: url) else {
                return .unidentified(nil)
            }
            return await NativeAgentLauncher.runtimeStatus(
                receipt: receipt,
                expected: expected,
                helper: helper,
                identity: identity,
                validate: validate
            )
#else
            return .unidentified(nil)
#endif
        }
    }

    private struct SharedDelivery {
        let identifier: UUID
        let route: NativeAgentRoute
        let deadline: UInt64
        let task: Task<Bool, Never>
    }

    private enum ReceiptObservation {
        case owned(ExtensionBridge.Snapshot, ExtensionBridge.NativeDeliveryReceipt)
        case unowned, completed, terminal, unavailable
    }

    @MainActor
    private static func observeReceipt(
        handle: ExtensionBridge.Handle,
        nonce: ExtensionBridge.NativeDeliveryNonce,
        isPending: () -> Bool,
        dependencies: Dependencies
    ) async -> ReceiptObservation {
        guard !Task.isCancelled, isPending() else { return .unavailable }
        let loaded = await dependencies.load(handle)
        guard !Task.isCancelled, isPending() else { return .unavailable }
        switch loaded {
        case .found(let snapshot):
            guard snapshot.nativeDeliveryNonce == nonce else { return .terminal }
            if snapshot.phase == .responded { return .completed }
            guard let receipt = snapshot.nativeDeliveryReceipt else { return .unowned }
            guard receipt.nativeDeliveryNonce == nonce else { return .terminal }
            return .owned(snapshot, receipt)
        case .missing:
            return .terminal
        case .unavailable:
            return .unavailable
        }
    }

    @MainActor
    private static func reconcileReceipt(
        handle: ExtensionBridge.Handle,
        nonce: ExtensionBridge.NativeDeliveryNonce,
        policy: ReceiptPolicy = .delivery,
        isPending: @escaping () -> Bool,
        dependencies: Dependencies
    ) async -> ReceiptStatus {
        while !Task.isCancelled, isPending() {
            let receipt: ExtensionBridge.NativeDeliveryReceipt
            switch await observeReceipt(
                handle: handle, nonce: nonce, isPending: isPending, dependencies: dependencies
            ) {
            case .owned(let snapshot, let current):
                if policy == .manualRecovery && !snapshot.hasStagedOrActiveExecution {
                    return .unavailable
                }
                if policy == .pageRead,
                   case .queued(_, .delivered) = snapshot.state,
                   let url = dependencies.helperURL(), let expected = ExpectedRuntime(url: url),
                   case .compatible = assessRuntime(
                       .receiptOwner(current.owner), expected: expected,
                       helper: dependencies.helper, identity: dependencies.identity
                   ), expected.installedVersionMatches, isPending() {
                    return .delivered
                }
                receipt = current
            case .completed: return .responseReady
            case .unowned: return .needsDelivery
            case .terminal: return .terminal
            case .unavailable: return .unavailable
            }
            let status = await dependencies.receiptRuntimeStatus(receipt)
            guard !Task.isCancelled, isPending() else { return .unavailable }
            switch status {
            case .compatible:
                return .delivered
            case .incompatible(let runtime):
                guard policy != .manualRecovery else { return .unavailable }
                guard let url = dependencies.helperURL(), let expected = ExpectedRuntime(url: url),
                      await verifyRuntime(runtime, expected: expected,
                                          identity: dependencies.identity, validate: dependencies.validate),
                      !Task.isCancelled, isPending() else { return .unavailable }
                switch await observeReceipt(
                    handle: handle, nonce: nonce, isPending: isPending, dependencies: dependencies
                ) {
                case .owned(_, let current):
                    guard current == receipt else { continue }
                case .completed: return .responseReady
                case .unowned: continue
                case .terminal: return .terminal
                case .unavailable: return .unavailable
                }
                guard expected.installedVersionMatches else { return .unavailable }
                switch assessRuntime(
                    .receiptOwner(receipt.owner), expected: expected,
                    helper: dependencies.helper, identity: dependencies.identity
                ) {
                case .absent:
                    break
                case .incompatible(let current) where current.identity == runtime.identity:
                    guard current.helper.requestQuit() else { return .unavailable }
                    while current.helper.isRunning(), !Task.isCancelled, isPending() {
                        await dependencies.wait(NativeApprovalTiming.launchPollIntervalNanoseconds)
                    }
                case .compatible:
                    continue
                case .incompatible, .unidentified:
                    return .unavailable
                }
            case .absent:
                break
            case .unidentified:
                return .unavailable
            }
            guard !Task.isCancelled, isPending() else { return .unavailable }
            let cleared = await dependencies.clearReceipt(handle, receipt)
            guard !Task.isCancelled, isPending() else { return .unavailable }
            switch cleared {
            case .persisted:
                switch await observeReceipt(
                    handle: handle, nonce: nonce, isPending: isPending, dependencies: dependencies
                ) {
                case .owned:
                    guard policy != .manualRecovery else { return .unavailable }
                    continue
                case .completed: return .responseReady
                case .unowned:
                    return policy == .manualRecovery ? .unavailable : .needsDelivery
                case .terminal: return .terminal
                case .unavailable: return .unavailable
                }
            case .ownershipLost:
                guard policy != .manualRecovery else { return .unavailable }
                continue
            case .retryablePersistenceFailure:
                return .unavailable
            }
        }
        return .unavailable
    }

    @MainActor
    private static func runtimeIsConfirmed(
        expected: ExpectedRuntime,
        isPending: () -> Bool,
        dependencies: Dependencies
    ) async -> Bool {
#if os(macOS)
        for helper in dependencies.helpers() {
            if await isConfirmedRuntimeHelper(
                helper,
                expected: expected,
                identity: dependencies.identity,
                validate: dependencies.validate
            ) {
                return !Task.isCancelled && isPending()
            }
        }
#endif
        return false
    }

    private actor LaunchResolution<Value: Sendable> {
        private var result: Value?
        private var continuation: CheckedContinuation<Value, Never>?

        func value() async -> Value {
            if let result { return result }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func finish(_ succeeded: Value) {
            guard result == nil else { return }
            result = succeeded
            continuation?.resume(returning: succeeded)
            self.continuation = nil
        }
    }

    static let live = NativeAgentLauncher(dependencies: .live)

    private let dependencies: Dependencies
    private let launchTimeoutNanoseconds: UInt64
    private var sharedDeliveries = [SharedDelivery]()
    private var deliveryTail: Task<Bool, Never>?
    private var deliveryTailIdentifier: UUID?

    init(
        dependencies: Dependencies,
        launchTimeoutNanoseconds: UInt64 = NativeApprovalTiming.launchTimeoutNanoseconds
    ) {
        self.dependencies = dependencies
        self.launchTimeoutNanoseconds = launchTimeoutNanoseconds
    }

    func open(
        _ route: NativeAgentRoute,
        waitDeadline: UInt64? = nil
    ) async -> Bool {
        let deliveryDeadline = dependencies.deadline(after: launchTimeoutNanoseconds)
        let callerDeadline = min(
            deliveryDeadline,
            waitDeadline ?? UInt64.max
        )
        guard dependencies.uptime() < callerDeadline else { return false }
        if let shared = sharedDeliveries.first(where: {
            $0.route == route && dependencies.uptime() < $0.deadline
        }) {
            return await result(of: shared, callerDeadline: callerDeadline)
        }
        let identifier = UUID()
        let precedingDelivery = deliveryTail
        let operation = Task { [weak self] in
            _ = await precedingDelivery?.value
            guard let self else { return false }
            return await self.deliver(route, deadline: deliveryDeadline)
        }
        let task = Task { [weak self] in
            guard let self else { operation.cancel(); return false }
            let result = await self.boundedResult(of: operation, deadline: deliveryDeadline, timeoutValue: false)
            await self.finishSharedDelivery(identifier: identifier)
            return result
        }
        let shared = SharedDelivery(
            identifier: identifier,
            route: route,
            deadline: deliveryDeadline,
            task: task
        )
        sharedDeliveries.append(shared)
        deliveryTail = task
        deliveryTailIdentifier = identifier
        return await result(of: shared, callerDeadline: callerDeadline)
    }

    private func result(of delivery: SharedDelivery, callerDeadline: UInt64) async -> Bool {
        if callerDeadline < delivery.deadline {
            return await awaitResult(of: delivery.task, deadline: callerDeadline, timeoutValue: false)
        }
        return await delivery.task.value
    }

    enum ApprovalReadMode {
        case page, manualRecovery
    }

    @MainActor
    private func inspectReceipt(
        handle: ExtensionBridge.Handle,
        nonce: ExtensionBridge.NativeDeliveryNonce,
        policy: ReceiptPolicy = .delivery,
        deadline: UInt64
    ) async -> ReceiptStatus {
        guard !Task.isCancelled, dependencies.uptime() < deadline else { return .unavailable }
        let dependencies = dependencies
        let operation = Task { @MainActor in
            await Self.reconcileReceipt(
                handle: handle, nonce: nonce, policy: policy,
                isPending: { dependencies.uptime() < deadline }, dependencies: dependencies
            )
        }
        return await boundedResult(of: operation, deadline: deadline, timeoutValue: .unavailable)
    }

    @MainActor
    func deliverApproval(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce
    ) async -> ApprovalDeliveryResult {
        guard !Task.isCancelled else { return .unavailable }
        let loaded = await dependencies.load(handle)
        guard !Task.isCancelled,
              case .found(let snapshot) = loaded,
              snapshot.nativeDeliveryNonce == nativeDeliveryNonce else { return .unavailable }
        if snapshot.phase == .responded { return .responseReady }
        if snapshot.hasStagedOrActiveExecution {
            let status = await inspectReceipt(
                handle: handle, nonce: nativeDeliveryNonce,
                deadline: dependencies.deadline(after: launchTimeoutNanoseconds)
            )
            switch status {
            case .delivered: return .pending
            case .responseReady: return .responseReady
            case .needsDelivery, .terminal, .unavailable: return .unavailable
            }
        }
        let opened = await open(.approval(
            workflowVersion: ExtensionBridge.workflowVersion,
            handle: handle,
            nativeDeliveryNonce: nativeDeliveryNonce
        ))
        guard !Task.isCancelled else { return .unavailable }
        if !opened {
            let deadline = dependencies.deadline(after: NativeApprovalTiming.receiptWaitTimeoutNanoseconds)
            let status = await inspectReceipt(
                handle: handle, nonce: nativeDeliveryNonce,
                deadline: deadline
            )
            switch status {
            case .delivered: return .pending
            case .responseReady: return .responseReady
            case .needsDelivery, .terminal, .unavailable: return .unavailable
            }
        }
        return .pending
    }

    @MainActor
    func readApprovalResponse(
        handle: ExtensionBridge.Handle,
        configurationKey: String,
        revisions: ExtensionBridge.ProviderRevisions,
        executionDeadline: Date,
        mode: ApprovalReadMode
    ) async -> ExtensionBridge.ResponseReadResult {
        guard !Task.isCancelled else { return .pending }
        if mode == .manualRecovery {
            let loaded = await dependencies.loadManualSwitch(handle, configurationKey)
            guard !Task.isCancelled else { return .pending }
            switch loaded {
            case .found(let snapshot):
                if snapshot.phase != .responded {
                    let status = await inspectReceipt(
                        handle: handle, nonce: snapshot.nativeDeliveryNonce,
                        policy: .manualRecovery,
                        deadline: dependencies.deadline(after: launchTimeoutNanoseconds)
                    )
                    guard !Task.isCancelled else { return .pending }
                    switch status {
                    case .delivered, .responseReady: break
                    case .needsDelivery, .terminal, .unavailable: return .pending
                    }
                }
            case .missing: return .missing
            case .unavailable: return .unavailable
            }
        }

        var executionLease: ExtensionBridge.NativeExecutionReadLease?
        defer { executionLease?.release() }
        let execution = await dependencies.beginExecutionRead(
            handle, configurationKey, revisions, executionDeadline
        )
        if case .acquired(let lease) = execution { executionLease = lease }
        guard !Task.isCancelled else { return .pending }
        switch execution {
        case .acquired(let lease):
            let initialDeadline = dependencies.deadline(after: launchTimeoutNanoseconds)
            let initialStatus = await inspectReceipt(
                handle: handle, nonce: lease.nativeDeliveryNonce,
                policy: mode == .page ? .pageRead : .manualRecovery,
                deadline: initialDeadline
            )
            guard !Task.isCancelled else { return .pending }
            switch initialStatus {
            case .responseReady, .terminal:
                break
            case .needsDelivery, .unavailable:
                return mode == .page ? .unavailable : .pending
            case .delivered:
                let deadline = dependencies.deadline(after: NativeApprovalTiming.responseTimeoutNanoseconds)
                var nextDeliveryCheck = dependencies.deadline(after: NativeApprovalTiming.deliveryCheckIntervalNanoseconds)
                if dependencies.wallClock() >= lease.context.executionDeadline { return .pending }
                observation: while !Task.isCancelled, dependencies.uptime() < deadline {
                    let loaded = await dependencies.load(handle)
                    guard !Task.isCancelled else { return .pending }
                    switch loaded {
                    case .found(let snapshot):
                        guard snapshot.configurationKey == configurationKey,
                              snapshot.phase != .responded else { break observation }
                        if snapshot.phase == .queued,
                           dependencies.wallClock() >= lease.context.executionDeadline { return .pending }
                        let now = dependencies.uptime()
                        if case .queued(_, .staged) = snapshot.state, now >= nextDeliveryCheck {
                            let status = await inspectReceipt(
                                handle: handle, nonce: lease.nativeDeliveryNonce,
                                policy: mode == .page ? .pageRead : .manualRecovery,
                                deadline: min(deadline, dependencies.deadline(after: launchTimeoutNanoseconds))
                            )
                            guard !Task.isCancelled else { return .pending }
                            switch status {
                            case .responseReady, .terminal: break observation
                            case .delivered: break
                            case .needsDelivery, .unavailable: return .pending
                            }
                            let next = now.addingReportingOverflow(NativeApprovalTiming.deliveryCheckIntervalNanoseconds)
                            nextDeliveryCheck = next.overflow ? UInt64.max : next.partialValue
                        }
                    case .missing: break observation
                    case .unavailable: break
                    }
                    let wake = dependencies.deadline(after: NativeApprovalTiming.responsePollIntervalNanoseconds)
                    await dependencies.sleepUntil(min(wake, deadline))
                }
                guard !Task.isCancelled, dependencies.uptime() < deadline else { return .pending }
            }
        case .needsDelivery(let nonce):
            let deadline = dependencies.deadline(after: launchTimeoutNanoseconds)
            let status = await inspectReceipt(
                handle: handle, nonce: nonce,
                policy: mode == .page ? .pageRead : .manualRecovery,
                deadline: deadline
            )
            guard !Task.isCancelled else { return .pending }
            switch status {
            case .delivered, .responseReady, .terminal: break
            case .needsDelivery where mode == .page:
                let route = NativeAgentRoute.approval(
                    workflowVersion: ExtensionBridge.workflowVersion,
                    handle: handle, nativeDeliveryNonce: nonce
                )
                let delivered = await open(route, waitDeadline: deadline)
                guard !Task.isCancelled else { return .pending }
                guard delivered else { return .unavailable }
            case .needsDelivery, .unavailable:
                return mode == .page ? .unavailable : .pending
            }
        case .pending, .responseReady, .missing: break
        case .unavailable: return .unavailable
        }
        guard !Task.isCancelled else { return .pending }
        let response = await dependencies.readResponse(handle, configurationKey)
        return Task.isCancelled ? .pending : response
    }

    func reactivate(
        _ route: NativeAgentRoute,
        waitDeadline: UInt64? = nil
    ) async -> Bool {
        guard !Task.isCancelled, case .approval = route else {
            return false
        }
        let deadline = min(
            dependencies.deadline(after: launchTimeoutNanoseconds),
            waitDeadline ?? UInt64.max
        )
        guard dependencies.uptime() < deadline else { return false }
        let operation = Task { await self.reactivateApproval(route, deadline: deadline) }
        return await boundedResult(of: operation, deadline: deadline, timeoutValue: false)
    }

    private func reactivateApproval(_ route: NativeAgentRoute, deadline: UInt64) async -> Bool {
        guard case .approval(_, let handle, let nativeDeliveryNonce) = route else { return false }
        let isPending = { !Task.isCancelled && self.dependencies.uptime() < deadline }
        switch await Self.reconcileReceipt(
            handle: handle, nonce: nativeDeliveryNonce,
            isPending: isPending, dependencies: dependencies
        ) {
        case .needsDelivery:
            return isPending() ? await open(route, waitDeadline: deadline) : false
        case .delivered:
            break
        case .responseReady, .terminal, .unavailable:
            return false
        }
        guard isPending(),
              case .found(let snapshot) = await dependencies.load(handle),
              snapshot.nativeDeliveryNonce == nativeDeliveryNonce,
              case .queued = snapshot.state,
              let receipt = snapshot.nativeDeliveryReceipt,
              receipt.nativeDeliveryNonce == nativeDeliveryNonce,
              case .compatible(let runtime) = await dependencies
                .receiptRuntimeStatus(receipt),
              runtime.identity.instanceIdentifier == receipt.owner.runtimeInstanceIdentifier else {
            return false
        }
        return await Self.performLaunch(
            route: route, to: runtime.target,
            isPending: isPending, dependencies: dependencies
        )
    }

    private func finishSharedDelivery(identifier: UUID) {
        sharedDeliveries.removeAll { $0.identifier == identifier }
        if deliveryTailIdentifier == identifier {
            deliveryTail = nil
            deliveryTailIdentifier = nil
        }
    }

    @MainActor
    private func deliver(
        _ route: NativeAgentRoute,
        deadline: UInt64
    ) async -> Bool {
        let dependencies = dependencies
        let isPending = { !Task.isCancelled && dependencies.uptime() < deadline }
        guard isPending() else { return false }
        if case .approval(_, let handle, let nonce) = route {
            switch await Self.reconcileReceipt(
                handle: handle, nonce: nonce,
                isPending: isPending, dependencies: dependencies
            ) {
            case .delivered, .responseReady: return true
            case .terminal, .unavailable: return false
            case .needsDelivery: break
            }
        }
        guard isPending(), let url = dependencies.helperURL(),
              let target = await Self.resolveTargetHelper(
                currentURL: url, deadline: deadline,
                isPending: isPending, dependencies: dependencies
              ), isPending(),
              await Self.performLaunch(
                route: route, to: target,
                isPending: isPending, dependencies: dependencies
              ), let expected = ExpectedRuntime(url: target.url) else { return false }
        while isPending() {
            switch route {
            case .approval(_, let handle, let nonce):
                switch await Self.reconcileReceipt(
                    handle: handle, nonce: nonce,
                    isPending: isPending, dependencies: dependencies
                ) {
                case .delivered, .responseReady: return isPending()
                case .terminal: return false
                case .needsDelivery, .unavailable: break
                }
            case .showWallet:
                if await Self.runtimeIsConfirmed(
                    expected: expected, isPending: isPending, dependencies: dependencies
                ) { return true }
            }
            let now = dependencies.uptime()
            guard isPending(), now < deadline else { return false }
            await dependencies.wait(min(NativeApprovalTiming.launchPollIntervalNanoseconds, deadline - now))
        }
        return false
    }

    @MainActor
    private static func performLaunch(
        route: NativeAgentRoute,
        to selectedTarget: HelperTarget,
        isPending: @escaping () -> Bool,
        dependencies: Dependencies
    ) async -> Bool {
        guard !Task.isCancelled, isPending(),
              await dependencies.validate(selectedTarget.url),
              !Task.isCancelled, isPending() else {
            return false
        }
        let resolution = ApprovalResolution<Bool>()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled, isPending() else { return false }
            dependencies.launch(selectedTarget, route.url) { succeeded in
                let delivered = succeeded && isPending()
                Task { @MainActor in resolution.resolve(delivered) }
            }
            return await resolution.value()
        } onCancel: {
            Task { @MainActor in resolution.resolve(false) }
        }
    }

    private static func assessRuntime(
        _ subject: RuntimeSubject,
        expected: ExpectedRuntime,
        helper: (Int32) -> RuntimeHelper?,
        identity: (Int32) -> AmbientRuntimeIdentity?
    ) -> RuntimeAssessment {
        let runtime: RuntimeHelper
        let owner: ExtensionBridge.NativeDeliveryOwner?
        switch subject {
        case .candidate(let candidate):
            runtime = candidate
            owner = nil
        case .receiptOwner(let receiptOwner):
            guard receiptOwner.isValid else { return .unidentified(nil) }
            guard let candidate = helper(receiptOwner.processIdentifier) else { return .absent }
            guard candidate.processIdentifier == receiptOwner.processIdentifier else {
                return .unidentified(candidate)
            }
            runtime = candidate
            owner = receiptOwner
        }
        guard runtime.isRunning() else { return .absent }
        if let owner {
            guard let started = runtime.processStartDate else { return .unidentified(runtime) }
            guard AmbientRuntimeIdentity.matchesProcessStart(owner.processStartDate, started) else {
                return .absent
            }
        }
        guard let url = runtime.bundleURL?.standardizedFileURL,
              let observed = verifiedRuntimeIdentity(
                  processIdentifier: runtime.processIdentifier,
                  bundleURL: url, processStartDate: runtime.processStartDate,
                  identity: identity
              ), owner.map({ observed.matches($0) }) ?? true else {
            return .unidentified(runtime)
        }
        let identified = IdentifiedRuntime(helper: runtime, identity: observed)
        return expected.isCompatible(observed, runtimeURL: url)
            ? .compatible(identified) : .incompatible(identified)
    }

    private static func verifiedRuntimeIdentity(
        processIdentifier: Int32,
        bundleURL: URL,
        processStartDate: Date?,
        identity: (Int32) -> AmbientRuntimeIdentity?
    ) -> AmbientRuntimeIdentity? {
        guard let runtimeIdentity = identity(processIdentifier),
              runtimeIdentity.matches(
                  processIdentifier: processIdentifier,
                  bundleURL: bundleURL,
                  processStartDate: processStartDate
              ) else { return nil }
        return runtimeIdentity
    }

    @MainActor
    static func resolveTargetHelper(
        currentURL: URL,
        deadline: UInt64,
        isPending: @escaping () -> Bool,
        dependencies: Dependencies
    ) async -> HelperTarget? {
        let canContinue = { !Task.isCancelled && isPending() && dependencies.uptime() < deadline }
        guard canContinue(), let expected = ExpectedRuntime(url: currentURL) else { return nil }
        var unknownFirstObservedAt = [RuntimeProcessKey: UInt64]()
        var requestedQuit = Set<RuntimeProcessKey>()
        while canContinue() {
            let now = dependencies.uptime()
            guard canContinue(), now < deadline else { return nil }
            let candidates = dependencies.helpers().filter {
                $0.bundleURL?.standardizedFileURL == expected.url
            }
            var target: HelperTarget?
            var mustWait = false
            var verifiedCurrentBundle = false
            for candidate in candidates {
                guard canContinue() else { return nil }
                let key = RuntimeProcessKey(candidate)
                switch assessRuntime(.candidate(candidate), expected: expected,
                                     helper: dependencies.helper, identity: dependencies.identity) {
                case .absent:
                    continue
                case .compatible(let runtime):
                    if target == nil { target = runtime.target }
                    continue
                case .unidentified:
                    let firstObserved = unknownFirstObservedAt[key] ?? now
                    unknownFirstObservedAt[key] = firstObserved
                    if now < firstObserved ||
                        now - firstObserved < NativeApprovalTiming.runtimeIdentityGracePeriodNanoseconds {
                        mustWait = true
                        continue
                    }
                case .incompatible:
                    break
                }
                if requestedQuit.contains(key) {
                    mustWait = true
                    continue
                }
                if !verifiedCurrentBundle {
                    guard await dependencies.validate(expected.url) else { return nil }
                    verifiedCurrentBundle = true
                }
                guard canContinue(), expected.installedVersionMatches else { return nil }
                switch assessRuntime(.candidate(candidate), expected: expected,
                                     helper: dependencies.helper, identity: dependencies.identity) {
                case .absent:
                    mustWait = true
                    continue
                case .compatible(let runtime):
                    if target == nil { target = runtime.target }
                case .incompatible, .unidentified:
                    mustWait = true
                    requestedQuit.insert(key)
                    guard candidate.requestQuit() else { return nil }
                }
            }
            guard canContinue() else { return nil }
            if mustWait {
                let now = dependencies.uptime()
                guard now < deadline else { return nil }
                await dependencies.wait(min(NativeApprovalTiming.launchPollIntervalNanoseconds, deadline - now))
                continue
            }
            return target ?? .launch(url: expected.url)
        }
        return nil
    }

#if os(macOS)
    @MainActor
    static func runtimeStatus(
        receipt: ExtensionBridge.NativeDeliveryReceipt,
        expectedURL: URL,
        expectedVersion: AmbientRuntimeIdentity.Version,
        helper: @escaping (Int32) -> RuntimeHelper?,
        identity: @escaping (Int32) -> AmbientRuntimeIdentity?,
        validate: @escaping (URL) async -> Bool
    ) async -> RuntimeAssessment {
        let expected = ExpectedRuntime(
            url: expectedURL,
            version: expectedVersion
        )
        return await runtimeStatus(
            receipt: receipt,
            expected: expected,
            helper: helper,
            identity: identity,
            validate: validate
        )
    }

    @MainActor
    private static func runtimeStatus(
        receipt: ExtensionBridge.NativeDeliveryReceipt,
        expected: ExpectedRuntime,
        helper: @escaping (Int32) -> RuntimeHelper?,
        identity: @escaping (Int32) -> AmbientRuntimeIdentity?,
        validate: @escaping (URL) async -> Bool
    ) async -> RuntimeAssessment {
        let assessment = assessRuntime(
            .receiptOwner(receipt.owner), expected: expected,
            helper: helper, identity: identity
        )
        if case .compatible(let runtime) = assessment {
            guard await verifyRuntime(runtime, expected: expected,
                                      identity: identity, validate: validate) else {
                return .unidentified(runtime.helper)
            }
        }
        return assessment
    }

#endif

    @MainActor
    private static func verifyRuntime(
        _ runtime: IdentifiedRuntime,
        expected: ExpectedRuntime,
        identity: (Int32) -> AmbientRuntimeIdentity?,
        validate: (URL) async -> Bool
    ) async -> Bool {
        let runtimeURL = runtime.target.url
        let observedIdentity = runtime.identity
        guard await validate(expected.url) else { return false }
        if runtimeURL != expected.url {
            guard await validate(runtimeURL) else { return false }
        }
        guard expected.installedVersionMatches,
              runtime.helper.isRunning(),
              verifiedRuntimeIdentity(
                  processIdentifier: runtime.helper.processIdentifier,
                  bundleURL: runtimeURL,
                  processStartDate: runtime.helper.processStartDate,
                  identity: identity
              ) == observedIdentity else { return false }
        return true
    }


    private func boundedResult<Value: Sendable>(
        of task: Task<Value, Never>, deadline: UInt64, timeoutValue: Value
    ) async -> Value {
        let resolution = LaunchResolution<Value>()
        return await withTaskCancellationHandler {
            let result = await awaitResult(of: task, deadline: deadline, timeoutValue: timeoutValue, resolution: resolution)
            task.cancel()
            return result
        } onCancel: {
            task.cancel()
            Task { await resolution.finish(timeoutValue) }
        }
    }

    private func awaitResult<Value: Sendable>(
        of task: Task<Value, Never>,
        deadline: UInt64,
        timeoutValue: Value,
        resolution: LaunchResolution<Value> = LaunchResolution()
    ) async -> Value {
        guard dependencies.uptime() < deadline else { return timeoutValue }
        let timeoutTask = Task {
            await dependencies.sleepUntil(deadline)
            guard !Task.isCancelled else { return }
            await resolution.finish(timeoutValue)
        }
        let completionTask = Task { await resolution.finish(await task.value) }
        let result = await resolution.value()
        timeoutTask.cancel()
        completionTask.cancel()
        return result
    }

    @MainActor
    static func isConfirmedRuntimeHelper(
        _ helper: RuntimeHelper,
        expectedURL: URL,
        expectedVersion: AmbientRuntimeIdentity.Version? = nil,
        identity: (Int32) -> AmbientRuntimeIdentity?,
        validate: (URL) async -> Bool
    ) async -> Bool {
        guard let version = expectedVersion ?? AmbientRuntimeIdentity.bundleVersion(
            at: expectedURL.standardizedFileURL
        ) else { return false }
        let expected = ExpectedRuntime(
            url: expectedURL,
            version: version
        )
        return await isConfirmedRuntimeHelper(
            helper,
            expected: expected,
            identity: identity,
            validate: validate
        )
    }

    @MainActor
    private static func isConfirmedRuntimeHelper(
        _ helper: RuntimeHelper,
        expected: ExpectedRuntime,
        identity: (Int32) -> AmbientRuntimeIdentity?,
        validate: (URL) async -> Bool
    ) async -> Bool {
        guard case .compatible(let runtime) = assessRuntime(
            .candidate(helper), expected: expected,
            helper: { _ in helper }, identity: identity
        ) else { return false }
#if os(macOS)
        return await verifyRuntime(
            runtime,
            expected: expected,
            identity: identity,
            validate: validate
        )
#else
        return false
#endif
    }

    static func isCompatibleRuntimeIdentity(
        _ identity: AmbientRuntimeIdentity,
        runtimeURL: URL,
        expectedURL: URL,
        expectedVersion: AmbientRuntimeIdentity.Version? = nil
    ) -> Bool {
        guard let version = expectedVersion ?? AmbientRuntimeIdentity.bundleVersion(
            at: expectedURL.standardizedFileURL
        ) else { return false }
        let expected = ExpectedRuntime(
            url: expectedURL,
            version: version
        )
        return expected.isCompatible(
            identity,
            runtimeURL: runtimeURL
        )
    }


}
