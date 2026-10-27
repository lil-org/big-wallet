import UIKit
import WalletAuthority

@MainActor
final class MobileWalletSceneTracker {
    private var foreground = [String: Bool]()
    private let lock: (WalletAccessController.LockReason) -> Void

    init(lock: @escaping (WalletAccessController.LockReason) -> Void) {
        self.lock = lock
    }

    func update(sceneID: String, isForeground: Bool) {
        let previous = foreground.updateValue(isForeground, forKey: sceneID)
        if !isForeground, previous != false, !foreground.values.contains(true) {
            lock(.background)
        }
    }

    func remove(sceneID: String) {
        guard foreground.removeValue(forKey: sceneID) == true,
              !foreground.values.contains(true) else { return }
        lock(.background)
    }
}

@MainActor
final class MobileWalletSceneRegistry: NSObject {
    static let shared = MobileWalletSceneRegistry(access: ApplicationServices.shared.access)

    @MainActor
    private final class Entry {
        weak var window: UIWindow?
        let sceneID: String
        let activity: WalletActivityGestureRecognizer
        let cover = UIView()

        init(window: UIWindow, sceneID: String, activity: WalletActivityGestureRecognizer) {
            self.window = window
            self.sceneID = sceneID
            self.activity = activity
            cover.backgroundColor = .systemBackground
            cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            cover.isAccessibilityElement = true
            cover.accessibilityLabel = Strings.walletLocked
            cover.accessibilityIdentifier = "wallet-privacy-cover"
            cover.accessibilityViewIsModal = true
            cover.isHidden = true
        }
    }

    private let access: WalletAccessController
    private let tracker: MobileWalletSceneTracker
    private let notifications: NotificationCenter
    private let protectedDataAvailable: @MainActor () -> Bool
    private var notificationObservers = [NSObjectProtocol]()
    private var entries = [ObjectIdentifier: Entry]()

    init(
        access: WalletAccessController,
        notifications: NotificationCenter = .default,
        protectedDataAvailable: @escaping @MainActor () -> Bool = { UIApplication.shared.isProtectedDataAvailable }
    ) {
        self.access = access
        self.notifications = notifications
        self.protectedDataAvailable = protectedDataAvailable
        tracker = MobileWalletSceneTracker { access.lock(reason: $0) }
        super.init()
        access.isProtectedDataAvailable = protectedDataAvailable
        for name in [UIScene.willEnterForegroundNotification, UIScene.didActivateNotification,
                     UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
                     UIScene.didDisconnectNotification, UIApplication.protectedDataWillBecomeUnavailableNotification,
                     UIApplication.protectedDataDidBecomeAvailableNotification,
                     UITextField.textDidChangeNotification, UITextView.textDidChangeNotification] {
            notificationObservers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let name = notification.name
                let scene = notification.object as? UIWindowScene
                let textInput = notification.object as? UIView
                MainActor.assumeIsolated { self?.receive(name, scene: scene, textInput: textInput) }
            })
        }
    }

    isolated deinit {
        notificationObservers.forEach(notifications.removeObserver)
    }

    func register(_ window: UIWindow) {
        pruneWindows()
        guard let scene = window.windowScene else { return }
        let key = ObjectIdentifier(window)
        guard entries[key] == nil else { return }
        let activity = WalletActivityGestureRecognizer { [weak self, weak window] continuous in
            guard let self, let window, window.windowScene?.activationState == .foregroundActive else { return }
            if continuous { access.recordContinuousInteraction() }
            else { access.recordInteraction() }
        }
        window.addGestureRecognizer(activity)
        let entry = Entry(window: window, sceneID: scene.session.persistentIdentifier, activity: activity)
        entries[key] = entry
        entry.cover.frame = window.bounds
        window.addSubview(entry.cover)
        tracker.update(sceneID: entry.sceneID, isForeground: scene.activationState != .background)
        setCovered(entry, scene.activationState != .foregroundActive)
    }

    private func pruneWindows() {
        let expired = entries.filter { $0.value.window == nil }
        for (key, _) in expired { entries.removeValue(forKey: key) }
        for sceneID in Set(expired.values.map(\.sceneID)) where !entries.values.contains(where: { $0.sceneID == sceneID }) {
            tracker.remove(sceneID: sceneID)
        }
    }

    private func setCovered(_ entry: Entry, _ covered: Bool) {
        guard let window = entry.window else { return }
        if !covered { access.checkAccess() }
        let covered = covered || !protectedDataAvailable()
        entry.cover.frame = window.bounds
        window.bringSubviewToFront(entry.cover)
        entry.cover.isHidden = !covered
        window.rootViewController?.viewIfLoaded?.accessibilityElementsHidden = covered
    }

    private func receive(_ name: Notification.Name, scene: UIWindowScene?, textInput: UIView?) {
        switch name {
        case UIApplication.protectedDataWillBecomeUnavailableNotification:
            protectedDataUnavailable()
        case UIApplication.protectedDataDidBecomeAvailableNotification:
            protectedDataBecameAvailable()
        case UITextField.textDidChangeNotification, UITextView.textDidChangeNotification:
            textChanged(textInput)
        default:
            sceneChanged(name, scene: scene)
        }
    }

    private func sceneChanged(_ name: Notification.Name, scene: UIWindowScene?) {
        pruneWindows()
        guard let scene else { return }
        let sceneID = scene.session.persistentIdentifier
        let affected = entries.filter { $0.value.sceneID == sceneID }
        guard !affected.isEmpty else { return }
        switch name {
        case UIScene.didDisconnectNotification:
            for (key, entry) in affected {
                entry.window?.removeGestureRecognizer(entry.activity)
                entry.cover.removeFromSuperview()
                entries.removeValue(forKey: key)
            }
            tracker.remove(sceneID: sceneID)
        case UIScene.didEnterBackgroundNotification:
            affected.values.forEach { setCovered($0, true) }
            tracker.update(sceneID: sceneID, isForeground: false)
        case UIScene.didActivateNotification:
            tracker.update(sceneID: sceneID, isForeground: true)
            affected.values.forEach { setCovered($0, false) }
        default:
            tracker.update(sceneID: sceneID, isForeground: true)
            affected.values.forEach { setCovered($0, true) }
        }
    }

    private func protectedDataUnavailable() {
        entries.values.forEach { setCovered($0, true) }
        access.lock(reason: .protectedDataUnavailable)
    }

    private func protectedDataBecameAvailable() {
        for entry in entries.values where entry.window?.windowScene?.activationState == .foregroundActive {
            setCovered(entry, false)
        }
    }

    private func textChanged(_ view: UIView?) {
        guard let view, let window = view.window,
              entries[ObjectIdentifier(window)] != nil,
              window.windowScene?.activationState == .foregroundActive else { return }
        access.recordInteraction()
    }
}

