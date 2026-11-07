import WalletDomain
import WalletAuthority
import WalletNetworking
import Cocoa

@MainActor
final class NativeSecretAlertPresentation {
    typealias Token = SecretPresentationSession.Token
    typealias Authentication = @MainActor () async -> WalletAuthenticationGrant?
    typealias Export = @MainActor (WalletAuthenticationGrant) async throws -> WalletExportedSecret

    private enum Phase {
        case waitingForSecret, authenticating, exporting, showing
    }

    private enum Authorization {
        case authenticate(Authentication)
        case grant(WalletAuthenticationGrant)

        func invalidate() {
            if case .grant(let grant) = self { grant.invalidate() }
        }
    }

    @MainActor
    private final class Reveal {
        let token: Token
        weak var window: NSWindow?
        let title: String
        var phase = Phase.waitingForSecret
        var task: Task<Void, Never>?
        var sheet: Sheet?

        init(token: Token, window: NSWindow, title: String) {
            self.token = token
            self.window = window
            self.title = title
        }
    }

    @MainActor
    private final class Sheet: NSObject {
        let alert = NSAlert()
        let secretField = NSTextField(wrappingLabelWithString: "")
        private let finish: (Sheet, NSApplication.ModalResponse) -> Void

        init(title: String, finish: @escaping (Sheet, NSApplication.ModalResponse) -> Void) {
            self.finish = finish
            super.init()
            alert.messageText = title
            alert.alertStyle = .informational
            secretField.isSelectable = false
            secretField.isEditable = false
            secretField.preferredMaxLayoutWidth = 320
            alert.accessoryView = secretField
            alert.addButton(withTitle: Strings.ok)
            let copyButton = alert.addButton(withTitle: Strings.copy)
            copyButton.target = self
            copyButton.action = #selector(copyButtonClicked)
        }

        func present(for window: NSWindow) {
            secretField.frame = NSRect(x: 0, y: 0, width: 320, height: secretField.fittingSize.height)
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                finish(self, response)
            }
        }

        @objc private func copyButtonClicked() {
            finish(self, .alertSecondButtonReturn)
        }

