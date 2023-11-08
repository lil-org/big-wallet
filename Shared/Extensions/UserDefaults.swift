// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

extension UserDefaults {
    
    func setCodable<T: Codable>(_ value: T, forKey: String) {
        let data = try? JSONEncoder().encode(value)
        set(data, forKey: forKey)
    }

    func codableValue<T: Codable>(type: T.Type, forKey: String) -> T? {
        guard let data = data(forKey: forKey),
            let value = try? JSONDecoder().decode(type, from: data) else {
            return nil
        }
        return value
    }
    
}
