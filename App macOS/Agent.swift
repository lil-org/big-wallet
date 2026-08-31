// ∅ 2026 lil org

import Cocoa

class Agent: NSObject {

    static let shared = Agent()

    private override init() { super.init() }
    private var didEnterPasswordOnStart = false

    private var didStartInitialLAEvaluation = false
    private var didCompleteInitialLAEvaluation = false

    private var hasPassword: Bool {
        return Keychain.shared.password != nil
    }

    func showInitialScreen() {
        let isEvaluatingInitialLA = didStartInitialLAEvaluation && !didCompleteInitialLAEvaluation
        guard !isEvaluatingInitialLA else { return }

        guard hasPassword else {
            let welcomeViewController = WelcomeViewController.new { [weak self] createdPassword in
                guard let self else { return }
                if createdPassword {
                    self.didEnterPasswordOnStart = true
                    self.didCompleteInitialLAEvaluation = true
                } else {
                    guard self.hasPassword else { return }
                    self.didEnterPasswordOnStart = false
                }
                self.showInitialScreen()
            }
            let windowController = Window.showNew(closeOthers: true)
            windowController.contentViewController = welcomeViewController
            return
        }

        guard didEnterPasswordOnStart else {
            askAuthentication(on: nil, onStart: true, reason: .start) { [weak self] success in
                if success {
                    self?.didEnterPasswordOnStart = true
                    self?.showInitialScreen()
                }
            }
            return
        }

        let accountsList = instantiate(AccountsListViewController.self)
        let windowController = Window.showNew(closeOthers: true)
        windowController.contentViewController = accountsList
    }

    func open() {
        showInitialScreen()
    }

    func askAuthentication(
        on: NSWindow?,
        getBackTo: NSViewController? = nil,
        onStart: Bool,
        reason: AuthenticationReason,
        completion: @escaping (Bool) -> Void
    ) {
        func showPasswordScreen() {
            let window = on ?? Window.showNew(closeOthers: onStart).window
            let passwordViewController = PasswordViewController.with(
                mode: .enter,
                reason: reason
            ) { [weak window] success in
                if let getBackTo = getBackTo {
                    window?.contentViewController = getBackTo
                } else {
                    Window.closeWindow(idToClose: window?.windowNumber)
                }
                completion(success)
            }
            window?.contentViewController = passwordViewController
        }

        // Gate on canUseBiometrics rather than letting attemptBiometrics report the unavailable
        // case: it reports asynchronously, and showPasswordScreen has to run in the same turn of
        // the run loop as the launch that asked for it.
        guard DeviceAuthentication.canUseBiometrics else {
            showPasswordScreen()
            return
        }

        didStartInitialLAEvaluation = true
        DeviceAuthentication.attemptBiometrics(reason: reason.title) { [weak self] outcome in
            let success = outcome == .succeeded
            self?.didCompleteInitialLAEvaluation = true
            if !success, onStart, self?.didEnterPasswordOnStart == false {
                showPasswordScreen()
            }
            completion(success)
        }
    }

}
