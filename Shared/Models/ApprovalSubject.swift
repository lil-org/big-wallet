import WalletDomain
import WalletAuthority
import WalletNetworking

extension ApprovalSubject {
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
