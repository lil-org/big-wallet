// Copyright © 2021 Tokenary. All rights reserved.

enum ApprovalSubject {
    case signMessage
    case signPersonalMessage
    case signTypedData
    case approveTransaction
    
    var asAuthenticationReason: AuthenticationReason {
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
    
    var title: String {
        switch self {
        case .signMessage:
            return Strings.signMessage
        case .signPersonalMessage:
            return Strings.signPersonalMessage
        case .signTypedData:
            return Strings.signTypedData
        case .approveTransaction:
            return Strings.approveTransaction
        }
    }
}
