// ∅ 2026 lil org

import Foundation

@MainActor
final class NativeAgentLauncher {
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

    struct ExpectedRuntime {
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

    enum OwnerRetirementResult {
        case exited, reassess, unavailable
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
        let uptime: () -> UInt64
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
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    func expectedRuntime(at url: URL? = nil) -> ExpectedRuntime? {
        guard let url = url ?? dependencies.helperURL() else { return nil }
        return ExpectedRuntime(url: url)
    }

    func assess(
        owner: ExtensionBridge.NativeDeliveryOwner,
        expected: ExpectedRuntime
    ) -> RuntimeAssessment {
        assessRuntime(.receiptOwner(owner), expected: expected)
    }

    func status(
        owner: ExtensionBridge.NativeDeliveryOwner,
        expected: ExpectedRuntime
    ) async -> RuntimeAssessment {
        let assessment = assess(owner: owner, expected: expected)
        if case .compatible(let runtime) = assessment {
            guard await verify(runtime, expected: expected) else {
                return .unidentified(runtime.helper)
            }
        }
        return assessment
    }

    func retireVerifiedOwner(
        owner: ExtensionBridge.NativeDeliveryOwner,
        observedRuntime: IdentifiedRuntime,
        expected: ExpectedRuntime,
        deadline: UInt64
    ) async -> OwnerRetirementResult {
        guard !Task.isCancelled, dependencies.uptime() < deadline,
              expected.installedVersionMatches else { return .unavailable }
        switch assess(owner: owner, expected: expected) {
        case .absent:
            return .exited
        case .compatible:
            return .reassess
        case .incompatible(let current) where current.identity == observedRuntime.identity:
            guard requestQuit(current.helper, expected: expected, deadline: deadline),
                  await waitForExit(current, deadline: deadline) else {
                return .unavailable
            }
            return .exited
        case .incompatible, .unidentified:
            return .unavailable
        }
    }

    private func requestQuit(
        _ helper: RuntimeHelper,
        expected: ExpectedRuntime,
        deadline: UInt64
    ) -> Bool {
        guard !Task.isCancelled, dependencies.uptime() < deadline,
              expected.installedVersionMatches else { return false }
        return helper.requestQuit()
    }

    private func waitForExit(_ runtime: IdentifiedRuntime, deadline: UInt64) async -> Bool {
        while runtime.helper.isRunning(), !Task.isCancelled,
              dependencies.uptime() < deadline {
            await dependencies.wait(NativeApprovalTiming.launchPollIntervalNanoseconds)
        }
        return !Task.isCancelled && dependencies.uptime() < deadline
    }

    func isConfirmed(
        _ expected: ExpectedRuntime,
        deadline: UInt64
    ) async -> Bool {
#if os(macOS)
        for helper in dependencies.helpers() {
            guard !Task.isCancelled, dependencies.uptime() < deadline else { return false }
            if case .compatible(let runtime) = assessRuntime(.candidate(helper), expected: expected),
               await verify(runtime, expected: expected) {
                return !Task.isCancelled && dependencies.uptime() < deadline
            }
        }
#endif
        return false
    }

    func send(
        _ route: NativeAgentRoute,
        to selectedTarget: HelperTarget,
        deadline: UInt64
    ) async -> Bool {
        let dependencies = dependencies
        let isPending = { !Task.isCancelled && dependencies.uptime() < deadline }
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
                Task.detached { await resolution.resolve(delivered) }
            }
            return await resolution.value()
        } onCancel: {
            Task { await resolution.resolve(false) }
        }
    }

    private func assessRuntime(
        _ subject: RuntimeSubject,
        expected: ExpectedRuntime
    ) -> RuntimeAssessment {
        let runtime: RuntimeHelper
        let owner: ExtensionBridge.NativeDeliveryOwner?
        switch subject {
        case .candidate(let candidate):
            runtime = candidate
            owner = nil
        case .receiptOwner(let receiptOwner):
            guard receiptOwner.isValid else { return .unidentified(nil) }
            guard let candidate = dependencies.helper(receiptOwner.processIdentifier) else { return .absent }
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
                  identity: dependencies.identity
              ), owner.map({ observed.matches($0) }) ?? true else {
            return .unidentified(runtime)
        }
        let identified = IdentifiedRuntime(helper: runtime, identity: observed)
        return expected.isCompatible(observed, runtimeURL: url)
            ? .compatible(identified) : .incompatible(identified)
    }

    private func verifiedRuntimeIdentity(
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

    func resolveTarget(
        expected: ExpectedRuntime,
        deadline: UInt64
    ) async -> HelperTarget? {
        let dependencies = dependencies
        let canContinue = { !Task.isCancelled && dependencies.uptime() < deadline }
        guard canContinue() else { return nil }
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
                switch assessRuntime(.candidate(candidate), expected: expected) {
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
                switch assessRuntime(.candidate(candidate), expected: expected) {
                case .absent:
                    mustWait = true
                    continue
                case .compatible(let runtime):
                    if target == nil { target = runtime.target }
                case .incompatible, .unidentified:
                    mustWait = true
                    requestedQuit.insert(key)
                    guard requestQuit(candidate, expected: expected, deadline: deadline) else { return nil }
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

    func verify(
        _ runtime: IdentifiedRuntime,
        expected: ExpectedRuntime
    ) async -> Bool {
        let runtimeURL = runtime.target.url
        let observedIdentity = runtime.identity
        guard await dependencies.validate(expected.url) else { return false }
        if runtimeURL != expected.url {
            guard await dependencies.validate(runtimeURL) else { return false }
        }
        guard expected.installedVersionMatches,
              runtime.helper.isRunning(),
              verifiedRuntimeIdentity(
                  processIdentifier: runtime.helper.processIdentifier,
                  bundleURL: runtimeURL,
                  processStartDate: runtime.helper.processStartDate,
                  identity: dependencies.identity
              ) == observedIdentity else { return false }
        return true
    }
}
