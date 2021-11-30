// Copyright © 2021 Tokenary. All rights reserved.

enum ApprovalSubject {
    case signMessage
    case signPersonalMessage
    case signTypedData
    
    var asAuthenticationReason: AuthenticationReason {
        switch self {
        case .signMessage:
            return .signMessage
        case .signPersonalMessage:
            return .signPersonalMessage
        case .signTypedData:
            return .signTypedData
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
        }
    }
}
