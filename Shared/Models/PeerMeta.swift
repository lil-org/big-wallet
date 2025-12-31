// ∅ 2026 lil org

import Foundation

struct PeerMeta {
    
    let title: String?
    let iconURLString: String?
    
    var name: String {
        return title ?? Strings.unknownWebsite
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
