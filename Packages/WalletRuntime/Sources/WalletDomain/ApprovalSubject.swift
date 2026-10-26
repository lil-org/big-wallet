// ∅ 2026 lil org

public enum ApprovalSubject: Sendable {
    case signMessage
    case signPersonalMessage
    case signTypedData
    case approveTransaction
    
    public var asAuthenticationReason: AuthenticationReason {
        switch self {
        case .signMessage:
            return .signMessage
        case .signPersonalMessage:
            return .signPersonalMessage
        case .signTypedData:
            return .signTypedData
        case .approveTransaction:
            return .approveTransaction
        }
    }
    
}
