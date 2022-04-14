// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

extension FileManager {
    func directoryExists(atPath: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileExists(atPath: atPath, isDirectory: &isDirectory)
        return isDirectory.boolValue && exists
    }
}
