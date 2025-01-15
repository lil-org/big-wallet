// ∅ 2025 lil org

import Foundation

struct SharedDefaults {
    
#if os(macOS)
    static let defaults = UserDefaults(suiteName: "8DXC3N7E7P.group.org.lil.wallet")
#elseif os(iOS)
    static let defaults = UserDefaults(suiteName: "group.org.lil.wallet")
#endif
    
}
