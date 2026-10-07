import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class SecretClipboard: NSObject {
    typealias Schedule = @MainActor (Duration, @escaping @MainActor () -> Void) -> (@MainActor () -> Void)

    @MainActor
    private final class TimerAction: NSObject {
        private let action: @MainActor () -> Void

        init(_ action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        @objc func fire(_ timer: Timer) {
            action()
        }
    }

    @MainActor
    enum Pasteboard {
        case systemManaged(write: @MainActor (String, Date) -> Void)
        case applicationManaged(
            write: @MainActor (String) -> Int?,
            changeCount: @MainActor () -> Int,
            clear: @MainActor () -> Void
        )

        #if os(macOS)
        static func macOS(
            prepare: @escaping @MainActor (NSPasteboard.ContentsOptions) -> Int,
            setString: @escaping @MainActor (String) -> Bool,
            changeCount: @escaping @MainActor () -> Int,
            clear: @escaping @MainActor () -> Void
        ) -> Self {
            .applicationManaged(
                write: { secret in
                    let ownership = prepare(.currentHostOnly)
                    guard setString(secret) else { return nil }
                    return ownership
                },
                changeCount: changeCount,
                clear: clear
            )
        }

        static var general: Self {
            let pasteboard = NSPasteboard.general
            return macOS(
                prepare: { pasteboard.prepareForNewContents(with: $0) },
                setString: { pasteboard.setString($0, forType: .string) },
                changeCount: { pasteboard.changeCount },
                clear: { pasteboard.clearContents() }
            )
        }
        #else
        static func uiKit(
            setItems: @escaping @MainActor ([[String: Any]], [UIPasteboard.OptionsKey: Any]) -> Void
        ) -> Self {
            .systemManaged { secret, deadline in
                setItems(
                    [[UIPasteboard.typeAutomatic: secret]],
                    [.localOnly: true, .expirationDate: deadline]
                )
            }
        }

        static var general: Self {
            let pasteboard = UIPasteboard.general
            return uiKit(setItems: { pasteboard.setItems($0, options: $1) })
        }
        #endif
    }

    private struct Copy {
        let identifier = UUID()
        let ownership: Int
        let deadline: ContinuousClock.Instant
    }

    static let lifetime: TimeInterval = 30
    static let shared = SecretClipboard()

    private let pasteboard: Pasteboard
    private let now: @MainActor () -> Date
    private let monotonicNow: @MainActor () -> ContinuousClock.Instant
    private let schedule: Schedule
    private let applicationNotifications: NotificationCenter?
    private let workspaceNotifications: NotificationCenter?
    private var currentCopy: Copy?
    private var cancelExpiration: (@MainActor () -> Void)?

    private override convenience init() {
        #if os(macOS)
        self.init(
            pasteboard: .general,
            applicationNotifications: .default,
            workspaceNotifications: NSWorkspace.shared.notificationCenter
        )
        #else
        self.init(pasteboard: .general, applicationNotifications: .default)
        #endif
    }

    init(
        pasteboard: Pasteboard,
        now: @escaping @MainActor () -> Date = Date.init,
        monotonicNow: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock().now },
        schedule: @escaping Schedule = SecretClipboard.scheduleOnMainRunLoop,
        applicationNotifications: NotificationCenter? = nil,
        workspaceNotifications: NotificationCenter? = nil
    ) {
        self.pasteboard = pasteboard
        self.now = now
        self.monotonicNow = monotonicNow
        self.schedule = schedule
        self.applicationNotifications = applicationNotifications
        self.workspaceNotifications = workspaceNotifications
        super.init()

        #if os(macOS)
        let termination = NSApplication.willTerminateNotification
        let activation = NSApplication.didBecomeActiveNotification
        workspaceNotifications?.addObserver(
            self, selector: #selector(recheckExpiration), name: NSWorkspace.didWakeNotification, object: nil
        )
        #else
        let termination = UIApplication.willTerminateNotification
        let activation = UIApplication.didBecomeActiveNotification
        #endif
        applicationNotifications?.addObserver(
            self, selector: #selector(clearForTermination), name: termination, object: nil
        )
        applicationNotifications?.addObserver(
            self, selector: #selector(recheckExpiration), name: activation, object: nil
        )
    }

    func copy(_ secret: String) {
        retireCopy()
        let ownership: Int
        let deadline: ContinuousClock.Instant
        switch pasteboard {
        case .systemManaged(let write):
            write(secret, now().addingTimeInterval(Self.lifetime))
            return
        case .applicationManaged(let write, _, _):
            deadline = monotonicNow().advanced(by: .seconds(Self.lifetime))
            guard let writtenOwnership = write(secret) else { return }
            ownership = writtenOwnership
        }
        let copy = Copy(ownership: ownership, deadline: deadline)
        currentCopy = copy
        scheduleExpiration(for: copy)
    }

    private func scheduleExpiration(for copy: Copy) {
        cancelExpiration?()
        cancelExpiration = nil
        let interval = max(.zero, monotonicNow().duration(to: copy.deadline))
        cancelExpiration = schedule(interval) { [weak self] in
            self?.expire(copy.identifier)
        }
    }

    private static func scheduleOnMainRunLoop(
        after delay: Duration,
        action: @escaping @MainActor () -> Void
    ) -> @MainActor () -> Void {
        let components = delay.components
        let interval = Double(components.seconds) + Double(components.attoseconds) / 1e18
        let timer = Timer(
            timeInterval: interval,
            target: TimerAction(action),
            selector: #selector(TimerAction.fire(_:)),
            userInfo: nil,
            repeats: false
        )
        RunLoop.main.add(timer, forMode: .common)
#if os(macOS)
        RunLoop.main.add(timer, forMode: .modalPanel)
#endif
        return { timer.invalidate() }
    }

    private func expire(_ identifier: UUID) {
        guard currentCopy?.identifier == identifier else { return }
        recheckExpiration()
    }

    @objc private func recheckExpiration() {
        guard let copy = currentCopy,
              case .applicationManaged(_, let changeCount, let clear) = pasteboard else { return }
        guard changeCount() == copy.ownership else {
            retireCopy()
            return
        }
        guard monotonicNow() >= copy.deadline else {
            scheduleExpiration(for: copy)
            return
        }
        clear()
        retireCopy()
    }

    @objc private func clearForTermination() {
        guard let copy = currentCopy,
              case .applicationManaged(_, let changeCount, let clear) = pasteboard else { return }
        if changeCount() == copy.ownership {
            clear()
        }
        retireCopy()
    }

    private func retireCopy() {
        currentCopy = nil
        cancelExpiration?()
        cancelExpiration = nil
    }

    isolated deinit {
        cancelExpiration?()
        applicationNotifications?.removeObserver(self)
        workspaceNotifications?.removeObserver(self)
    }
}
