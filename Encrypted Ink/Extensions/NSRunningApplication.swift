// Copyright © 2021 Encrypted Ink. All rights reserved.

import AppKit

extension NSRunningApplication {
    
    static var isGoogleChromeRunning: Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome")
        return !apps.isEmpty
    }
}
