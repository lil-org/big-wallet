// Copyright © 2021 Encrypted Ink. All rights reserved.

enum AuthenticationReason {
    case start
    case sendTransaction
    case removeAccount
    case showPrivateKey
    case showSecretWords
    case signAction(title: String)
    
    var title: String {
        switch self {
        case .start:
            return "Start"
        case .sendTransaction:
            return "Send Transaction"
        case .removeAccount:
            return "Remove account"
        case .showPrivateKey:
            return "Show private key"
        case .showSecretWords:
            return "Show secret words"
        case .signAction(let title):
            return title
        }
    }
}
