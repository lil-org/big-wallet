// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import SPDiffable

open class SPDiffableTableRowTextInputWithLabel: SPDiffableItem {
    open var label: String
    open var value: String
    open var action: Action
    
    public init(
        id: String? = nil,
        label: String,
        value: String,
        action: @escaping Action
    ) {
        self.label = label
        self.value = value
        self.action = action
        super.init(id: id ?? label)
    }
    
    public typealias Action = (_ newValue: String) -> Void
}
