import WalletDomain
import WalletAuthority
import WalletNetworking
import Cocoa

@MainActor
final class NativeSecretAlertPresentation: NSObject {
    let token: SecretPresentationSession.Token
    let alert = Alert()
    let secretField = NSTextField(wrappingLabelWithString: "")

    private let session: SecretPresentationSession
    private let canCopy: () -> Bool
    private let copy: (String) -> Void
    private let didEnd: () -> Void
    private var hasEnded = false

    static func acceptsKeyWindow(
        _ keyWindow: NSWindow?,
        owner: NSWindow,
        presentation: NativeSecretAlertPresentation?
    ) -> Bool {
        guard let keyWindow, keyWindow.isKeyWindow else { return false }
        return keyWindow === owner || keyWindow === presentation?.alert.window
    }

    init(
        session: SecretPresentationSession,
        token: SecretPresentationSession.Token,
        title: String,
        canCopy: @escaping () -> Bool,
        copy: @escaping (String) -> Void = { SecretClipboard.shared.copy($0) },
        didEnd: @escaping () -> Void = {}
    ) {
        self.session = session
        self.token = token
        self.canCopy = canCopy
        self.copy = copy
        self.didEnd = didEnd
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
        guard !hasEnded, let secret = session.value(for: token), canCopy() else {
            dismiss()
            return
        }
        secretField.stringValue = secret
        secretField.frame = NSRect(x: 0, y: 0, width: 320, height: secretField.fittingSize.height)
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.finish(response)
        }
    }

    @objc private func copyButtonClicked() {
        finish(.alertSecondButtonReturn)
    }

    func finish(_ response: NSApplication.ModalResponse) {
        guard !hasEnded else { return }
        let secret = response == .alertSecondButtonReturn && canCopy()
            ? session.value(for: token) : nil
        dismiss()
        if let secret { copy(secret) }
    }

    func dismiss() {
        guard !hasEnded else { return }
        hasEnded = true
        secretField.stringValue = ""
        alert.informativeText = ""
        if session.isCurrent(token) { session.invalidate() }
        if let window = alert.window.sheetParent {
            window.endSheet(alert.window, returnCode: .abort)
        }
        alert.window.orderOut(nil)
        didEnd()
    }
}
