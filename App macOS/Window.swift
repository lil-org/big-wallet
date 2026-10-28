import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import Cocoa

@MainActor
struct NativeWalletAccess {
    let controller: WalletAccessController?
    let generation: UInt64?

    init(_ controller: WalletAccessController? = nil) {
        self.controller = controller
        generation = controller?.generation
    }

    var isCurrent: Bool {
        guard let controller, let generation else { return true }
        return controller.accepts(generation)
    }

    var hasCurrentPresentation: Bool {
        guard let controller, let generation else { return true }
        return controller.generation == generation && !controller.isLocked
    }

    func beginAction() -> Bool {
        guard isCurrent else { return false }
        return controller?.recordInteraction() ?? true
    }

    func requireCurrentAccess() throws -> WalletAccessSession {
        guard isCurrent, let controller else { throw WalletCredentialError.authorizationUnavailable }
        let session = try controller.requireCurrentAccess()
        guard isCurrent else { throw WalletCredentialError.authorizationUnavailable }
        return session
    }
}

@MainActor
protocol NativeWalletProtectedContent: AnyObject {
    var walletAccess: NativeWalletAccess { get set }
    func retireForWalletLock()
}

final class WalletWindowController: NSWindowController, WalletAccessObserver {
    var approvalPeer: PeerMeta?
    private(set) var currentAuthenticationSession: WindowAuthenticationSession?
    private(set) var walletAccess: WalletAccessController?
    private var unlock: (() -> Void)?
    private var lockPresentationID: UUID?
    private var lockWindowCloseObserver: NativeApprovalWindowCloseObserver?
    private var contentInstallationID: UUID?
    fileprivate var cascadesOnFirstPresentation = false

    override func showWindow(_ sender: Any?) {
        let cascade = cascadesOnFirstPresentation
        cascadesOnFirstPresentation = false
        super.showWindow(sender)
        if cascade { Window.cascade(self) }
    }

    func bindAccess(_ access: WalletAccessController?, unlock: @escaping () -> Void) {
        walletAccess?.removeObserver(self)
        walletAccess = access
        self.unlock = unlock
        access?.addObserver(self)
        if let window {
            lockWindowCloseObserver?.disable()
            let observer = NativeApprovalWindowCloseObserver { [weak self] in self?.lockPresentationID = nil }
            lockWindowCloseObserver = observer
            observer.observe(window)
        }
    }

    func walletAccessDidLock() {
        contentInstallationID = nil
        currentAuthenticationSession?.cancel()
        if let protected = contentViewController as? NativeWalletProtectedContent { protected.retireForWalletLock() }
        else { (contentViewController as? NativeApprovalReviewTeardown)?.invalidateNativeApprovalReview() }
        switch contentViewController {
        case let password as PasswordViewController: password.retire()
        case let welcome as WelcomeViewController: welcome.retire()
        case let waiting as WaitingViewController: waiting.retire()
        default: break
        }
        Window.dismissSheets(in: window)
        if let modal = NSApp.modalWindow, modal !== window, modal.sheetParent == nil {
            Window.clearText(in: modal.contentView)
            NSApp.abortModal()
            modal.orderOut(nil)
        }
        window?.delegate = nil
        approvalPeer = nil
        let presentationID = UUID()
        lockPresentationID = presentationID
        contentViewController = WalletLockedViewController { [weak self] in
            guard let self, lockPresentationID == presentationID,
                  contentViewController is WalletLockedViewController,
                  walletAccess?.isLocked != false else { return }
            unlock?()
        }
    }

    @discardableResult
    func installProtectedContent(_ next: NSViewController, access: NativeWalletAccess) -> Bool {
        installContent(next) { access.isCurrent }
    }

    @discardableResult
    func installContent(_ next: NSViewController, while isCurrent: () -> Bool) -> Bool {
        let installationID = UUID()
        contentInstallationID = installationID
        func acceptsInstallation() -> Bool {
            isCurrent() && contentInstallationID == installationID
        }
        func discardInstallation() {
            if let protected = next as? NativeWalletProtectedContent { protected.retireForWalletLock() }
            else { (next as? NativeApprovalReviewTeardown)?.invalidateNativeApprovalReview() }
            switch next {
            case let password as PasswordViewController: password.retire()
            case let welcome as WelcomeViewController: welcome.retire()
            case let waiting as WaitingViewController: waiting.retire()
            default: break
            }
            if walletAccess?.isLocked == true, walletAccess?.hasLocked == true { walletAccessDidLock() }
            if contentViewController !== next, let retiredView = next.viewIfLoaded,
               retiredView !== window?.contentView {
                retiredView.isHidden = true
                retiredView.setAccessibilityHidden(true)
                retiredView.removeFromSuperview()
            }
        }
        guard acceptsInstallation() else {
            discardInstallation()
            return false
        }
        _ = next.view
        guard acceptsInstallation() else {
            discardInstallation()
            return false
        }
        contentViewController = next
        guard acceptsInstallation() else {
            discardInstallation()
            return false
        }
        contentInstallationID = nil
        return true
    }

