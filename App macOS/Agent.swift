// ∅ 2026 lil org

import Cocoa
import LocalAuthentication

class Agent: NSObject {
    
    enum ExternalRequest {
        case safari(SafariRequest)
    }
    
    static let shared = Agent()
    
    private let walletsManager = WalletsManager.shared
    private static let deferredExternalRequestMaxAge: TimeInterval = 5 * 60
    
    private override init() { super.init() }
    private var didEnterPasswordOnStart = false
    
    private var didStartInitialLAEvaluation = false
    private var didCompleteInitialLAEvaluation = false
    private var initialExternalRequest: DeferredExternalRequest?

    private struct DeferredExternalRequest {
        let request: ExternalRequest
        let createdAt = Date()

        var canBeProcessed: Bool {
            return !isExpired && request.isPending
        }

        private var isExpired: Bool {
            return Date().timeIntervalSince(createdAt) > Agent.deferredExternalRequestMaxAge
        }

        func isSameDeferredRequest(as other: DeferredExternalRequest) -> Bool {
            return createdAt == other.createdAt && request.matches(other.request)
        }
    }
    
    private var hasPassword: Bool {
        return Keychain.shared.password != nil
    }

    func start(openOnLaunch: Bool) {
        NotificationCenter.default.addObserver(self, selector: #selector(walletsChanged), name: .walletsChanged, object: nil)
        if openOnLaunch {
            open()
        }
    }
    
    func showInitialScreen(externalRequest: ExternalRequest?) {
        let isEvaluatingInitialLA = didStartInitialLAEvaluation && !didCompleteInitialLAEvaluation
        guard !isEvaluatingInitialLA else {
            deferInitialExternalRequest(externalRequest)
            return
        }
        
        guard hasPassword else {
            guard CurrentApp.canCreatePassword else {
                deferInitialExternalRequest(externalRequest)
                DockAppLauncher.openDockApp()
                return
            }
            let welcomeViewController = WelcomeViewController.new { [weak self] createdPassword in
                guard let self else { return }
                if createdPassword {
                    self.didEnterPasswordOnStart = true
                    self.didCompleteInitialLAEvaluation = true
                } else {
                    guard self.hasPassword else { return }
                    self.didEnterPasswordOnStart = false
                }
                self.showInitialScreen(externalRequest: externalRequest)
            }
            let windowController = Window.showNew(closeOthers: true)
            windowController.contentViewController = welcomeViewController
            return
        }
        
        guard didEnterPasswordOnStart else {
            askAuthentication(on: nil, browser: nil, onStart: true, reason: .start) { [weak self] success in
                if success {
                    self?.didEnterPasswordOnStart = true
                    self?.showInitialScreen(externalRequest: externalRequest)
                }
            }
            return
        }
        
        let deferredRequest = initialExternalRequest
        let request = externalRequest ?? deferredRequest?.request
        if let externalRequest = externalRequest,
           let deferredRequest = deferredRequest,
           !deferredRequest.request.matches(externalRequest) {
            deferredRequest.request.cancelIfPending()
        }
        initialExternalRequest = nil
        if let request = request {
            if externalRequest == nil, let deferredRequest, !deferredRequest.canBeProcessed {
                deferredRequest.request.cancelIfPending()
                return
            }
            processExternalRequest(request)
        } else {
            let accountsList = instantiate(AccountsListViewController.self)
            let windowController = Window.showNew(closeOthers: accountsList.selectAccountAction == nil)
            windowController.contentViewController = accountsList
        }
    }
    
    func showApprove(windowController: NSWindowController, browser: Browser?, transaction: Transaction, account: WalletAccount, walletId: String, chain: EthereumNetwork, peerMeta: PeerMeta?, completion: @escaping (Transaction?) -> Void) {
        let window = windowController.window
        let approveViewController = ApproveTransactionViewController.with(transaction: transaction, chain: chain, account: account, walletId: walletId, peerMeta: peerMeta) { [weak self, weak window] transaction in
            if transaction != nil {
                self?.askAuthentication(on: window, browser: browser, onStart: false, reason: .sendTransaction) { success in
                    completion(success ? transaction : nil)
                }
            } else {
                completion(nil)
            }
        }
        windowController.contentViewController = approveViewController
    }
    
    func showApprove(windowController: NSWindowController,
                     browser: Browser?,
                     subject: ApprovalSubject,
                     meta: String,
                     account: WalletAccount,
                     walletId: String,
                     peerMeta: PeerMeta?,
                     solanaClusterSelection: SolanaClusterSelection? = nil,
                     completion: @escaping (Bool) -> Void) {
        let window = windowController.window
        let approveViewController = ApproveViewController.with(subject: subject,
                                                               meta: meta,
                                                               account: account,
                                                               walletId: walletId,
                                                               peerMeta: peerMeta,
                                                               solanaClusterSelection: solanaClusterSelection) { [weak self, weak window] result in
            if result {
                self?.askAuthentication(on: window, getBackTo: window?.contentViewController, browser: browser, onStart: false, reason: subject.asAuthenticationReason) { success in
                    completion(success)
                    (window?.contentViewController as? ApproveViewController)?.enableWaiting()
                }
            } else {
                completion(result)
            }
        }
        windowController.contentViewController = approveViewController
    }

    func open() {
        showInitialScreen(externalRequest: nil)
    }

    @objc private func walletsChanged() {
        guard let deferredRequest = initialExternalRequest, hasPassword else { return }
        guard deferredRequest.canBeProcessed else {
            deferredRequest.request.cancelIfPending()
            initialExternalRequest = nil
            return
        }
        showInitialScreen(externalRequest: nil)
    }

    private func deferInitialExternalRequest(_ request: ExternalRequest?) {
        guard let request else { return }
        if let deferredRequest = initialExternalRequest, !deferredRequest.request.matches(request) {
            deferredRequest.request.cancelIfPending()
        }
        let deferredRequest = DeferredExternalRequest(request: request)
        initialExternalRequest = deferredRequest
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.deferredExternalRequestMaxAge) { [weak self] in
            guard let self,
                  let currentDeferredRequest = self.initialExternalRequest,
                  currentDeferredRequest.isSameDeferredRequest(as: deferredRequest)
            else { return }
            currentDeferredRequest.request.cancelIfPending()
            self.initialExternalRequest = nil
        }
    }
    
