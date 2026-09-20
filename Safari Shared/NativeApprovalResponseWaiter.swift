// ∅ 2026 lil org

import Foundation

@MainActor
struct NativeApprovalResponseWaiter {
    enum Result {
        case readyToRead, pending, deliveryUnavailable
    }

    private let launcher: NativeAgentLauncher
    private let load: (ExtensionBridge.Handle) async -> ExtensionBridge.SnapshotResult
    private let uptime: () -> UInt64
    private let wallClock: () -> Date
    private let sleepUntil: (UInt64) async -> Void

    init(
        launcher: NativeAgentLauncher = .live,
        load: @escaping (ExtensionBridge.Handle) async -> ExtensionBridge.SnapshotResult = {
            ExtensionBridge.shared.load(handle: $0)
        },
        uptime: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        wallClock: @escaping () -> Date = Date.init,
        sleepUntil: @escaping (UInt64) async -> Void = { deadline in
            let now = DispatchTime.now().uptimeNanoseconds
            if deadline > now { try? await Task.sleep(nanoseconds: deadline - now) }
        }
    ) {
        self.launcher = launcher
        self.load = load
        self.uptime = uptime
        self.wallClock = wallClock
        self.sleepUntil = sleepUntil
    }

    func waitForResponse(
        handle: ExtensionBridge.Handle,
        configurationKey: String,
        initialContext: ExtensionBridge.NativeExecutionContext,
        mode: NativeAgentLauncher.ApprovalReadMode
    ) async -> Result {
        guard await launcher.ensureApprovalDelivery(
            handle: handle,
            mode: mode
        ) else { return .deliveryUnavailable }
        let startedAt = uptime()
        let deadline = startedAt.addingReportingOverflow(170_000_000_000).partialValue
        var nextDeliveryCheck = startedAt
        if wallClock() >= initialContext.executionDeadline { return .pending }
        while !Task.isCancelled, uptime() < deadline {
            switch await load(handle) {
            case .found(let snapshot):
                guard snapshot.configurationKey == configurationKey,
                      snapshot.phase != .responded else { return .readyToRead }
                if snapshot.phase == .queued,
                   wallClock() >= initialContext.executionDeadline {
                    return .pending
                }
                let now = uptime()
                if case .queued(_, .staged) = snapshot.state,
                   now >= nextDeliveryCheck {
                    guard await launcher.ensureApprovalDelivery(
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
            let wake = uptime().addingReportingOverflow(250_000_000)
            await sleepUntil(wake.overflow ? UInt64.max : wake.partialValue)
        }
        return .pending
    }

}
