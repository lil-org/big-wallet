// ∅ 2026 lil org

enum AuthenticationReason {
    case start
    case removeWallet
    case showPrivateKey
    case showSecretWords

    var title: String {
        switch self {
        case .start:
            return Strings.start
        case .removeWallet:
            return Strings.removeWallet
        case .showPrivateKey:
            return Strings.showPrivateKey
        case .showSecretWords:
            return Strings.showSecretWords
        }
    }
}