    isolated deinit {
        walletAccess?.removeObserver(self)
        currentAuthenticationSession?.cancel()
        lockWindowCloseObserver?.disable()
    }

    func authenticate(
        reason: AuthenticationReason,
        challenge: WalletAuthenticationChallenge,
        review: NativeApprovalReview? = nil,
        dependencies: WindowAuthenticationSession.Dependencies = .init()
    ) async -> WalletAuthenticationGrant? {
        guard currentAuthenticationSession == nil, !Task.isCancelled,
              review?.isActive != false,
              let window, Window.isVisibleContentWindow(window) else {
            challenge.invalidate()
            return nil
        }
        var dependencies = dependencies
        if dependencies.access == nil { dependencies.access = walletAccess }
        let session = WindowAuthenticationSession(
            owner: window, reason: reason, challenge: challenge, review: review,
            dependencies: dependencies
        )
        currentAuthenticationSession = session
        defer {
            if currentAuthenticationSession === session { currentAuthenticationSession = nil }
        }
        return await session.run()
    }
}

@MainActor
final class WalletLockedViewController: NSViewController {
    private let unlock: () -> Void

    init(unlock: @escaping () -> Void) {
        self.unlock = unlock
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 400))
        let title = NSTextField(labelWithString: Strings.walletLocked)
        title.font = .systemFont(ofSize: 22, weight: .medium)
        title.alignment = .center
        let button = NSButton(title: Strings.unlock, target: self, action: #selector(unlockWallet))
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier("wallet.unlock")
        let stack = NSStackView(views: [title, button])
        stack.orientation = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
        self.view = view
    }

    @objc func unlockWallet() { unlock() }
}

@MainActor
final class MacWalletAccessLifecycle: NSObject {
    private let access: WalletAccessController
    private let protectedDataAvailable: @MainActor () -> Bool
    private var observations = [(NotificationCenter, NSObjectProtocol)]()
    private var inputMonitor: Any?

    init(
        access: WalletAccessController,
        applicationNotifications: NotificationCenter = .default,
        workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
        protectedDataAvailable: @escaping @MainActor () -> Bool = { NSApp.isProtectedDataAvailable },
        monitorsInput: Bool = true
    ) {
        self.access = access
        self.protectedDataAvailable = protectedDataAvailable
        super.init()
        access.isProtectedDataAvailable = protectedDataAvailable
        observe(Notification.Name.NSApplicationProtectedDataWillBecomeUnavailable, in: applicationNotifications) { [weak self] in
            self?.access.lock(reason: .protectedDataUnavailable)
        }
        observe(NSApplication.didBecomeActiveNotification, in: applicationNotifications) { [weak self] in self?.checkActivation() }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observe(name, in: workspaceNotifications) { [weak self] in self?.access.lock(reason: .systemSleep) }
        }
        observe(NSWorkspace.sessionDidResignActiveNotification, in: workspaceNotifications) { [weak self] in
            self?.access.lock(reason: .sessionInactive)
        }
        if monitorsInput { installInputMonitor() }
        checkActivation()
    }

    private func observe(_ name: Notification.Name, in center: NotificationCenter, action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        observations.append((center, token))
    }

    private func installInputMonitor() {
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .magnify, .rotate, .swipe
        ]) { [weak self] event in
            guard let self else { return event }
            let wasUnlocked = !self.access.isLocked
            if [.scrollWheel, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .magnify, .rotate, .swipe].contains(event.type) ||
                event.type == .keyDown && event.isARepeat {
                self.access.recordContinuousInteraction()
                return self.access.isLocked && wasUnlocked ? nil : event
            }
            return !self.access.recordInteraction() && wasUnlocked ? nil : event
        }
    }

    func checkActivation() {
        if !protectedDataAvailable() { access.lock(reason: .protectedDataUnavailable) }
        else { access.checkAccess() }
    }

    isolated deinit {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        for (center, token) in observations { center.removeObserver(token) }
    }
}

@MainActor
struct Window {
    
    private static var isClosingAllWindows = false

    static func dismissSheets(in window: NSWindow?) {
        guard let window else { return }
        for sheet in window.sheets {
            dismissSheets(in: sheet)
            clearText(in: sheet.contentView)
            window.endSheet(sheet, returnCode: .abort)
            sheet.orderOut(nil)
        }
    }

    static func clearText(in view: NSView?) {
        guard let view else { return }
        if let field = view as? NSTextField { field.stringValue = "" }
        if let text = view as? NSTextView { text.string = "" }
        view.subviews.forEach { clearText(in: $0) }
    }

    static func clearSecretInput(_ field: NSTextField?) {
        guard let field else { return }
        if let editor = field.currentEditor() {
            (editor as? NSTextView)?.breakUndoCoalescing()
            editor.string = ""
            _ = field.abortEditing()
        }
        field.stringValue = ""
    }

