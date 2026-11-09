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
    private let validateExport: @MainActor (WalletExportedSecret) async -> Bool
    private var validationTask: Task<Void, Never>?
    private var sourceRevision: UInt64 = 0

    init(validateExport: @escaping @MainActor (WalletExportedSecret) async -> Bool) {
        self.validateExport = validateExport
    }

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

    func validate(_ token: Token, then completion: @escaping @MainActor (WalletExportedSecret?) -> Void) {
        guard isCurrent(token), let secret else { completion(nil); return }
        validationTask?.cancel()
        validationTask = Task { [weak self, validateExport] in
            while !Task.isCancelled, let revision = self?.sourceRevision {
                let valid = await validateExport(secret)
                guard !Task.isCancelled, let self, isCurrent(token), self.secret === secret else { return }
                guard revision == sourceRevision else { continue }
                validationTask = nil
                completion(valid ? secret : nil)
                return
            }
        }
    }

    func sourceDidChange(_ completion: @escaping @MainActor (Token, WalletExportedSecret?) -> Void) {
        sourceRevision &+= 1
        guard validationTask == nil, let token, secret != nil else { return }
        validate(token) { completion(token, $0) }
    }

    func invalidate() {
        token = nil
        validationTask?.cancel()
        validationTask = nil
        secret?.invalidate()
        secret = nil
    }

    isolated deinit { secret?.invalidate() }
}
