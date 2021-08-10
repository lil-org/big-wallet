// Copyright © 2021 Encrypted Ink. All rights reserved.

enum SigningItem {
    case message
    case personalMessage
    case typedData
    
    var asAuthenticationReason: AuthenticationReason {
        switch self {
        case .message:
            return .signMessage
        case .personalMessage:
            return .signPersonalMessage
        case .typedData:
            return .signTypedData
        }
    }
    
    var title: String {
        switch self {
        case .message:
            return Strings.signMessage
        case .personalMessage:
            return Strings.signPersonalMessage
        case .typedData:
            return Strings.signTypedData
        }
    }
}
