import WalletDomain
import WalletAuthority
import WalletNetworking
import Foundation

@MainActor
final class SecretPresentationSession {
    struct Token: Equatable, Sendable {
        fileprivate let identifier = UUID()
    }

    private var token: Token?
    private var secret: WalletExportedSecret?

    func begin() -> Token {
        invalidate()
        let token = Token()
        self.token = token
        return token
    }

    func isCurrent(_ token: Token) -> Bool {
        self.token == token
    }

    @discardableResult
    func store(_ secret: WalletExportedSecret, for token: Token) -> Bool {
        guard isCurrent(token) else {
            secret.invalidate()
            return false
        }
        self.secret?.invalidate()
        self.secret = secret
        return true
    }

    @discardableResult
    func withText(for token: Token, _ consume: (String) -> Void) -> Bool {
        guard isCurrent(token), let secret else { return false }
        return secret.withText(consume)
    }

    func invalidate() {
        token = nil
        secret?.invalidate()
        secret = nil
    }

    isolated deinit { secret?.invalidate() }
}