private final class WalletActivityGestureRecognizer: UIGestureRecognizer {
    private let interaction: @MainActor (Bool) -> Void

    init(interaction: @escaping @MainActor (Bool) -> Void) {
        self.interaction = interaction
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { interaction(false) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { interaction(true) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) { interaction(false) }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) { state = .failed }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) { state = .cancelled }
}

@MainActor
final class WalletActivityTableView: UITableView {
    var accessibilityInteraction: (() -> Bool)?

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard accessibilityInteraction?() == true else { return false }
        return super.accessibilityScroll(direction)
    }
}

@MainActor
class WalletAccessViewController: UIViewController, WalletAccessObserver {
    var access = ApplicationServices.shared.access
    private(set) var accessGeneration: UInt64?

    override func viewDidLoad() {
        super.viewDidLoad()
        accessGeneration = access.generation
        access.addObserver(self)
    }

    isolated deinit {
        access.removeObserver(self)
    }

    var hasWalletAccess: Bool {
        guard let accessGeneration else { return false }
        return access.accepts(accessGeneration)
    }

    var hasCurrentWalletPresentation: Bool {
        accessGeneration == access.generation && !access.isLocked
    }

    @discardableResult
    func beginWalletAction() -> Bool {
        hasWalletAccess && access.recordInteraction()
    }

    func requireCurrentCredentials() throws {
        guard hasWalletAccess else { throw WalletCredentialError.authorizationUnavailable }
        try access.requireCurrentCredentials()
    }

    func walletAccessDidLock() {
        viewIfLoaded?.endEditing(true)
        viewIfLoaded?.isUserInteractionEnabled = false
        clearPresentedWalletInputs()
        dismissPresentedWalletContent()
    }

    func walletAccessDidUnlock() {}
}

extension UIViewController {
    func clearPresentedWalletInputs() {
        if let alert = self as? UIAlertController {
            alert.textFields?.forEach { $0.clearSecretDraft() }
            alert.message = nil
        }
        children.forEach { $0.clearPresentedWalletInputs() }
        presentedViewController?.clearPresentedWalletInputs()
    }

