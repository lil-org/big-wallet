// Copyright © 2021 Encrypted Ink. All rights reserved.

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
            return "Start"
        case .sendTransaction:
            return Strings.sendTransaction
        case .removeAccount:
            return "Remove account"
        case .showPrivateKey:
            return "Show private key"
        case .showSecretWords:
            return "Show secret words"
        case .signMessage:
            return Strings.signMessage
        case .signPersonalMessage:
            return Strings.signPersonalMessage
        case .signTypedData:
            return Strings.signTypedData
        }
    }
}
