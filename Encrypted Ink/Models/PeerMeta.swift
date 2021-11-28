// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation
import WalletConnect

struct PeerMeta {
    
    let title: String?
    let iconURLString: String?
    
    var name: String {
        return title ?? "Unknown"
    }
 
    init(wcPeerMeta: WCPeerMeta?) {
        self.title = wcPeerMeta?.name
        self.iconURLString = wcPeerMeta?.icons.first
    }
    
}