        func dismiss() {
            secretField.stringValue = ""
            alert.informativeText = ""
            if let window = alert.window.sheetParent {
                window.endSheet(alert.window, returnCode: .abort)
            }
            alert.window.orderOut(nil)
        }
    }

    private let session = SecretPresentationSession()
    private var active: Reveal?
    private let sourceIsCurrent: (NSWindow) -> Bool
    private let copy: (String) -> Void
    private let notifications: NotificationCenter
    private let applicationIsActive: () -> Bool
    private let keyWindow: () -> NSWindow?
    private var observers = [NSObjectProtocol]()

    var alert: NSAlert? { active?.sheet?.alert }

    init(
        sourceIsCurrent: @escaping (NSWindow) -> Bool,
        copy: @escaping (String) -> Void = { SecretClipboard.shared.copy($0) },
        notifications: NotificationCenter = .default,
        applicationIsActive: @escaping () -> Bool = { NSApp.isActive },
        keyWindow: @escaping () -> NSWindow? = { NSApp.keyWindow }
    ) {
        self.sourceIsCurrent = sourceIsCurrent
        self.copy = copy
        self.notifications = notifications
        self.applicationIsActive = applicationIsActive
        self.keyWindow = keyWindow
        for name in [NSApplication.willResignActiveNotification, NSApplication.willHideNotification,
                     NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification,
                     NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let name = notification.name
                let window = notification.object as? NSWindow
                MainActor.assumeIsolated { self?.receive(name, window: window) }
            })
        }
    }

    isolated deinit {
        observers.forEach(notifications.removeObserver)
        invalidate()
    }

    static func acceptsKeyWindow(_ keyWindow: NSWindow?, owner: NSWindow, sheetWindow: NSWindow? = nil) -> Bool {
        guard let keyWindow, keyWindow.isKeyWindow else { return false }
        return keyWindow === owner || keyWindow === sheetWindow
    }

    func begin(in window: NSWindow, title: String) -> Token? {
        invalidate()
        let reveal = Reveal(token: session.begin(), window: window, title: title)
        active = reveal
        guard accepts(reveal) else {
            invalidate(ifCurrent: reveal.token)
            return nil
        }
        return reveal.token
    }

    func authenticateAndReveal(for token: Token, authenticate: @escaping Authentication, export: @escaping Export) {
        start(for: token, authorization: .authenticate(authenticate), export: export)
    }

    func reveal(for token: Token, authorization: WalletAuthenticationGrant, export: @escaping Export) {
        start(for: token, authorization: .grant(authorization), export: export)
    }

    private func start(for token: Token, authorization: Authorization, export: @escaping Export) {
        guard let reveal = active, reveal.token == token, reveal.phase == .waitingForSecret,
              accepts(reveal) else {
            authorization.invalidate()
            return
        }
        switch authorization {
        case .authenticate: reveal.phase = .authenticating
        case .grant: reveal.phase = .exporting
        }
        reveal.task = Task { [weak self] in
            let grant: WalletAuthenticationGrant?
            switch authorization {
            case .authenticate(let authenticate):
                guard !Task.isCancelled, self?.isCurrent(token) == true else { return }
                grant = await authenticate()
            case .grant(let authorization):
                grant = authorization
            }
            guard let grant else {
                self?.invalidate(ifCurrent: token)
                return
            }
            defer { grant.invalidate() }
            guard !Task.isCancelled, self?.beginExport(for: token) == true else {
                self?.invalidate(ifCurrent: token)
                return
            }
            do {
                let secret = try await withTaskCancellationHandler {
                    try await export(grant)
                } onCancel: {
                    grant.invalidate()
                }
                guard !Task.isCancelled, self?.show(secret, for: token) == true else {
                    secret.invalidate()
                    self?.invalidate(ifCurrent: token)
                    return
                }
            } catch {
                self?.invalidate(ifCurrent: token)
            }
        }
    }

    private func isCurrent(_ token: Token) -> Bool {
        active?.token == token && session.isCurrent(token)
    }

    private func accepts(_ reveal: Reveal) -> Bool {
        guard active === reveal, let window = reveal.window else { return false }
        let eligible = sourceIsCurrent(window) && applicationIsActive() && window.isVisible && !window.isMiniaturized &&
            Self.acceptsKeyWindow(keyWindow(), owner: window, sheetWindow: reveal.sheet?.alert.window)
        return eligible && active === reveal && session.isCurrent(reveal.token)
    }

    private func beginExport(for token: Token) -> Bool {
        guard let reveal = active, reveal.token == token else { return false }
        reveal.phase = .exporting
        return accepts(reveal)
    }

    private func show(_ secret: WalletExportedSecret, for token: Token) -> Bool {
        guard let reveal = active, reveal.token == token, reveal.phase == .exporting,
              accepts(reveal), let window = reveal.window,
              session.store(secret, for: token) else { return false }
        let sheet = Sheet(title: reveal.title) { [weak self] sheet, response in
            self?.finish(response, for: token, sheet: sheet)
        }
        guard session.withText(for: token, { sheet.secretField.stringValue = $0 }) else { return false }
        reveal.phase = .showing
        reveal.task = nil
        reveal.sheet = sheet
        sheet.present(for: window)
        return true
    }

    private func finish(_ response: NSApplication.ModalResponse, for token: Token, sheet: Sheet) {
        guard let reveal = active, reveal.token == token, reveal.sheet === sheet else { return }
        if response == .alertSecondButtonReturn, accepts(reveal), session.withText(for: token, { secret in
            invalidate(ifCurrent: token)
            copy(secret)
        }) { return }
        invalidate(ifCurrent: token)
    }

    func invalidate(ifCurrent token: Token? = nil) {
        guard token == nil || active?.token == token else { return }
        let previous = active
        active = nil
        session.invalidate()
        previous?.task?.cancel()
        previous?.sheet?.dismiss()
    }

    func cancelAuthentication() {
        if active?.phase == .authenticating { invalidate() }
    }

    func sourceWillDisappear() {
        if active?.phase != .authenticating { invalidate() }
    }

    func walletLoadStateChanged(_ state: WalletsManager.LoadState) {
        guard state != .ready else { return }
        if state != .loading || active?.phase != .authenticating { invalidate() }
    }

    private func receive(_ name: Notification.Name, window: NSWindow?) {
        guard let reveal = active else { return }
        switch name {
        case NSApplication.willResignActiveNotification, NSApplication.willHideNotification:
            sourceWillDisappear()
        case NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification:
            if let window, window === reveal.window || window === reveal.sheet?.alert.window { invalidate() }
        case NSWindow.didResignKeyNotification:
            guard reveal.phase != .authenticating, let window,
                  window === reveal.window || window === reveal.sheet?.alert.window else { return }
            let token = reveal.token
            Task { [weak self] in
                await Task.yield()
                guard let self, let current = active, current.token == token, !accepts(current) else { return }
                invalidate(ifCurrent: token)
            }
        case NSWindow.didBecomeKeyNotification:
            if reveal.phase != .authenticating, let window,
               window !== reveal.window, window !== reveal.sheet?.alert.window { invalidate() }
        default:
            break
        }
    }
}
