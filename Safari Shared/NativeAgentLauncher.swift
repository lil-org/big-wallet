// ∅ 2026 lil org

import Foundation
import OSLog

#if os(macOS)
import AppKit
import Security
#endif

actor NativeAgentLauncher {
    private static let logger = Logger(
        subsystem: "org.lil.wallet",
        category: "NativeAgentLauncher"
    )

    enum ExistingDeliveryStatus: Equatable {
        case delivered, needsDelivery, terminal, unavailable
    }

    enum HelperTarget: Equatable, Sendable {
        case running(
            url: URL,
            processIdentifier: Int32,
            runtimeInstanceIdentifier: UUID
        )
        case launch(url: URL, createsNewApplicationInstance: Bool)

        var url: URL {
            switch self {
            case .running(let url, _, _), .launch(let url, _):
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

    private struct ObservedRuntime {
        let helper: RuntimeHelper
        let bundleURL: URL?
        let identity: AmbientRuntimeIdentity?
    }

    private enum ReceiptOwnerObservation {
        case owner(ObservedRuntime)
        case absent, indeterminate
    }

    private struct RuntimeProcessKey: Hashable {
        let processIdentifier: Int32
        let processStartDate: Date?

        init(_ helper: RuntimeHelper) {
            processIdentifier = helper.processIdentifier
            processStartDate = helper.processStartDate
        }
    }

    struct ExactReceiptOwner {
        let requestQuit: @MainActor (_ isPending: () -> Bool) async -> Bool
        let isRunning: () -> Bool
    }

    enum ReceiptRuntimeStatus {
        case compatible(HelperTarget)
        case incompatible(ExactReceiptOwner), absent, indeterminate
    }

    struct Dependencies {
        let helperURL: () -> URL?
        let validate: (URL) async -> Bool
        let helpers: @MainActor () -> [RuntimeHelper]
        let helper: @MainActor (Int32) -> RuntimeHelper?
        let identity: (Int32) -> AmbientRuntimeIdentity?
        let launch: Launch
        let load: (ExtensionBridge.Handle) async -> ExtensionBridge.SnapshotResult
        let clearReceipt: (
            ExtensionBridge.Handle,
            ExtensionBridge.NativeDeliveryReceipt
        ) async -> ExtensionBridge.StoreMutationResult
        let uptime: () -> UInt64
        let wallClock: () -> Date
        let sleepUntil: (UInt64) async -> Void

        static var live: Self {
            Self(
                helperURL: NativeAgentLauncher.embeddedHelperURL,
                validate: NativeAgentLauncher.validateEmbeddedHelper,
                helpers: {
#if os(macOS)
                    NativeAgentLauncher.runningHelpers()
#else
                    []
#endif
                },
                helper: { identifier in
#if os(macOS)
                    NativeAgentLauncher.runningHelper(processIdentifier: identifier)
#else
                    nil
#endif
                },
                identity: { AmbientRuntimeIdentity.load(processIdentifier: $0) },
                launch: NativeAgentLauncher.launchApplication,
                load: { await ExtensionBridge.shared.load(handle: $0) },
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
        ) async -> ReceiptRuntimeStatus {
#if os(macOS)
            guard let url = helperURL(), let expected = ExpectedRuntime(url: url) else {
                return .indeterminate
            }
            return await NativeAgentLauncher.runtimeStatus(
                receipt: receipt,
                expected: expected,
                helper: helper,
                identity: identity,
                validate: validate
            )
#else
            return .indeterminate
#endif
        }
    }

    private struct SharedDelivery {
        let identifier: UUID
        let route: NativeAgentRoute
        let deadline: UInt64
        let task: Task<Bool, Never>
    }

    @MainActor
    private static func reconcileReceipt(
        handle: ExtensionBridge.Handle,
        nonce: ExtensionBridge.NativeDeliveryNonce,
        isPending: @escaping () -> Bool,
        dependencies: Dependencies
    ) async -> ExistingDeliveryStatus {
        while !Task.isCancelled, isPending() {
            let receipt: ExtensionBridge.NativeDeliveryReceipt
            let loaded = await dependencies.load(handle)
            guard !Task.isCancelled, isPending() else { return .unavailable }
            switch loaded {
            case .found(let snapshot):
                guard snapshot.nativeDeliveryNonce == nonce else { return .terminal }
                if snapshot.phase == .responded { return .delivered }
                guard let current = snapshot.nativeDeliveryReceipt else { return .needsDelivery }
                guard current.nativeDeliveryNonce == nonce else { return .terminal }
                receipt = current
            case .missing:
                return .terminal
            case .unavailable:
                return .unavailable
            }
            let status = await dependencies.receiptRuntimeStatus(receipt)
            guard !Task.isCancelled, isPending() else { return .unavailable }
            switch status {
            case .compatible:
                return .delivered
            case .incompatible(let owner):
                let loaded = await dependencies.load(handle)
                guard !Task.isCancelled, isPending() else { return .unavailable }
                switch loaded {
                case .found(let current):
                    guard current.nativeDeliveryNonce == nonce else { return .terminal }
                    if current.phase == .responded { return .delivered }
                    guard current.nativeDeliveryReceipt == receipt else { continue }
                case .missing:
                    return .terminal
                case .unavailable:
                    return .unavailable
                }
                guard await owner.requestQuit({ !Task.isCancelled && isPending() }) else {
                    return .unavailable
                }
                while owner.isRunning(), !Task.isCancelled, isPending() {
                    await dependencies.wait(50_000_000)
                }
            case .absent:
                break
            case .indeterminate:
                return .unavailable
            }
            guard !Task.isCancelled, isPending() else { return .unavailable }
            let cleared = await dependencies.clearReceipt(handle, receipt)
            guard !Task.isCancelled, isPending() else { return .unavailable }
            switch cleared {
            case .persisted:
                return .needsDelivery
            case .ownershipLost:
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

    private actor LaunchResolution {
        private var continuation: CheckedContinuation<Bool, Never>?
        private var timeoutTask: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func install(timeoutTask: Task<Void, Never>) {
            guard continuation != nil else {
                timeoutTask.cancel()
                return
            }
            self.timeoutTask = timeoutTask
        }

        func finish(_ succeeded: Bool) {
            guard let continuation else { return }
            self.continuation = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            continuation.resume(returning: succeeded)
        }
    }

    static let live = NativeAgentLauncher(dependencies: .live)

    private let dependencies: Dependencies
    private let launchTimeoutNanoseconds: UInt64
    private var sharedDeliveries = [SharedDelivery]()
    private var deliveryTail: Task<Void, Never>?
    private var deliveryTailIdentifier: UUID?

    init(
        dependencies: Dependencies,
        launchTimeoutNanoseconds: UInt64 = 5_000_000_000
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
            return await awaitResult(
                of: shared.task,
                deadline: callerDeadline
            )
        }
        let identifier = UUID()
        let precedingDelivery = deliveryTail
        let operation = Task { [weak self] in
            await precedingDelivery?.value
            guard let self else { return false }
            return await self.deliver(route, deadline: deliveryDeadline)
        }
        let task = Task { [weak self] in
            guard let self else { operation.cancel(); return false }
            let result = await self.awaitResult(of: operation, deadline: deliveryDeadline)
            operation.cancel()
            await self.finishSharedDelivery(identifier: identifier)
            return result
        }
        sharedDeliveries.append(SharedDelivery(
            identifier: identifier,
            route: route,
            deadline: deliveryDeadline,
            task: task
        ))
        deliveryTail = Task { _ = await task.value }
        deliveryTailIdentifier = identifier
        return await awaitResult(of: task, deadline: callerDeadline)
    }

    enum ApprovalReadMode {
        case page, manualRecovery
    }

    enum FinalizationResult {
        case readyToRead, pending, deliveryUnavailable
    }

    @MainActor
    func ensureApprovalDelivery(
        handle: ExtensionBridge.Handle,
        mode: ApprovalReadMode,
        waitDeadline: UInt64? = nil
    ) async -> Bool {
        switch await dependencies.load(handle) {
        case .found(let snapshot):
            guard snapshot.phase != .responded else { return true }
            if mode == .manualRecovery {
                return await hasCompatibleApprovalDelivery(
                    handle: handle,
                    nativeDeliveryNonce: snapshot.nativeDeliveryNonce
                )
            }
#if os(macOS)
            if case .queued(_, .delivered(let receipt)) = snapshot.state,
               receipt.nativeDeliveryNonce == snapshot.nativeDeliveryNonce,
               let url = dependencies.helperURL(),
               let expected = ExpectedRuntime(url: url),
               case .owner(let runtime) = Self.observeReceiptOwner(
                   receipt,
                   helper: dependencies.helper,
                   identity: dependencies.identity
               ),
               let identity = runtime.identity,
               expected.isCompatible(identity, runtimeURL: runtime.bundleURL),
               expected.installedVersionMatches,
               dependencies.uptime() < (waitDeadline ?? UInt64.max) {
                return true
            }
#endif
            return await open(
                .approval(
                    workflowVersion: ExtensionBridge.workflowVersion,
                    handle: handle,
                    nativeDeliveryNonce: snapshot.nativeDeliveryNonce
                ),
                waitDeadline: waitDeadline
            )
        case .missing:
            return true
        case .unavailable:
            return false
        }
    }

    @MainActor
    func waitForFinalization(
        handle: ExtensionBridge.Handle,
        configurationKey: String,
        initialContext: ExtensionBridge.NativeExecutionContext,
        mode: ApprovalReadMode
    ) async -> FinalizationResult {
        guard await ensureApprovalDelivery(
            handle: handle,
            mode: mode
        ) else { return .deliveryUnavailable }
        let startedAt = dependencies.uptime()
        let deadline = startedAt.addingReportingOverflow(170_000_000_000).partialValue
        var nextDeliveryCheck = startedAt
        if dependencies.wallClock() >= initialContext.executionDeadline { return .pending }
        while !Task.isCancelled, dependencies.uptime() < deadline {
            switch await dependencies.load(handle) {
            case .found(let snapshot):
                guard snapshot.configurationKey == configurationKey,
                      snapshot.phase != .responded else { return .readyToRead }
                if snapshot.phase == .queued,
                   dependencies.wallClock() >= initialContext.executionDeadline {
                    return .pending
                }
                if case .queued(_, .staged(let approval)) = snapshot.state,
                   approval.receipt == nil {
                    return .pending
                }
                let now = dependencies.uptime()
                if case .queued(_, .staged) = snapshot.state,
                   now >= nextDeliveryCheck {
                    guard await ensureApprovalDelivery(
                        handle: handle,
                        mode: mode,
                        waitDeadline: deadline
                    ) else { return .pending }
                    nextDeliveryCheck = now.addingReportingOverflow(1_000_000_000).partialValue
                }
            case .missing:
                return .readyToRead
            case .unavailable:
                break
            }
            await dependencies.wait(250_000_000)
        }
        return .pending
    }

    func reactivate(
        _ route: NativeAgentRoute,
        waitDeadline: UInt64? = nil
    ) async -> Bool {
        guard case .approval(_, let handle, let nativeDeliveryNonce) = route else {
            return false
        }
        let deadline = min(
            dependencies.deadline(after: launchTimeoutNanoseconds),
            waitDeadline ?? UInt64.max
        )
        let isPending = { self.dependencies.uptime() < deadline }
        switch await approvalDeliveryStatus(
            handle: handle,
            nativeDeliveryNonce: nativeDeliveryNonce,
            isPending: isPending
        ) {
        case .needsDelivery:
            return isPending() ? await open(route, waitDeadline: deadline) : false
        case .delivered:
            break
        case .terminal, .unavailable:
            return false
        }
        guard isPending(),
              case .found(let snapshot) = await dependencies.load(handle),
              snapshot.nativeDeliveryNonce == nativeDeliveryNonce,
              case .queued = snapshot.state,
              let receipt = snapshot.nativeDeliveryReceipt,
              receipt.nativeDeliveryNonce == nativeDeliveryNonce,
              case .compatible(let target) = await dependencies
                .receiptRuntimeStatus(receipt),
              case .running(_, _, let runtimeInstanceIdentifier) = target,
              runtimeInstanceIdentifier == receipt.owner.runtimeInstanceIdentifier else {
            return false
        }
        return await launchOnce(route: route, to: target, deadline: deadline)
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
            case .delivered: return true
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
                route: route, to: target, deadline: deadline,
                isPending: isPending, dependencies: dependencies
              ), let expected = ExpectedRuntime(url: target.url) else { return false }
        while isPending() {
            switch route {
            case .approval(_, let handle, let nonce):
                switch await Self.reconcileReceipt(
                    handle: handle, nonce: nonce,
                    isPending: isPending, dependencies: dependencies
                ) {
                case .delivered: return isPending()
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
            await dependencies.wait(min(50_000_000, deadline - now))
        }
        return false
    }

    private func launchOnce(
        route: NativeAgentRoute,
        to selectedTarget: HelperTarget,
        deadline: UInt64
    ) async -> Bool {
        await Self.performLaunch(
            route: route,
            to: selectedTarget,
            deadline: deadline,
            dependencies: dependencies
        )
    }

    @MainActor
    private static func performLaunch(
        route: NativeAgentRoute,
        to selectedTarget: HelperTarget,
        deadline: UInt64,
        isPending: (() -> Bool)? = nil,
        dependencies: Dependencies
    ) async -> Bool {
        let isPending = isPending ?? { dependencies.uptime() < deadline }
        guard isPending(), await dependencies.validate(selectedTarget.url), isPending() else {
            return false
        }
        return await withCheckedContinuation { continuation in
            let launchResolution = LaunchResolution(continuation)
            let timeoutTask = Task {
                await dependencies.sleepUntil(deadline)
                guard !Task.isCancelled else { return }
                await launchResolution.finish(false)
            }
            Task { await launchResolution.install(timeoutTask: timeoutTask) }
            dependencies.launch(selectedTarget, route.url) { succeeded in
                Task {
                    await launchResolution.finish(
                        succeeded && isPending()
                    )
                }
            }
        }
    }

    private static func embeddedHelperURL() -> URL? {
#if os(macOS)
        return embeddedHelperURL(in: Bundle.main.bundleURL)
#else
        return nil
#endif
    }

    static func embeddedHelperURL(in extensionURL: URL) -> URL? {
        guard extensionURL.isFileURL,
              extensionURL.pathExtension == "appex" else { return nil }
        return extensionURL.standardizedFileURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("Big Wallet.app", isDirectory: true)
    }

    private static func validateEmbeddedHelper(_ url: URL) async -> Bool {
#if os(macOS)
        return await codeValidator.validate(
            helperURL: url,
            extensionURL: Bundle.main.bundleURL
        )
#else
        return false
#endif
    }

#if os(macOS)
    private static let codeValidator = CodeValidator(
        validate: { checkEmbeddedHelper($0, extensionURL: $1) }
    )

    private static func checkEmbeddedHelper(_ url: URL, extensionURL: URL) -> Bool {
        guard let bundle = Bundle(url: url),
              bundle.bundleIdentifier == "org.lil.wallet.ambient" else {
            logger.error("Helper bundle is unavailable")
            return false
        }
        guard let helperCode = staticCode(at: url) else {
            logger.error("Helper static code is unavailable")
            return false
        }
        guard let containingCode = staticCode(at: extensionURL) else {
            logger.error("Containing extension static code is unavailable")
            return false
        }
        let helperStatus = SecStaticCodeCheckValidity(
            helperCode,
            SecCSFlags(
                rawValue: kSecCSCheckAllArchitectures |
                    kSecCSCheckNestedCode |
                    kSecCSStrictValidate
            ),
            nil
        )
        let containingStatus = SecStaticCodeCheckValidity(
            containingCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        )
        guard helperStatus == errSecSuccess, containingStatus == errSecSuccess else {
            logger.error("Code validation failed: helper=\(helperStatus) extension=\(containingStatus)")
            return false
        }
        let helperTeam = teamIdentifier(for: helperCode)
        let containingTeam = teamIdentifier(for: containingCode)
#if DEBUG
        return helperTeam == containingTeam
#else
        return helperTeam != nil && helperTeam == containingTeam
#endif
    }
#endif

    @MainActor
    private static func launchApplication(
        target: HelperTarget,
        routeURL: URL,
        completion: @escaping (Bool) -> Void
    ) {
#if os(macOS)
        switch target {
        case .running(
            let helperURL,
            let processIdentifier,
            let runtimeInstanceIdentifier
        ):
            guard let expected = ExpectedRuntime(url: helperURL),
                  let processStartDate = AmbientRuntimeIdentity.processStartDate(
                      processIdentifier: processIdentifier
                  ),
                  let identity = verifiedRuntimeIdentity(
                      processIdentifier: processIdentifier,
                      bundleURL: helperURL,
                      processStartDate: processStartDate,
                      identity: {
                          AmbientRuntimeIdentity.load(processIdentifier: $0)
                      }
                  ), identity.instanceIdentifier == runtimeInstanceIdentifier,
                  expected.isCompatible(
                      identity,
                      runtimeURL: helperURL
                  ) else {
                completion(false)
                return
            }
            let event = NSAppleEventDescriptor(
                eventClass: AEEventClass(kInternetEventClass),
                eventID: AEEventID(kAEGetURL),
                targetDescriptor: NSAppleEventDescriptor(
                    processIdentifier: processIdentifier
                ),
                returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID)
            )
            event.setParam(
                NSAppleEventDescriptor(string: routeURL.absoluteString),
                forKeyword: AEKeyword(keyDirectObject)
            )
            do {
                _ = try event.sendEvent(
                    options: [.noReply, .neverInteract],
                    timeout: 1
                )
                completion(true)
            } catch {
                logger.error("Helper route delivery failed: \((error as NSError).code)")
                completion(false)
            }
        case .launch(let helperURL, let createsNewApplicationInstance):
            let configuration = applicationLaunchConfiguration(
                createsNewApplicationInstance: createsNewApplicationInstance
            )
            NSWorkspace.shared.open(
                [routeURL],
                withApplicationAt: helperURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    logger.error("Helper launch failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
                }
                completion(error == nil)
            }
        }
#else
        completion(false)
#endif
    }

#if os(macOS)
    static func applicationLaunchConfiguration(
        createsNewApplicationInstance: Bool
    ) -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.createsNewApplicationInstance =
            createsNewApplicationInstance
        return configuration
    }
#endif

#if os(macOS)
    private static func runningHelpers() -> [RuntimeHelper] {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: "org.lil.wallet.ambient"
        ).map(runtimeHelper)
    }

    private static func runningHelper(processIdentifier: Int32) -> RuntimeHelper? {
        NSRunningApplication(processIdentifier: processIdentifier).map(runtimeHelper)
    }

    private static func runtimeHelper(_ application: NSRunningApplication) -> RuntimeHelper {
        let processIdentifier = application.processIdentifier
        let processStartDate = AmbientRuntimeIdentity.processStartDate(
            processIdentifier: processIdentifier
        )
        return RuntimeHelper(
            processIdentifier: processIdentifier,
            bundleURL: application.bundleURL,
            processStartDate: processStartDate,
            isRunning: {
                runtimeProcessIsRunning(
                    processIdentifier: processIdentifier,
                    capturedStartDate: processStartDate,
                    isTerminated: application.isTerminated
                )
            },
            requestQuit: {
                requestExactReceiptOwnerQuit(
                    processIdentifier: processIdentifier,
                    capturedStartDate: processStartDate
                )
            }
        )
    }

    static func requestExactReceiptOwnerQuit(
        processIdentifier: Int32,
        capturedStartDate: Date?,
        runningProcessStartDate: (Int32) -> Date? = {
            AmbientRuntimeIdentity.processStartDate(processIdentifier: $0)
        },
        sendQuitEvent: (Int32) -> Bool = sendQuitAppleEvent
    ) -> Bool {
        switch AmbientRuntimeIdentity.processStatus(
            processIdentifier: processIdentifier,
            capturedStartDate: capturedStartDate,
            runningProcessStartDate: runningProcessStartDate
        ) {
        case .current:
            return sendQuitEvent(processIdentifier)
        case .replaced:
            return true
        case .unknown:
            return false
        }
    }

    static func runtimeProcessIsRunning(
        processIdentifier: Int32,
        capturedStartDate: Date?,
        isTerminated: Bool,
        runningProcessStartDate: (Int32) -> Date? = {
            AmbientRuntimeIdentity.processStartDate(processIdentifier: $0)
        }
    ) -> Bool {
        guard !isTerminated else { return false }
        switch AmbientRuntimeIdentity.processStatus(
            processIdentifier: processIdentifier,
            capturedStartDate: capturedStartDate,
            runningProcessStartDate: runningProcessStartDate
        ) {
        case .current:
            return true
        case .replaced:
            return false
        case .unknown:
            return true
        }
    }

    private static func sendQuitAppleEvent(
        processIdentifier: Int32
    ) -> Bool {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEQuitApplication),
            targetDescriptor: NSAppleEventDescriptor(
                processIdentifier: processIdentifier
            ),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        do {
            _ = try event.sendEvent(
                options: [.noReply, .neverInteract],
                timeout: 1
            )
            return true
        } catch {
            return false
        }
    }

#endif

    private static func observedRuntimes(
        _ helpers: [RuntimeHelper],
        identity: (Int32) -> AmbientRuntimeIdentity?
    ) -> [ObservedRuntime] {
        helpers.compactMap { helper in
            guard helper.isRunning() else { return nil }
            let bundleURL = helper.bundleURL?.standardizedFileURL
            let verifiedIdentity = bundleURL.flatMap { bundleURL in
                verifiedRuntimeIdentity(
                    processIdentifier: helper.processIdentifier,
                    bundleURL: bundleURL,
                    processStartDate: helper.processStartDate,
                    identity: identity
                )
            }
            return ObservedRuntime(
                helper: helper,
                bundleURL: bundleURL,
                identity: verifiedIdentity
            )
        }
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
            let samePath = NativeAgentLauncher.observedRuntimes(
                dependencies.helpers(), identity: dependencies.identity
            ).filter { $0.bundleURL == expected.url }
            var unknown = [ObservedRuntime]()
            var incompatible = [ObservedRuntime]()
            var target: HelperTarget?
            for runtime in samePath {
                guard let identity = runtime.identity else {
                    unknown.append(runtime)
                    continue
                }
                if expected.isCompatible(identity, runtimeURL: runtime.bundleURL) {
                    if target == nil {
                        target = .running(
                            url: expected.url,
                            processIdentifier: runtime.helper.processIdentifier,
                            runtimeInstanceIdentifier: identity.instanceIdentifier
                        )
                    }
                } else {
                    incompatible.append(runtime)
                }
            }
            var mustWait = false
            var verifiedCurrentBundle = false
            func verifyBeforeQuit() async -> Bool {
                guard canContinue() else { return false }
                if !verifiedCurrentBundle {
                    guard await dependencies.validate(expected.url) else { return false }
                    verifiedCurrentBundle = true
                }
                return canContinue() && expected.installedVersionMatches
            }
            for runtime in unknown {
                let key = RuntimeProcessKey(runtime.helper)
                let firstObservedAt = unknownFirstObservedAt[key] ?? now
                unknownFirstObservedAt[key] = firstObservedAt
                let graceElapsed = now >= firstObservedAt &&
                    now - firstObservedAt >= 1_000_000_000
                if graceElapsed, !requestedQuit.contains(key) {
                    guard await verifyBeforeQuit() else { return nil }
                    if let identity = NativeAgentLauncher.verifiedRuntimeIdentity(
                        processIdentifier: runtime.helper.processIdentifier,
                        bundleURL: expected.url,
                        processStartDate: runtime.helper.processStartDate,
                        identity: dependencies.identity
                    ), expected.isCompatible(identity, runtimeURL: runtime.bundleURL) {
                        if target == nil {
                            target = .running(
                                url: expected.url,
                                processIdentifier: runtime.helper.processIdentifier,
                                runtimeInstanceIdentifier: identity.instanceIdentifier
                            )
                        }
                        continue
                    }
                    guard runtime.helper.isRunning() else {
                        mustWait = true
                        continue
                    }
                    requestedQuit.insert(key)
                    guard runtime.helper.requestQuit() else { return nil }
                }
                mustWait = true
            }
            for runtime in incompatible {
                let key = RuntimeProcessKey(runtime.helper)
                if !requestedQuit.contains(key) {
                    guard await verifyBeforeQuit() else { return nil }
                    if let identity = NativeAgentLauncher.verifiedRuntimeIdentity(
                        processIdentifier: runtime.helper.processIdentifier,
                        bundleURL: expected.url,
                        processStartDate: runtime.helper.processStartDate,
                        identity: dependencies.identity
                    ), expected.isCompatible(identity, runtimeURL: runtime.bundleURL) {
                        mustWait = true
                        continue
                    }
                    guard runtime.helper.isRunning() else {
                        mustWait = true
                        continue
                    }
                    requestedQuit.insert(key)
                    guard runtime.helper.requestQuit() else { return nil }
                }
                mustWait = true
            }
            guard canContinue() else { return nil }
            if mustWait {
                let remainingFrom = dependencies.uptime()
                guard remainingFrom < deadline else { return nil }
                await dependencies.wait(min(50_000_000, deadline - remainingFrom))
                continue
            }
            if let target { return target }
            guard canContinue() else { return nil }
            return .launch(url: expected.url, createsNewApplicationInstance: false)
        }
        return nil
    }

    @MainActor
    func approvalDeliveryStatus(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        isPending: @escaping () -> Bool
    ) async -> ExistingDeliveryStatus {
#if os(macOS)
        return await Self.reconcileReceipt(
            handle: handle, nonce: nativeDeliveryNonce,
            isPending: isPending, dependencies: dependencies
        )
#else
        return .terminal
#endif
    }

    @MainActor
    func hasCompatibleApprovalDelivery(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce
    ) async -> Bool {
        guard case .found(let snapshot) = await dependencies.load(handle),
              snapshot.nativeDeliveryNonce == nativeDeliveryNonce else { return false }
        if snapshot.phase == .responded { return true }
        guard snapshot.hasStagedOrActiveExecution,
              let receipt = snapshot.nativeDeliveryReceipt,
              receipt.nativeDeliveryNonce == nativeDeliveryNonce,
              case .compatible(.running(_, _, let runtimeInstanceIdentifier)) =
                await dependencies.receiptRuntimeStatus(receipt) else { return false }
        return runtimeInstanceIdentifier == receipt.owner.runtimeInstanceIdentifier
    }

    @MainActor
    func currentApprovalDeliveryStatus(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        timeoutNanoseconds: UInt64 = 250_000_000
    ) async -> ExistingDeliveryStatus {
        let deadline = dependencies.deadline(after: timeoutNanoseconds)
        return await approvalDeliveryStatus(
            handle: handle,
            nativeDeliveryNonce: nativeDeliveryNonce,
            isPending: { self.dependencies.uptime() < deadline }
        )
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
    ) async -> ReceiptRuntimeStatus {
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
    ) async -> ReceiptRuntimeStatus {
        switch observeReceiptOwner(receipt, helper: helper, identity: identity) {
        case .absent:
            return .absent
        case .indeterminate:
            return .indeterminate
        case .owner(let runtime):
            guard let runtimeURL = runtime.bundleURL,
                  let runtimeIdentity = runtime.identity else { return .indeterminate }
            if expected.isCompatible(
                runtimeIdentity,
                runtimeURL: runtimeURL
            ) {
                guard await verifyRuntime(
                    runtime,
                    expected: expected,
                    identity: identity,
                    validate: validate
                ) else { return .indeterminate }
                return .compatible(.running(
                    url: runtimeURL,
                    processIdentifier: runtime.helper.processIdentifier,
                    runtimeInstanceIdentifier: runtimeIdentity.instanceIdentifier
                ))
            }
            return .incompatible(ExactReceiptOwner(
                requestQuit: { isPending in
                    guard case .owner(let current) = observeReceiptOwner(
                        receipt, helper: helper, identity: identity
                    ), current.helper.processIdentifier == runtime.helper.processIdentifier,
                       current.identity == runtimeIdentity,
                       await verifyRuntime(
                        current,
                        expected: expected,
                        identity: identity,
                        validate: validate
                       ), isPending() else { return false }
                    return current.helper.requestQuit()
                },
                isRunning: runtime.helper.isRunning
            ))
        }
    }

    private static func observeReceiptOwner(
        _ receipt: ExtensionBridge.NativeDeliveryReceipt,
        helper: (Int32) -> RuntimeHelper?,
        identity: (Int32) -> AmbientRuntimeIdentity?
    ) -> ReceiptOwnerObservation {
        let owner = receipt.owner
        guard owner.isValid else { return .indeterminate }
        guard let runtime = helper(owner.processIdentifier), runtime.isRunning() else {
            return .absent
        }
        guard runtime.processIdentifier == owner.processIdentifier,
              let startDate = runtime.processStartDate else {
            return .indeterminate
        }
        guard AmbientRuntimeIdentity.matchesProcessStart(owner.processStartDate, startDate) else {
            return .absent
        }
        guard let runtimeURL = runtime.bundleURL,
              let runtimeIdentity = verifiedRuntimeIdentity(
                  processIdentifier: owner.processIdentifier,
                  bundleURL: runtimeURL,
                  processStartDate: startDate,
                  identity: identity
              ), runtimeIdentity.matches(owner) else { return .indeterminate }
        return .owner(ObservedRuntime(
            helper: runtime,
            bundleURL: runtimeURL,
            identity: runtimeIdentity
        ))
    }

    @MainActor
    private static func verifyRuntime(
        _ runtime: ObservedRuntime,
        expected: ExpectedRuntime,
        identity: (Int32) -> AmbientRuntimeIdentity?,
        validate: (URL) async -> Bool
    ) async -> Bool {
        guard let runtimeURL = runtime.bundleURL,
              let observedIdentity = runtime.identity,
              await validate(expected.url) else { return false }
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

#endif

    private func awaitResult(
        of task: Task<Bool, Never>,
        deadline: UInt64
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let resolution = LaunchResolution(continuation)
            let timeoutTask = Task {
                await dependencies.sleepUntil(deadline)
                guard !Task.isCancelled else { return }
                await resolution.finish(false)
            }
            Task {
                await resolution.install(timeoutTask: timeoutTask)
                let value = await task.value
                await resolution.finish(value)
            }
        }
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
        guard let runtime = observedRuntimes(
                  [helper],
                  identity: identity
              ).first,
              let runtimeIdentity = runtime.identity,
              expected.isCompatible(
                  runtimeIdentity,
                  runtimeURL: runtime.bundleURL
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

#if os(macOS)
    actor CodeValidator {
        private let check: @Sendable (URL, URL) -> Bool

        init(validate: @escaping @Sendable (URL, URL) -> Bool) {
            check = validate
        }

        func validate(helperURL: URL, extensionURL: URL) -> Bool {
            check(helperURL.standardizedFileURL, extensionURL.standardizedFileURL)
        }
    }

    private static func staticCode(at url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(),
            &code
        )
        guard status == errSecSuccess else {
            logger.error("Static code creation failed: \(status)")
            return nil
        }
        return code
    }

    private static func teamIdentifier(for code: SecStaticCode) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
                  code,
                  SecCSFlags(rawValue: kSecCSSigningInformation),
                  &information
              ) == errSecSuccess,
              let values = information as? [CFString: Any] else { return nil }
        return values[kSecCodeInfoTeamIdentifier] as? String
    }
#endif
}
