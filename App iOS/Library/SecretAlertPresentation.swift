import WalletDomain
import WalletAuthority
import WalletNetworking
import UIKit

@MainActor
final class SecretAlertPresentation {
    typealias Token = SecretPresentationSession.Token

    private let session: SecretPresentationSession
    private let validateSource: () -> Bool
    private let beginCopy: () -> Bool
    private let pasteboardChangeCount: () -> Int
    private let copy: (String) -> Void
    private(set) var alert: UIAlertController?

    init(
        validateSource: @escaping () -> Bool,
        validateExport: @escaping @MainActor (WalletExportedSecret) async -> Bool,
        beginCopy: @escaping () -> Bool = { true },
        pasteboardChangeCount: @escaping () -> Int = { UIPasteboard.general.changeCount },
        copy: @escaping (String) -> Void = { SecretClipboard.shared.copy($0) }
    ) {
        self.validateSource = validateSource
        session = SecretPresentationSession(validateExport: validateExport)
        self.beginCopy = beginCopy
        self.pasteboardChangeCount = pasteboardChangeCount
        self.copy = copy
    }

    isolated deinit {
        invalidate()
    }

    func begin() -> Token? {
        invalidate()
        guard validateSource() else { return nil }
        return session.begin()
    }

    func validate(_ token: Token) -> Bool {
        guard session.isCurrent(token), validateSource() else { return false }
        return session.isCurrent(token)
    }

    func show(_ secret: WalletExportedSecret, title: String, token: Token, from presenter: UIViewController, completion: (() -> Void)? = nil) {
        guard validate(token) else { secret.invalidate(); return }
        guard session.store(secret, for: token) else { return }
        session.validate(token) { [weak self, weak presenter] export in
            guard let self else { return }
            guard let presenter, let export, validate(token) else { invalidate(ifCurrent: token); return }
            present(export, title: title, token: token, from: presenter, completion: completion)
        }
    }

    private func present(_ secret: WalletExportedSecret, title: String, token: Token, from presenter: UIViewController, completion: (() -> Void)?) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        guard secret.withText({ alert.message = $0 }) else { invalidate(ifCurrent: token); return }
        alert.addAction(UIAlertAction(title: Strings.copy, style: .default) { [weak self] _ in
            self?.finish(token, copying: true)
        })
        alert.addAction(UIAlertAction(title: Strings.ok, style: .default) { [weak self] _ in
            self?.finish(token, copying: false)
        })
        self.alert = alert
        presenter.present(alert, animated: true) { [weak self, weak alert] in
            if let alert, self?.alert !== alert {
                alert.viewIfLoaded?.isHidden = true
                alert.dismissAfterCurrentTransition(animated: false)
            }
            completion?()
        }
    }

    func finish(_ token: Token, copying: Bool) {
        guard session.isCurrent(token) else { return }
        guard copying, validate(token) else { invalidate(ifCurrent: token); return }
        let changeCount = pasteboardChangeCount()
        guard beginCopy() else { invalidate(ifCurrent: token); return }
        alert?.message = nil
        session.validate(token) { [weak self] export in
            guard let self else { return }
            defer { invalidate(ifCurrent: token) }
            guard let export, validate(token) else { return }
            export.withText { text in
                if pasteboardChangeCount() == changeCount { copy(text) }
            }
        }
    }

    func invalidate(ifCurrent token: Token? = nil) {
        if let token, !session.isCurrent(token) { return }
        session.invalidate()
        let previous = alert
        alert = nil
        previous?.message = nil
        previous?.viewIfLoaded?.isHidden = true
        previous?.dismissAfterCurrentTransition(animated: false)
    }

    func sourceDidChange() {
        alert?.message = nil
        session.sourceDidChange { [weak self] token, export in
            guard let self else { return }
            guard let export, validate(token), let alert,
                  export.withText({ alert.message = $0 }) else { invalidate(ifCurrent: token); return }
        }
    }
}
