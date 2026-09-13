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
    typealias Confirm = (
        URL,
        NativeAgentRoute,
        UInt64,
        @escaping () -> Bool
    ) async -> Bool
    typealias HelperResolution = (
        URL,
        UInt64,
        @escaping () -> Bool
    ) async -> HelperTarget?
    typealias ExistingDelivery = (
        NativeAgentRoute,
        @escaping () -> Bool
    ) async -> ExistingDeliveryStatus

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
        let requestQuit: (_ isPending: () -> Bool) -> Bool
        let isRunning: () -> Bool
    }

    enum ReceiptRuntimeStatus {
        case compatible(HelperTarget)
        case incompatible(ExactReceiptOwner), absent, indeterminate
    }

    struct ApprovalDeliveryDependencies {
        let load: (ExtensionBridge.Handle) async ->
            ExtensionBridge.SnapshotResult
        let receiptRuntimeStatus: @MainActor (
            ExtensionBridge.NativeDeliveryReceipt
        ) -> ReceiptRuntimeStatus
        let clearReceipt: (
            ExtensionBridge.Handle,
            ExtensionBridge.NativeDeliveryReceipt
        ) async -> ExtensionBridge.StoreMutationResult
        let wait: (UInt64) async -> Void

        init(
            load: @escaping (ExtensionBridge.Handle) async ->
                ExtensionBridge.SnapshotResult,
            runtimeStatus: @escaping @MainActor (UUID) ->
                ReceiptRuntimeStatus,
            clearReceipt: @escaping (
                ExtensionBridge.Handle,
                ExtensionBridge.NativeDeliveryReceipt
            ) async -> ExtensionBridge.StoreMutationResult,
            wait: @escaping (UInt64) async -> Void
        ) {
            self.load = load
            receiptRuntimeStatus = {
                runtimeStatus($0.runtimeInstanceIdentifier)
            }
            self.clearReceipt = clearReceipt
            self.wait = wait
        }

        init(
            load: @escaping (ExtensionBridge.Handle) async ->
                ExtensionBridge.SnapshotResult,
            receiptRuntimeStatus: @escaping @MainActor (
                ExtensionBridge.NativeDeliveryReceipt
            ) -> ReceiptRuntimeStatus,
            clearReceipt: @escaping (
                ExtensionBridge.Handle,
                ExtensionBridge.NativeDeliveryReceipt
            ) async -> ExtensionBridge.StoreMutationResult,
            wait: @escaping (UInt64) async -> Void
        ) {
            self.load = load
            self.receiptRuntimeStatus = receiptRuntimeStatus
            self.clearReceipt = clearReceipt
            self.wait = wait
        }

        static let live = ApprovalDeliveryDependencies(
            load: { await ExtensionBridge.shared.load(handle: $0) },
            receiptRuntimeStatus: { receipt in
#if os(macOS)
                NativeAgentLauncher.runtimeStatus(
                    receipt: receipt
                )
#else
                .indeterminate
#endif
            },
            clearReceipt: { handle, receipt in
                await ExtensionBridge.shared.clearNativeDeliveryReceipt(
                    handle: handle,
                    nativeDeliveryNonce: receipt.nativeDeliveryNonce,
                    runtimeInstanceIdentifier:
                        receipt.runtimeInstanceIdentifier
                )
            },
            wait: { try? await Task.sleep(nanoseconds: $0) }
        )
    }

    private struct SharedDelivery {
        let identifier: UUID
        let route: NativeAgentRoute
        let task: Task<Bool, Never>
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

    static let live = NativeAgentLauncher(
        helperURL: embeddedHelperURL,
        validate: validateEmbeddedHelper,
        resolveHelper: { helperURL, deadline, isPending in
            await resolveTargetHelper(
                currentURL: helperURL,
                deadline: deadline,
                isPending: isPending
            )
        },
        confirm: { helperURL, route, deadline, isPending in
            await confirmDelivery(
                to: helperURL,
                route: route,
                deadline: deadline,
                isPending: isPending
            )
        },
        existingDelivery: { route, isPending in
            await existingDeliveryStatus(
                route: route,
                isPending: isPending
            )
        },
        launch: launchApplication
    )

    private let helperURL: () -> URL?
    private let validate: (URL) -> Bool
    private let resolveHelper: HelperResolution
    private let confirm: Confirm
    private let existingDelivery: ExistingDelivery
    private let launch: Launch
    private let launchTimeoutNanoseconds: UInt64
    private var sharedDeliveries = [SharedDelivery]()
    private var deliveryTail: Task<Void, Never>?
    private var deliveryTailIdentifier: UUID?
    init(
        helperURL: @escaping () -> URL?,
        validate: @escaping (URL) -> Bool,
        resolveHelper: @escaping HelperResolution = { url, _, _ in
            .launch(url: url, createsNewApplicationInstance: false)
        },
        confirm: @escaping Confirm = { _, _, _, _ in true },
        existingDelivery: @escaping ExistingDelivery = { _, _ in
            .needsDelivery
        },
        launchTimeoutNanoseconds: UInt64 = 5_000_000_000,
        launch: @escaping Launch
    ) {
        self.helperURL = helperURL
        self.validate = validate
        self.resolveHelper = resolveHelper
        self.confirm = confirm
        self.existingDelivery = existingDelivery
        self.launch = launch
        self.launchTimeoutNanoseconds = launchTimeoutNanoseconds
    }

    func open(_ route: NativeAgentRoute) async -> Bool {
        let callerDeadline = Self.deadline(
            afterNanoseconds: launchTimeoutNanoseconds
        )
        while let shared = sharedDeliveries.first(where: {
            $0.route == route
        }) {
            if await Self.awaitResult(
                of: shared.task,
                deadline: callerDeadline
            ) {
                return true
            }
            guard Self.isPending(deadline: callerDeadline) else { return false }
            finishSharedDelivery(identifier: shared.identifier)
        }
        let identifier = UUID()
        let precedingDelivery = deliveryTail
        let task = Task { [weak self] in
            await precedingDelivery?.value
            guard let self else { return false }
            return await self.runQueuedDelivery(route)
        }
        sharedDeliveries.append(SharedDelivery(
            identifier: identifier,
            route: route,
            task: task
        ))
        deliveryTail = Task { _ = await task.value }
        deliveryTailIdentifier = identifier
        Task { [weak self] in
            _ = await task.value
            await self?.finishSharedDelivery(identifier: identifier)
        }
        return await Self.awaitResult(of: task, deadline: callerDeadline)
    }

    func reactivate(
        _ route: NativeAgentRoute,
        dependencies: ApprovalDeliveryDependencies = .live
    ) async -> Bool {
        guard case .approval(_, let handle, let nativeDeliveryNonce) = route else {
            return false
        }
        let deadline = Self.deadline(
            afterNanoseconds: launchTimeoutNanoseconds
        )
        let isPending = { Self.isPending(deadline: deadline) }
        switch await Self.approvalDeliveryStatus(
            handle: handle,
            nativeDeliveryNonce: nativeDeliveryNonce,
            isPending: isPending,
            dependencies: dependencies
        ) {
        case .needsDelivery:
            return isPending() ? await open(route) : false
        case .delivered:
            break
        case .terminal, .unavailable:
            return false
        }
        guard isPending(),
              case .found(let snapshot) = await dependencies.load(handle),
              snapshot.nativeDeliveryNonce == nativeDeliveryNonce,
              snapshot.phase == .queued,
              !snapshot.nativeDecisionStaged,
              let receipt = snapshot.nativeDeliveryReceipt,
              receipt.nativeDeliveryNonce == nativeDeliveryNonce,
              case .compatible(let target) = await dependencies
                .receiptRuntimeStatus(receipt),
              case .running(_, _, let runtimeInstanceIdentifier) = target,
              runtimeInstanceIdentifier == receipt.runtimeInstanceIdentifier else {
            return false
        }
        return await launchOnce(route: route, to: target, deadline: deadline)
    }

    private func runQueuedDelivery(_ route: NativeAgentRoute) async -> Bool {
        let deliveryDeadline = Self.deadline(
            afterNanoseconds: launchTimeoutNanoseconds
        )
        return await deliver(route, deadline: deliveryDeadline)
    }

    private func finishSharedDelivery(identifier: UUID) {
        sharedDeliveries.removeAll { $0.identifier == identifier }
        if deliveryTailIdentifier == identifier {
            deliveryTail = nil
            deliveryTailIdentifier = nil
        }
    }

    private func deliver(
        _ route: NativeAgentRoute,
        deadline: UInt64
    ) async -> Bool {
        for attempt in 0..<3 {
            guard Self.isPending(deadline: deadline) else { return false }
            switch await preflight(route: route, deadline: deadline) {
            case .delivered:
                return true
            case .terminal, .unavailable:
                return false
            case .needsDelivery:
                break
            }
            guard let target = await prepareHelper(deadline: deadline) else {
                return false
            }
            guard await launchOnce(
                route: route,
                to: target,
                deadline: deadline
            ) else { continue }
            let confirmationDeadline = attempt == 2 ? deadline : min(
                deadline,
                Self.deadline(afterNanoseconds: 250_000_000)
            )
            guard await confirm(
                      target.url,
                      route,
                      confirmationDeadline,
                      { Self.isPending(deadline: deadline) }
                  ) else { continue }
            return true
        }
        return false
    }

    private func preflight(
        route: NativeAgentRoute,
        deadline: UInt64
    ) async -> ExistingDeliveryStatus {
        let isPending = { Self.isPending(deadline: deadline) }
        guard isPending() else { return .unavailable }
        return await existingDelivery(route, isPending)
    }

    private func prepareHelper(deadline: UInt64) async -> HelperTarget? {
        let isPending = { Self.isPending(deadline: deadline) }
        guard isPending(), let helperURL = helperURL(),
              let selectedTarget = await resolveHelper(
                  helperURL,
                  deadline,
                  isPending
              ), isPending() else {
            return nil
        }
        return selectedTarget
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
            validate: validate,
            launch: launch
        )
    }

    @MainActor
    private static func performLaunch(
        route: NativeAgentRoute,
        to selectedTarget: HelperTarget,
        deadline: UInt64,
        validate: @escaping (URL) -> Bool,
        launch: @escaping Launch
    ) async -> Bool {
        let isPending = { Self.isPending(deadline: deadline) }
        guard isPending(), validate(selectedTarget.url), isPending() else {
            return false
        }
        return await withCheckedContinuation { continuation in
            let launchResolution = LaunchResolution(continuation)
            let timeoutTask = Task {
                await Self.waitUntil(deadline: deadline)
                guard !Task.isCancelled else { return }
                await launchResolution.finish(false)
            }
            Task { await launchResolution.install(timeoutTask: timeoutTask) }
            launch(selectedTarget, route.url) { succeeded in
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

    private static func validateEmbeddedHelper(_ url: URL) -> Bool {
#if os(macOS)
        let extensionURL = Bundle.main.bundleURL
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
#else
        return false
#endif
    }

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
            guard let expectedVersion = AmbientRuntimeIdentity.bundleVersion(
                      at: helperURL
                  ),
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
                  identity.isCompatible(
                      withWorkflowVersion: ExtensionBridge.workflowVersion,
                      expectedVersion: expectedVersion
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

    @MainActor
    private static func resolveTargetHelper(
        currentURL helperURL: URL,
        deadline: UInt64,
        isPending: @escaping () -> Bool
    ) async -> HelperTarget? {
#if os(macOS)
        return await resolveTargetHelper(
            currentURL: helperURL,
            deadline: deadline,
            isPending: isPending,
            helpers: runningHelpers,
            identity: { processIdentifier in
                AmbientRuntimeIdentity.load(
                    processIdentifier: processIdentifier
                )
            },
            validate: validateEmbeddedHelper
        )
#else
        return nil
#endif
    }

#if os(macOS)
    private static func runningHelpers() -> [RuntimeHelper] {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: "org.lil.wallet.ambient"
        ).map { application in
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
        helpers: @escaping () -> [RuntimeHelper],
        identity: @escaping (Int32) -> AmbientRuntimeIdentity?,
        validate: @escaping (URL) -> Bool,
        uptime: @escaping () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        sleep: @escaping (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) async -> HelperTarget? {
        let currentURL = currentURL.standardizedFileURL
        guard let expectedVersion = AmbientRuntimeIdentity.bundleVersion(
                  at: currentURL
              ) else { return nil }
        let identityStartupGraceNanoseconds: UInt64 = 1_000_000_000
        var unknownFirstObservedAt = [RuntimeProcessKey: UInt64]()
        var requestedQuit = Set<RuntimeProcessKey>()
        while true {
            let monotonicNow = uptime()
            guard !Task.isCancelled,
                  isPending(), monotonicNow < deadline else { return nil }
            let samePath = observedRuntimes(
                helpers(),
                identity: identity
            ).filter {
                $0.bundleURL == currentURL
            }
            var unknownRuntimes = [ObservedRuntime]()
            var compatibleTarget: HelperTarget?
            var incompatibleRuntimes = [ObservedRuntime]()
            for runtime in samePath {
                guard let runtimeIdentity = runtime.identity else {
                    unknownRuntimes.append(runtime)
                    continue
                }
                if runtimeIdentity.isCompatible(
                    withWorkflowVersion: ExtensionBridge.workflowVersion,
                    expectedVersion: expectedVersion
                ) {
                    if compatibleTarget == nil {
                        compatibleTarget = .running(
                            url: currentURL,
                            processIdentifier:
                                runtime.helper.processIdentifier,
                            runtimeInstanceIdentifier:
                                runtimeIdentity.instanceIdentifier
                        )
                    }
                } else {
                    incompatibleRuntimes.append(runtime)
                }
            }
            var mustWait = false
            var verifiedCurrentBundle = false
            func verifyBeforeQuit() -> Bool {
                guard isPending() else { return false }
                if !verifiedCurrentBundle {
                    guard validate(currentURL) else { return false }
                    verifiedCurrentBundle = true
                }
                return isPending() && AmbientRuntimeIdentity.bundleVersion(
                    at: currentURL
                ) == expectedVersion
            }
            for runtime in unknownRuntimes {
                let key = RuntimeProcessKey(runtime.helper)
                let firstObservedAt = unknownFirstObservedAt[key] ??
                    monotonicNow
                unknownFirstObservedAt[key] = firstObservedAt
                let graceElapsed = monotonicNow >= firstObservedAt &&
                    monotonicNow - firstObservedAt >=
                        identityStartupGraceNanoseconds
                if graceElapsed, !requestedQuit.contains(key) {
                    guard verifyBeforeQuit() else { return nil }
                    let refreshedIdentity = verifiedRuntimeIdentity(
                        processIdentifier:
                            runtime.helper.processIdentifier,
                        bundleURL: currentURL,
                        processStartDate:
                            runtime.helper.processStartDate,
                        identity: identity
                    )
                    if let refreshedIdentity,
                       refreshedIdentity.isCompatible(
                           withWorkflowVersion:
                               ExtensionBridge.workflowVersion,
                           expectedVersion: expectedVersion
                       ) {
                        if compatibleTarget == nil {
                            compatibleTarget = .running(
                                url: currentURL,
                                processIdentifier:
                                    runtime.helper.processIdentifier,
                                runtimeInstanceIdentifier:
                                    refreshedIdentity.instanceIdentifier
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
            for runtime in incompatibleRuntimes {
                let key = RuntimeProcessKey(runtime.helper)
                if !requestedQuit.contains(key) {
                    guard verifyBeforeQuit() else { return nil }
                    if let refreshedIdentity = verifiedRuntimeIdentity(
                        processIdentifier: runtime.helper.processIdentifier,
                        bundleURL: currentURL,
                        processStartDate: runtime.helper.processStartDate,
                        identity: identity
                    ), refreshedIdentity.isCompatible(
                        withWorkflowVersion: ExtensionBridge.workflowVersion,
                        expectedVersion: expectedVersion
                    ) {
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
            if mustWait {
                await sleep(min(50_000_000, deadline - monotonicNow))
                continue
            }
            if let compatibleTarget { return compatibleTarget }
            guard isPending() else { return nil }
            return .launch(
                url: currentURL,
                createsNewApplicationInstance: false
            )
        }
    }

    @MainActor
    private static func confirmDelivery(
        to helperURL: URL,
        route: NativeAgentRoute,
        deadline: UInt64,
        isPending: @escaping () -> Bool
    ) async -> Bool {
        switch route {
        case .showWallet:
            return await confirmRuntimeHelper(
                helperURL,
                deadline: deadline,
                isPending: isPending
            )
        case .approval(
            _,
            let handle,
            let nativeDeliveryNonce
        ):
            return await confirmApprovalDelivery(
                handle: handle,
                nativeDeliveryNonce: nativeDeliveryNonce,
                deadline: deadline,
                isPending: isPending
            )
        }
    }

    @MainActor
    private static func confirmApprovalDelivery(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        deadline: UInt64,
        isPending: @escaping () -> Bool
    ) async -> Bool {
#if os(macOS)
        while isPending(), DispatchTime.now().uptimeNanoseconds < deadline {
            switch await approvalDeliveryStatus(
                handle: handle,
                nativeDeliveryNonce: nativeDeliveryNonce,
                isPending: isPending
            ) {
            case .delivered:
                return true
            case .terminal:
                return false
            case .needsDelivery, .unavailable:
                break
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard isPending(), now < deadline else { return false }
            do {
                try await Task.sleep(
                    nanoseconds: min(50_000_000, deadline - now)
                )
            } catch {
                return false
            }
        }
        return false
#else
        return false
#endif
    }

    @MainActor
    private static func existingDeliveryStatus(
        route: NativeAgentRoute,
        isPending: @escaping () -> Bool
    ) async -> ExistingDeliveryStatus {
        guard case .approval(
                  _,
                  let handle,
                  let nativeDeliveryNonce
              ) = route else {
            return .needsDelivery
        }
        return await approvalDeliveryStatus(
            handle: handle,
            nativeDeliveryNonce: nativeDeliveryNonce,
            isPending: isPending
        )
    }

    @MainActor
    static func approvalDeliveryStatus(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        isPending: @escaping () -> Bool,
        dependencies: ApprovalDeliveryDependencies = .live
    ) async -> ExistingDeliveryStatus {
#if os(macOS)
        while isPending() {
            let receipt: ExtensionBridge.NativeDeliveryReceipt
            switch await dependencies.load(handle) {
            case .found(let snapshot):
                guard snapshot.nativeDeliveryNonce == nativeDeliveryNonce else {
                    return .terminal
                }
                if snapshot.phase == .responded {
                    return .delivered
                }
                guard let currentReceipt = snapshot.nativeDeliveryReceipt else {
                    return .needsDelivery
                }
                guard currentReceipt.nativeDeliveryNonce ==
                        nativeDeliveryNonce else {
                    return .terminal
                }
                receipt = currentReceipt
            case .missing:
                return .terminal
            case .unavailable:
                return .unavailable
            }

            switch dependencies.receiptRuntimeStatus(receipt) {
            case .compatible:
                return isPending() ? .delivered : .unavailable
            case .incompatible(let helper):
                switch await dependencies.load(handle) {
                case .found(let current):
                    if current.phase == .responded {
                        return .delivered
                    }
                    guard current.nativeDeliveryNonce == nativeDeliveryNonce,
                          current.nativeDeliveryReceipt == receipt else {
                        continue
                    }
                case .missing:
                    return .terminal
                case .unavailable:
                    return .unavailable
                }
                guard isPending(), helper.requestQuit(isPending) else {
                    return .unavailable
                }
                while helper.isRunning() {
                    guard isPending() else { return .unavailable }
                    await dependencies.wait(50_000_000)
                }
            case .absent:
                break
            case .indeterminate:
                return .unavailable
            }

            guard isPending() else { return .unavailable }
            switch await dependencies.clearReceipt(handle, receipt) {
            case .persisted:
                return .needsDelivery
            case .ownershipLost:
                continue
            case .retryablePersistenceFailure:
                return .unavailable
            }
        }
        return .unavailable
#else
        return .terminal
#endif
    }

    @MainActor
    static func hasCompatibleApprovalDelivery(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        dependencies: ApprovalDeliveryDependencies = .live
    ) async -> Bool {
        guard case .found(let snapshot) = await dependencies.load(handle),
              snapshot.nativeDeliveryNonce == nativeDeliveryNonce else { return false }
        if snapshot.phase == .responded { return true }
        guard snapshot.nativeDecisionStaged || snapshot.phase == .approving,
              let receipt = snapshot.nativeDeliveryReceipt,
              receipt.nativeDeliveryNonce == nativeDeliveryNonce,
              case .compatible(.running(_, _, let runtimeInstanceIdentifier)) =
                dependencies.receiptRuntimeStatus(receipt) else { return false }
        return runtimeInstanceIdentifier == receipt.runtimeInstanceIdentifier
    }

    @MainActor
    static func currentApprovalDeliveryStatus(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        timeoutNanoseconds: UInt64 = 250_000_000,
        dependencies: ApprovalDeliveryDependencies = .live
    ) async -> ExistingDeliveryStatus {
        let deadline = Self.deadline(afterNanoseconds: timeoutNanoseconds)
        return await approvalDeliveryStatus(
            handle: handle,
            nativeDeliveryNonce: nativeDeliveryNonce,
            isPending: { Self.isPending(deadline: deadline) },
            dependencies: dependencies
        )
    }

#if os(macOS)
    @MainActor
    private static func runtimeStatus(
        receipt: ExtensionBridge.NativeDeliveryReceipt
    ) -> ReceiptRuntimeStatus {
        guard let expectedURL = embeddedHelperURL()?.standardizedFileURL,
              let expectedVersion = AmbientRuntimeIdentity.bundleVersion(
                  at: expectedURL
              ) else { return .indeterminate }
        return runtimeStatus(
            receipt: receipt,
            expectedURL: expectedURL,
            expectedVersion: expectedVersion,
            helpers: runningHelpers,
            identity: { AmbientRuntimeIdentity.load(processIdentifier: $0) },
            validate: validateEmbeddedHelper
        )
    }

    @MainActor
    static func runtimeStatus(
        receipt: ExtensionBridge.NativeDeliveryReceipt,
        expectedURL: URL,
        expectedVersion: AmbientRuntimeIdentity.Version,
        helpers: @escaping () -> [RuntimeHelper],
        identity: @escaping (Int32) -> AmbientRuntimeIdentity?,
        validate: @escaping (URL) -> Bool
    ) -> ReceiptRuntimeStatus {
        let expectedURL = expectedURL.standardizedFileURL
        switch observeReceiptOwner(receipt, helpers: helpers, identity: identity) {
        case .absent:
            return .absent
        case .indeterminate:
            return .indeterminate
        case .owner(let runtime):
            guard let runtimeURL = runtime.bundleURL,
                  let runtimeIdentity = runtime.identity else { return .indeterminate }
            if isCompatibleRuntimeIdentity(
                runtimeIdentity,
                runtimeURL: runtimeURL,
                expectedURL: expectedURL,
                expectedVersion: expectedVersion
            ) {
                guard verifyRuntime(
                    runtime,
                    expectedURL: expectedURL,
                    expectedVersion: expectedVersion,
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
                        receipt, helpers: helpers, identity: identity
                    ), current.helper.processIdentifier == runtime.helper.processIdentifier,
                       current.identity == runtimeIdentity,
                       verifyRuntime(
                        current,
                        expectedURL: expectedURL,
                        expectedVersion: expectedVersion,
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
        helpers: () -> [RuntimeHelper],
        identity: (Int32) -> AmbientRuntimeIdentity?
    ) -> ReceiptOwnerObservation {
        guard receipt.owner?.isValid ?? true else { return .indeterminate }
        var hasPossibleUnidentifiedOwner = false
        var owner: ObservedRuntime?
        for runtime in observedRuntimes(helpers(), identity: identity) {
            guard let runtimeURL = runtime.bundleURL else {
                hasPossibleUnidentifiedOwner = true
                continue
            }
            guard let identity = runtime.identity else {
                if receipt.owner == nil || receipt.owner?.bundleURL == runtimeURL {
                    hasPossibleUnidentifiedOwner = true
                }
                continue
            }
            guard identity.instanceIdentifier == receipt.runtimeInstanceIdentifier else {
                continue
            }
            guard owner == nil,
                  receipt.owner.map(identity.matches) ?? true else {
                return .indeterminate
            }
            owner = runtime
        }
        if let owner { return .owner(owner) }
        return hasPossibleUnidentifiedOwner ? .indeterminate : .absent
    }

    private static func verifyRuntime(
        _ runtime: ObservedRuntime,
        expectedURL: URL,
        expectedVersion: AmbientRuntimeIdentity.Version,
        identity: (Int32) -> AmbientRuntimeIdentity?,
        validate: (URL) -> Bool
    ) -> Bool {
        guard let runtimeURL = runtime.bundleURL,
              let observedIdentity = runtime.identity,
              validate(expectedURL),
              runtimeURL == expectedURL || validate(runtimeURL),
              AmbientRuntimeIdentity.bundleVersion(at: expectedURL) == expectedVersion,
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

    @MainActor
    private static func confirmRuntimeHelper(
        _ helperURL: URL,
        deadline: UInt64,
        isPending: @escaping () -> Bool
    ) async -> Bool {
#if os(macOS)
        let helperURL = helperURL.standardizedFileURL
        guard let expectedVersion = AmbientRuntimeIdentity.bundleVersion(
            at: helperURL
        ) else { return false }
        repeat {
            for helper in runningHelpers() {
                if isConfirmedRuntimeHelper(
                    helper,
                    expectedURL: helperURL,
                    expectedVersion: expectedVersion,
                    identity: { AmbientRuntimeIdentity.load(processIdentifier: $0) },
                    validate: validateEmbeddedHelper
                ) {
                    return isPending()
                }
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard isPending(), now < deadline else { return false }
            let remaining = deadline - now
            do {
                try await Task.sleep(nanoseconds: min(50_000_000, remaining))
            } catch {
                return false
            }
        } while isPending() && DispatchTime.now().uptimeNanoseconds < deadline
        return false
#else
        return false
#endif
    }

    private static func awaitResult(
        of task: Task<Bool, Never>,
        deadline: UInt64
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let resolution = LaunchResolution(continuation)
            let timeoutTask = Task {
                await waitUntil(deadline: deadline)
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

    private static func waitUntil(deadline: UInt64) async {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline > now else { return }
        try? await Task.sleep(nanoseconds: deadline - now)
    }

    private static func isPending(deadline: UInt64) -> Bool {
        DispatchTime.now().uptimeNanoseconds < deadline
    }

    private static func deadline(afterNanoseconds interval: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        let result = now.addingReportingOverflow(interval)
        return result.overflow ? UInt64.max : result.partialValue
    }

    static func isConfirmedRuntimeHelper(
        _ helper: RuntimeHelper,
        expectedURL: URL,
        expectedVersion: AmbientRuntimeIdentity.Version? = nil,
        identity: (Int32) -> AmbientRuntimeIdentity?,
        validate: (URL) -> Bool
    ) -> Bool {
        let expectedURL = expectedURL.standardizedFileURL
        guard let runtime = observedRuntimes(
                  [helper],
                  identity: identity
              ).first,
              runtime.bundleURL == expectedURL,
              let expectedVersion = expectedVersion ?? AmbientRuntimeIdentity.bundleVersion(
                  at: expectedURL
              ),
              let runtimeIdentity = runtime.identity,
              runtimeIdentity.isCompatible(
                  withWorkflowVersion: ExtensionBridge.workflowVersion,
                  expectedVersion: expectedVersion
              ) else { return false }
#if os(macOS)
        return verifyRuntime(
            runtime,
            expectedURL: expectedURL,
            expectedVersion: expectedVersion,
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
        let expectedURL = expectedURL.standardizedFileURL
        guard runtimeURL.standardizedFileURL == expectedURL,
              let expectedVersion = expectedVersion ??
                AmbientRuntimeIdentity.bundleVersion(at: expectedURL) else {
            return false
        }
        return identity.isCompatible(
            withWorkflowVersion: ExtensionBridge.workflowVersion,
            expectedVersion: expectedVersion
        )
    }

#if os(macOS)
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
