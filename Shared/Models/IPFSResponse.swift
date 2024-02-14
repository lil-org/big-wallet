// ∅ 2024 lil org

import Foundation

struct IPFSResponse: Codable {
    let name: String
    let hash: String
    let size: String
    
    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case hash = "Hash"
        case size = "Size"
    }
}
