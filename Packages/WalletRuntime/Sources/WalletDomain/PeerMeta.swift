// ∅ 2026 lil org

public struct PeerMeta: Sendable {
    
    public let title: String?
    
    public init(title: String?) {
        self.title = title
    }
    
}

extension SafariRequest {
    
    public var peerMeta: PeerMeta {
        return PeerMeta(title: host)
    }
    
}
