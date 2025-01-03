// ∅ 2025 lil org

import Foundation

let semaphore = DispatchSemaphore(value: 0)
let queue = DispatchQueue(label: UUID().uuidString, qos: .default)
let projectDir = FileManager.default.currentDirectoryPath

translateAppStoreMetadata(.highQuality)
translateAllStrings(.highQuality)

print("🟢 all done")
