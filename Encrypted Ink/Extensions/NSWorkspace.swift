// Copyright © 2021 Encrypted Ink. All rights reserved.

import AppKit

extension NSWorkspace {
    
    static func googleChromeIsRunning() -> Bool {
        let apps = NSWorkspace.shared.runningApplications
        return apps.contains(where: { $0.bundleIdentifier == "com.google.Chrome" })
    }
}
