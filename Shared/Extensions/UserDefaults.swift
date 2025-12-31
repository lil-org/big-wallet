// ∅ 2026 lil org

import Foundation

extension UserDefaults {
    
    func setCodable<T: Codable>(_ value: T, forKey key: String) {
        let data = try? JSONEncoder().encode(value)
        set(data, forKey: key)
    }

    func codableValue<T: Codable>(type: T.Type, forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    
}
