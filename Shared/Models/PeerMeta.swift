// ∅ 2026 lil org

struct PeerMeta {
    
    let title: String?
    
    var name: String {
        return title ?? Strings.unknownWebsite
    }
    
    init(title: String?) {
        self.title = title
    }
    
}

extension SafariRequest {
    
    var peerMeta: PeerMeta {
        return PeerMeta(title: host)
    }
    
}