    func askAuthentication(on: NSWindow?, getBackTo: NSViewController? = nil, browser: Browser?, onStart: Bool, reason: AuthenticationReason, completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        let policy = LAPolicy.deviceOwnerAuthenticationWithBiometrics
        let canDoLocalAuthentication = context.canEvaluatePolicy(policy, error: &error)
        
        func showPasswordScreen() {
            let window = on ?? Window.showNew(closeOthers: onStart).window
            let passwordViewController = PasswordViewController.with(mode: .enter, reason: reason) { [weak window] success in
                if let getBackTo = getBackTo {
                    window?.contentViewController = getBackTo
                } else if let browser = browser {
                    Window.closeWindowAndActivateNext(idToClose: window?.windowNumber, specificBrowser: browser)
                } else {
                    Window.closeWindow(idToClose: window?.windowNumber)
                }
                completion(success)
            }
            window?.contentViewController = passwordViewController
        }
        
        if canDoLocalAuthentication {
            context.localizedCancelTitle = Strings.cancel
            didStartInitialLAEvaluation = true
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason.title) { [weak self] success, _ in
                DispatchQueue.main.async {
                    self?.didCompleteInitialLAEvaluation = true
                    if !success, onStart, self?.didEnterPasswordOnStart == false {
                        showPasswordScreen()
                    }
                    completion(success)
                }
            }
        } else {
            showPasswordScreen()
        }
    }

    private func processExternalRequest(_ request: ExternalRequest) {
        var windowNumber: Int?
        let action: DappRequestAction
        
        switch request {
        case .safari(let safariRequest):
            action = DappRequestProcessor.processSafariRequest(safariRequest) { _ in
                Window.closeWindowAndActivateNext(idToClose: windowNumber, specificBrowser: .safari)
            }
        }
        
        switch action {
        case .none:
            break
        case .selectAccount(let accountAction), .switchAccount(let accountAction):
            let closeOtherWindows: Bool
            if case .selectAccount = action {
                closeOtherWindows = false
            } else {
                closeOtherWindows = true
            }
            
            let windowController = Window.showNew(closeOthers: closeOtherWindows)
            windowNumber = windowController.window?.windowNumber
            let accountsList = instantiate(AccountsListViewController.self)
            accountsList.selectAccountAction = accountAction
            windowController.contentViewController = accountsList
        case .approveMessage(let action):
            let windowController = Window.showNew(closeOthers: false)
            windowNumber = windowController.window?.windowNumber
            showApprove(windowController: windowController,
                        browser: .safari,
                        subject: action.subject,
                        meta: action.meta,
                        account: action.account,
                        walletId: action.walletId,
                        peerMeta: action.peerMeta,
                        solanaClusterSelection: action.solanaClusterSelection,
                        completion: action.completion)
        case .approveTransaction(let action):
            let windowController = Window.showNew(closeOthers: false)
            windowNumber = windowController.window?.windowNumber
            showApprove(windowController: windowController, browser: .safari, transaction: action.transaction, account: action.account, walletId: action.walletId, chain: action.chain, peerMeta: action.peerMeta, completion: action.completion)
        case .justShowApp:
            let windowController = Window.showNew(closeOthers: true)
            windowNumber = windowController.window?.windowNumber
            let accountsList = instantiate(AccountsListViewController.self)
            windowController.contentViewController = accountsList
        case .addEthereumChain(let action):
            let alert = Alert()
            alert.messageText = Strings.addNetwork
            alert.informativeText = action.chainToAdd.chainName + "\n\n" + action.chainToAdd.defaultRpcUrl
            alert.alertStyle = .informational
            alert.addButton(withTitle: Strings.ok)
            alert.addButton(withTitle: Strings.cancel)
            action.completion(alert.runModal() == .alertFirstButtonReturn)
        case let .showMessage(message, subtitle, completion):
            let alert = Alert()
            alert.messageText = message
            alert.informativeText = subtitle
            alert.alertStyle = .informational
            alert.addButton(withTitle: Strings.ok)
            _ = alert.runModal()
            completion?()
        }
    }
    
}

private extension Agent.ExternalRequest {

    var isPending: Bool {
        switch self {
        case .safari(let request):
            return ExtensionBridge.hasPendingRequest(id: request.id)
        }
    }

    func cancelIfPending() {
        switch self {
        case .safari(let request):
            guard ExtensionBridge.hasPendingRequest(id: request.id) else { return }
            ExtensionBridge.removeRequest(id: request.id)
            ExtensionBridge.respond(response: ResponseToExtension(for: request, error: Strings.canceled))
        }
    }

    func matches(_ other: Agent.ExternalRequest) -> Bool {
        switch (self, other) {
        case (.safari(let lhs), .safari(let rhs)):
            return lhs.id == rhs.id
        }
    }

}

private enum DockAppLauncher {

    static func openDockApp() {
        guard let dockAppURL = dockAppURL else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: dockAppURL, configuration: configuration)
    }

    private static var dockAppURL: URL? {
        guard Bundle.main.bundleIdentifier == Identifiers.macOSAmbientBundle else { return nil }

        var url = Bundle.main.bundleURL
        for _ in 0..<3 {
            url.deleteLastPathComponent()
        }
        guard url.pathExtension == "app",
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

}
