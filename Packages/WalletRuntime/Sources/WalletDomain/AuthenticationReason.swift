// ∅ 2026 lil org

public enum AuthenticationReason: Sendable {
    case start
    case sendTransaction
    case removeWallet
    case showPrivateKey
    case showSecretWords
    case signMessage
    case signPersonalMessage
    case signTypedData
    case approveTransaction
    
}
