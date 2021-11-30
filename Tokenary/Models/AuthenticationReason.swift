// Copyright © 2021 Tokenary. All rights reserved.

enum AuthenticationReason {
    case start
    case sendTransaction
    case removeAccount
    case showPrivateKey
    case showSecretWords
    case signMessage
    case signPersonalMessage
    case signTypedData
    
    var title: String {
        switch self {
        case .start:
            return Strings.start
        case .sendTransaction:
            return Strings.sendTransaction
        case .removeAccount:
            return Strings.removeAccount
        case .showPrivateKey:
            return Strings.showPrivateKey
        case .showSecretWords:
            return Strings.showSecretWords
        case .signMessage:
            return Strings.signMessage
        case .signPersonalMessage:
            return Strings.signPersonalMessage
        case .signTypedData:
            return Strings.signTypedData
        }
    }
}
