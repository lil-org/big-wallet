// Copyright © 2022 Tokenary. All rights reserved.
//

import Foundation

public struct LaunchFlagHelper {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }
    private static var environmentArguments: [String: String] { ProcessInfo.processInfo.environment }

    public static var rawEnv: String {
        var rawEnv: String = .empty
        for (key, val) in self.environmentArguments {
            guard !key.contains("SIMUL") else { continue }
            if val.count > 10 {
                rawEnv += "\n \(key) \(val.prefix(10))"
            } else {
                rawEnv += "\n \(key) \(val)"
            }
        }
        return rawEnv
    }

    public static var areAnimationsDisabled: Bool {
        self.arguments.contains("disableAnimations")
    }

    public static var serverPort: Int {
        guard
            let strPort = self.environmentArguments["serverPort"],
            let port = Int(strPort),
            port != .zero
        else { return Constants.defaultPort }
        return port
    }
}
