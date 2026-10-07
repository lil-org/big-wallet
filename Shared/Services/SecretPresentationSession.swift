import Foundation

@MainActor
final class SecretPresentationSession {
    struct Token: Equatable, Sendable {
        fileprivate let identifier = UUID()
    }

    private var token: Token?
    private var secret: String?

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
    func store(_ secret: String, for token: Token) -> Bool {
        guard isCurrent(token) else { return false }
        self.secret = secret
        return true
    }

    func value(for token: Token) -> String? {
        isCurrent(token) ? secret : nil
    }

    func invalidate() {
        token = nil
        secret = nil
    }
}
