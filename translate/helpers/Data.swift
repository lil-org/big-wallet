// ∅ 2025 lil org

import Foundation

extension Data {
    
    func fnv1aHash() -> UInt64 {
        let prime: UInt64 = 1099511628211
        var hash: UInt64 = 14695981039346656037
        forEach { byte in
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }
    
}
