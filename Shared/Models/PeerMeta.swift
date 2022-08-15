// Copyright © 2021 Tokenary. All rights reserved.

import Foundation
import WalletConnect

struct PeerMeta {
    
    let title: String?
    let iconURLString: String?
    
    var name: String {
        return title ?? Strings.unknownWebsite
    }
 
    init(wcPeerMeta: WCPeerMeta?) {
        self.title = wcPeerMeta?.name
        self.iconURLString = wcPeerMeta?.icons.first
    }
    
    init(title: String?, iconURLString: String?) {
        self.title = title
        self.iconURLString = iconURLString
    }
    
}

extension SafariRequest {
    
    var peerMeta: PeerMeta {
        return PeerMeta(title: host, iconURLString: favicon)
    }
    
}
