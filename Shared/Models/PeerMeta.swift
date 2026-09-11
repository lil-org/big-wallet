// ∅ 2026 lil org

struct PeerMeta {
    
    let title: String?
    let iconURLString: String?
    
    var name: String {
        return title ?? Strings.unknownWebsite
    }
    
    init(title: String?, iconURLString: String? = nil) {
        self.title = title
        self.iconURLString = iconURLString
    }
    
}

extension SafariRequest {
    
    var peerMeta: PeerMeta {
        return PeerMeta(title: host, iconURLString: favicon)
    }
    
}
