import WalletDomain
import WalletAuthority
import WalletNetworking

extension PeerMeta {
    var name: String {
        return title ?? Strings.unknownWebsite
    }
    
}