    func dismissPresentedWalletContent() {
        children.forEach { $0.dismissPresentedWalletContent() }
        guard let presented = presentedViewController else { return }
        presented.viewIfLoaded?.isHidden = true
        presented.dismissAfterCurrentTransition(animated: false)
    }
}

@MainActor
final class MobileWalletRootViewController: UIViewController, WalletAccessObserver {
    private let access: WalletAccessController
    private let registerWindow: (UIWindow) -> Void
    private let makeAccounts: (WalletAccessController) -> UIViewController
    private let makeAuthentication: (WalletAccessController) -> UIViewController
    private var presentationRevision: UInt64 = 0
    private(set) var content: UIViewController?

    init(
        access: WalletAccessController,
        registerWindow: @escaping (UIWindow) -> Void = { MobileWalletSceneRegistry.shared.register($0) },
        makeAccounts: @escaping (WalletAccessController) -> UIViewController = { access in
            let accounts = instantiate(AccountsListViewController.self, from: .main)
            accounts.access = access
            return accounts.inNavigationController
        },
        makeAuthentication: @escaping (WalletAccessController) -> UIViewController = { access in
            let password = instantiate(PasswordViewController.self, from: .main)
            password.access = access
            return password.inNavigationController
        }
    ) {
        self.access = access
        self.registerWindow = registerWindow
        self.makeAccounts = makeAccounts
        self.makeAuthentication = makeAuthentication
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        access.addObserver(self)
        if access.checkAccess() { walletAccessDidUnlock() }
        else if access.hasLocked { walletAccessDidLock() }
        else { showAuthentication() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let window = view.window { registerWindow(window) }
        access.checkAccess()
    }

    isolated deinit { access.removeObserver(self) }

    func walletAccessDidLock() {
        replaceContent {
            let revision = presentationRevision
            return MobileWalletLockedViewController { [weak self] locked in
                guard let self, presentationRevision == revision, content === locked else { return }
                showAuthentication()
            }
        }
    }

    func walletAccessDidUnlock() {
        guard access.checkAccess() else { return }
        replaceContent { makeAccounts(access) }
    }

    private func showAuthentication() {
        guard access.isLocked else { return }
        replaceContent { makeAuthentication(access) }
    }

    private func replaceContent(_ makeContent: () -> UIViewController) {
        presentationRevision &+= 1
        let revision = presentationRevision
        let generation = access.generation
        let next = makeContent()
        guard presentationRevision == revision, access.generation == generation else { return }
        next.loadViewIfNeeded()
        guard presentationRevision == revision, access.generation == generation,
              let nextView = next.viewIfLoaded else { return }
        let previous = content
        previous?.clearPresentedWalletInputs()
        guard presentationRevision == revision, access.generation == generation else { return }
        previous?.viewIfLoaded?.endEditing(true)
        guard presentationRevision == revision, access.generation == generation else { return }
        previous?.dismissPresentedWalletContent()
        guard presentationRevision == revision, access.generation == generation else { return }
        previous?.willMove(toParent: nil)
        guard presentationRevision == revision, access.generation == generation else { return }
        previous?.viewIfLoaded?.removeFromSuperview()
        previous?.removeFromParent()
        guard presentationRevision == revision, access.generation == generation else { return }
        content = next
        addChild(next)
        guard presentationRevision == revision, access.generation == generation else {
            discardRetiredContent(next)
            return
        }
        nextView.frame = view.bounds
        nextView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(nextView)
        guard presentationRevision == revision, content === next else {
            discardRetiredContent(next)
            return
        }
        next.didMove(toParent: self)
        guard presentationRevision == revision, content === next else {
            discardRetiredContent(next)
            return
        }
        if let window = view.window { registerWindow(window) }
    }

    private func discardRetiredContent(_ controller: UIViewController) {
        guard content !== controller else { return }
        controller.viewIfLoaded?.removeFromSuperview()
        if controller.parent === self { controller.removeFromParent() }
    }
}

@MainActor
final class MobileWalletLockedViewController: UIViewController {
    private let unlock: (MobileWalletLockedViewController) -> Void

    init(unlock: @escaping (MobileWalletLockedViewController) -> Void) {
        self.unlock = unlock
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel()
        title.text = Strings.walletLocked
        title.font = .preferredFont(forTextStyle: .title2)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0
        title.textAlignment = .center
        let button = UIButton(type: .system)
        button.setTitle(Strings.unlock, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.accessibilityIdentifier = "wallet-unlock"
        button.addTarget(self, action: #selector(unlockTapped), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [title, button])
        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])
    }

    @objc private func unlockTapped() { unlock(self) }
}
