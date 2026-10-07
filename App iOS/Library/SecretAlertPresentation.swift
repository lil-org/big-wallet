import UIKit

@MainActor
final class SecretAlertPresentation {
    typealias Token = SecretPresentationSession.Token

    private let session = SecretPresentationSession()
    private let isActive: () -> Bool
    private let copy: (String) -> Void
    private(set) var alert: UIAlertController?

    init(
        isActive: @escaping () -> Bool,
        copy: @escaping (String) -> Void = { SecretClipboard.shared.copy($0) }
    ) {
        self.isActive = isActive
        self.copy = copy
    }

    isolated deinit {
        invalidate()
    }

    func begin() -> Token? {
        invalidate()
        guard isActive() else { return nil }
        return session.begin()
    }

    func accepts(_ token: Token) -> Bool {
        session.isCurrent(token) && isActive()
    }

    func show(_ secret: String, title: String, token: Token, from presenter: UIViewController, completion: (() -> Void)? = nil) {
        guard accepts(token), session.store(secret, for: token) else { return }
        let alert = UIAlertController(title: title, message: secret, preferredStyle: .alert)
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
        if copying, accepts(token), let secret = session.value(for: token) {
            copy(secret)
        }
        invalidate()
    }

    func invalidate() {
        session.invalidate()
        let previous = alert
        alert = nil
        previous?.message = nil
        previous?.viewIfLoaded?.isHidden = true
        previous?.dismissAfterCurrentTransition(animated: false)
    }
}
