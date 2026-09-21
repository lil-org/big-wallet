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
        let clearReceipt: (
            ExtensionBridge.Handle,
            ExtensionBridge.NativeDeliveryReceipt
        ) async -> ExtensionBridge.StoreMutationResult
        let uptime: () -> UInt64
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
        isPending: @escaping () -> Bool,
        dependencies: Dependencies
    ) async -> ExistingDeliveryStatus {
        while !Task.isCancelled, isPending() {
            let receipt: ExtensionBridge.NativeDeliveryReceipt
            switch await observeReceipt(
                handle: handle, nonce: nonce, isPending: isPending, dependencies: dependencies
            ) {
            case .owned(_, let current):
                receipt = current
            case .completed: return .delivered
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
                guard let url = dependencies.helperURL(), let expected = ExpectedRuntime(url: url),
                      await verifyRuntime(runtime, expected: expected,
                                          identity: dependencies.identity, validate: dependencies.validate),
                      !Task.isCancelled, isPending() else { return .unavailable }
                switch await observeReceipt(
                    handle: handle, nonce: nonce, isPending: isPending, dependencies: dependencies
                ) {
                case .owned(_, let current):
                    guard current == receipt else { continue }
                case .completed: return .delivered
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
                        await dependencies.wait(50_000_000)
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
                case .owned: continue
                case .completed: return .delivered
                case .unowned: return .needsDelivery
                case .terminal: return .terminal
                case .unavailable: return .unavailable
                }
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
        private var result: Bool?
        private var continuation: CheckedContinuation<Bool, Never>?

        func value() async -> Bool {
            if let result { return result }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func finish(_ succeeded: Bool) {
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
            let result = await self.boundedResult(of: operation, deadline: deliveryDeadline)
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
            return await awaitResult(of: delivery.task, deadline: callerDeadline)
        }
        return await delivery.task.value
    }

    enum ApprovalReadMode {
        case page, manualRecovery
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
                return await recoverExistingApprovalDelivery(
                    handle: handle,
                    nativeDeliveryNonce: snapshot.nativeDeliveryNonce
                )
            }
#if os(macOS)
            if case .queued(_, .delivered(let receipt)) = snapshot.state,
               receipt.nativeDeliveryNonce == snapshot.nativeDeliveryNonce,
               let url = dependencies.helperURL(),
               let expected = ExpectedRuntime(url: url),
               case .compatible = Self.assessRuntime(
                   .receiptOwner(receipt.owner), expected: expected,
                   helper: dependencies.helper, identity: dependencies.identity
               ),
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
        return await boundedResult(of: operation, deadline: deadline)
    }

    private func reactivateApproval(_ route: NativeAgentRoute, deadline: UInt64) async -> Bool {
        guard case .approval(_, let handle, let nativeDeliveryNonce) = route else { return false }
        let isPending = { !Task.isCancelled && self.dependencies.uptime() < deadline }
        switch await reconcileApprovalDelivery(
            handle: handle,
            nativeDeliveryNonce: nativeDeliveryNonce,
            waitDeadline: deadline
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
        let resolution = LaunchResolution()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled, isPending() else { return false }
            dependencies.launch(selectedTarget, route.url) { succeeded in
                let delivered = succeeded && isPending()
                Task { await resolution.finish(delivered) }
            }
            return await resolution.value()
        } onCancel: {
            Task { await resolution.finish(false) }
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
        case .launch(let helperURL):
            let configuration = applicationLaunchConfiguration()
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
    static func applicationLaunchConfiguration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.createsNewApplicationInstance = false
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
                    if now < firstObserved || now - firstObserved < 1_000_000_000 {
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
                await dependencies.wait(min(50_000_000, deadline - now))
                continue
            }
            return target ?? .launch(url: expected.url)
        }
        return nil
    }

    @MainActor
    func reconcileApprovalDelivery(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        waitDeadline: UInt64? = nil
    ) async -> ExistingDeliveryStatus {
#if os(macOS)
        let deadline = waitDeadline ?? dependencies.deadline(after: 250_000_000)
        return await Self.reconcileReceipt(
            handle: handle, nonce: nativeDeliveryNonce,
            isPending: { self.dependencies.uptime() < deadline }, dependencies: dependencies
        )
#else
        return .terminal
#endif
    }

    @MainActor
    func recoverExistingApprovalDelivery(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce
    ) async -> Bool {
        let receipt: ExtensionBridge.NativeDeliveryReceipt
        switch await Self.observeReceipt(
            handle: handle, nonce: nativeDeliveryNonce,
            isPending: { true }, dependencies: dependencies
        ) {
        case .owned(let snapshot, let current):
            guard snapshot.hasStagedOrActiveExecution else { return false }
            receipt = current
        case .completed: return true
        case .unowned, .terminal, .unavailable: return false
        }
        let assessment = await dependencies.receiptRuntimeStatus(receipt)
        guard !Task.isCancelled else { return false }
        switch assessment {
        case .compatible(let runtime):
            return runtime.identity.instanceIdentifier == receipt.owner.runtimeInstanceIdentifier
        case .absent:
            guard await dependencies.clearReceipt(handle, receipt) == .persisted,
                  case .completed = await Self.observeReceipt(
                      handle: handle, nonce: nativeDeliveryNonce,
                      isPending: { true }, dependencies: dependencies
                  ) else { return false }
            return true
        case .incompatible, .unidentified:
            return false
        }
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


    private func boundedResult(of task: Task<Bool, Never>, deadline: UInt64) async -> Bool {
        let resolution = LaunchResolution()
        return await withTaskCancellationHandler {
            let result = await awaitResult(of: task, deadline: deadline, resolution: resolution)
            task.cancel()
            return result
        } onCancel: {
            task.cancel()
            Task { await resolution.finish(false) }
        }
    }

    private func awaitResult(
        of task: Task<Bool, Never>,
        deadline: UInt64,
        resolution: LaunchResolution = LaunchResolution()
    ) async -> Bool {
        guard dependencies.uptime() < deadline else { return false }
        let timeoutTask = Task {
            await dependencies.sleepUntil(deadline)
            guard !Task.isCancelled else { return }
            await resolution.finish(false)
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
