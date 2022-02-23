// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import ComposableArchitecture
import SwiftUI

extension Reducer {
    public static func strict(
        _ reducer: @escaping (inout State, Action) -> (Environment) -> Effect<Action, Never>
    ) -> Reducer {
        Self { state, action, environment in
            reducer(&state, action)(environment)
        }
    }
}