    static func authenticate(
        in window: NSWindow?,
        reason: AuthenticationReason,
        challenge: WalletAuthenticationChallenge,
        review: NativeApprovalReview? = nil
    ) async -> WalletAuthenticationGrant? {
        guard let controller = window?.windowController as? WalletWindowController else {
            challenge.invalidate()
            return nil
        }
        return await controller.authenticate(reason: reason, challenge: challenge, review: review)
    }
    
    static func showNew(
        closeOthers: Bool,
        approvalPeer: PeerMeta? = nil,
        activates: Bool = true
    ) -> WalletWindowController {
        if closeOthers {
            closeAll()
        }
        
        let windowController = new
        windowController.approvalPeer = approvalPeer
        windowController.cascadesOnFirstPresentation = !closeOthers
        if activates { activate(windowController) }

        return windowController
    }

    fileprivate static func cascade(_ windowController: WalletWindowController) {
        if let frame = windowController.window?.frame {
            let stepX: CGFloat = 18
            let stepY: CGFloat = 16

            let topLeft = CGPoint(x: frame.minX, y: frame.maxY)
            var validCascadeIndexes = [Int]()

            let validateActiveSpace = windowController.window?.isOnActiveSpace == true
            for otherWindow in NSApplication.shared.windows where
                otherWindow !== windowController.window &&
                isVisibleContentWindow(otherWindow) {
                if validateActiveSpace, !otherWindow.isOnActiveSpace { continue }
                let otherTopLeft = CGPoint(x: otherWindow.frame.minX, y: otherWindow.frame.maxY)

                let deltaX = otherTopLeft.x - topLeft.x
                let deltaY = otherTopLeft.y - topLeft.y

                if deltaX.truncatingRemainder(dividingBy: stepX).isZero, deltaY.truncatingRemainder(dividingBy: stepY).isZero {
                    let xIndex = deltaX / stepX
                    let yIndex = deltaY / stepY
                    if xIndex == yIndex {
                        validCascadeIndexes.append(Int(xIndex))
                    }
                }
            }

            if let previousCascadeIndex = validCascadeIndexes.max() {
                let cascadeIndex = CGFloat(previousCascadeIndex + 1)
                let newTopLeft = CGPoint(x: topLeft.x + stepX * cascadeIndex, y: topLeft.y + stepY * cascadeIndex)
                windowController.window?.setFrameTopLeftPoint(newTopLeft)
            }
        }
    }

    static private func activate(_ windowController: NSWindowController) {
        windowController.showWindow(nil)
        activateWindow(windowController.window)
    }
    
    static func activateWindow(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    
    static func reactivateWindow(_ windowController: NSWindowController) {
        windowController.showWindow(nil)
        if windowController.window?.isMiniaturized == true {
            windowController.window?.deminiaturize(nil)
        }
        activateWindow(windowController.window)
    }

    static func isVisibleContentWindow(_ window: NSWindow) -> Bool {
        window.contentViewController != nil &&
            (window.isVisible || window.isMiniaturized)
    }

    static func closeWindow(idToClose: Int?) {
        guard !isClosingAllWindows else { return }
        if let id = idToClose, let windowToClose = NSApplication.shared.windows.first(where: { $0.windowNumber == id }) {
            windowToClose.close()
        }
    }
    
    private static func closeAll() {
        isClosingAllWindows = true
        NSApplication.shared.windows.filter(isVisibleContentWindow).forEach { window in
            window.close()
        }
        isClosingAllWindows = false
    }
    
    static func activateBrowser(specific browser: Browser?) {
        if let browser = browser, browser != .unknown {
            activateBrowser(browser)
            return
        }
        
        let browsers = NSWorkspace.shared.runningApplications.filter { app in
            if let bundleId = app.bundleIdentifier {
                return Browser.allBundleIds.contains(bundleId)
            } else {
                return false
            }
        }
        
        guard !browsers.isEmpty else { return }
        
        let browsersPids = Set(browsers.map { $0.processIdentifier })
        let options = CGWindowListOption(arrayLiteral: [.excludeDesktopElements, .optionOnScreenOnly])
        guard let windows = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [[String: AnyObject]] else { return }
        for window in windows {
            if let pid = window[kCGWindowOwnerPID as String] as? pid_t, browsersPids.contains(pid) {
                browsers.first(where: { $0.processIdentifier == pid })?.activate()
                return
            }
        }
    }
    
    private static func activateBrowser(_ browser: Browser) {
        NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == browser.rawValue })?.activate()
    }
    
    private static var new: WalletWindowController {
        return NSStoryboard.main.instantiateController(
            withIdentifier: "initial"
        ) as! WalletWindowController
    }
    
}

@MainActor
extension NSStoryboard {
    static let main = NSStoryboard(name: "Main", bundle: nil)
}

@MainActor
func instantiate<ViewController: NSViewController>(_ type: ViewController.Type) -> ViewController {
    return NSStoryboard.main.instantiateController(withIdentifier: String(describing: type)) as! ViewController
}
