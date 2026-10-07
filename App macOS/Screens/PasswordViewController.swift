// ∅ 2026 lil org

import Cocoa

final class PasswordViewController: NSViewController {
    enum Mode {
        case create, repeatAfterCreate, enter
    }

    enum Availability {
        case ready, saving, unavailable
    }

    enum Action {
        case submit(String), cancel, retry
    }

    struct Configuration {
        let mode: Mode
        var reason: AuthenticationReason? = nil
        var availability: Availability = .ready
    }

    private var configuration = Configuration(mode: .create)
    private var onAction: ((Action) -> Void)?

    @IBOutlet weak var reasonLabel: NSTextField!
    @IBOutlet weak var cancelButton: NSButton!
    @IBOutlet weak var okButton: NSButton!
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet weak var passwordTextField: NSSecureTextField! {
        didSet { passwordTextField.delegate = self }
    }

    static func with(
        configuration: Configuration,
        onAction: @escaping (Action) -> Void
    ) -> PasswordViewController {
        let controller = instantiate(PasswordViewController.self)
        controller.configuration = configuration
        controller.onAction = onAction
        return controller
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        passwordTextField.placeholderString = Strings.password
        cancelButton.title = Strings.cancel
        applyConfiguration()
    }

    func render(_ configuration: Configuration, clearInput: Bool = false) {
        let changedMode = self.configuration.mode != configuration.mode
        self.configuration = configuration
        guard isViewLoaded else { return }
        if changedMode || clearInput || configuration.availability != .ready {
            passwordTextField.stringValue = ""
        }
        applyConfiguration()
    }

    func retire() {
        onAction = nil
        guard isViewLoaded else { return }
        passwordTextField.stringValue = ""
        passwordTextField.isEnabled = false
        okButton.isEnabled = false
        cancelButton.isEnabled = false
    }

    private func applyConfiguration() {
        if let reason = configuration.reason, reason != .start {
            reasonLabel.stringValue = "\(Strings.to) " + reason.title.lowercased()
        } else {
            reasonLabel.stringValue = ""
        }
        titleLabel.stringValue = switch configuration.availability {
        case .unavailable: Strings.failedToLoad
        case .ready, .saving:
            switch configuration.mode {
            case .create: Strings.createPassword
            case .repeatAfterCreate: Strings.repeatPassword
            case .enter: Strings.enterPassword
            }
        }
        okButton.title = configuration.availability == .unavailable ? Strings.tryAgain : Strings.ok
        passwordTextField.isEnabled = onAction != nil && configuration.availability == .ready
        cancelButton.isEnabled = onAction != nil && configuration.availability != .saving
        updateSubmitButton()
    }

    private func updateSubmitButton() {
        guard onAction != nil else {
            okButton.isEnabled = false
            return
        }
        switch configuration.availability {
        case .unavailable:
            okButton.isEnabled = true
        case .saving:
            okButton.isEnabled = false
        case .ready:
            okButton.isEnabled = configuration.mode == .enter
                ? !passwordTextField.stringValue.isEmpty
                : passwordTextField.stringValue.isOkAsPassword
        }
    }

    @IBAction func actionButtonTapped(_ sender: Any) {
        guard let onAction else { return }
        switch configuration.availability {
        case .unavailable: onAction(.retry)
        case .saving: break
        case .ready:
            updateSubmitButton()
            guard okButton.isEnabled else { return }
            onAction(.submit(passwordTextField.stringValue))
        }
    }

    @IBAction func cancelButtonTapped(_ sender: NSButton) {
        guard configuration.availability != .saving else { return }
        onAction?(.cancel)
    }
}

extension PasswordViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        updateSubmitButton()
    }
}
