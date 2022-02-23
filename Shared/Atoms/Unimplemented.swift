// Copyright © 2022 Tokenary. All rights reserved.
// Helper for abstract-methods

import Foundation

public func _unimplemented(
  _ function: StaticString, file: StaticString = #file, line: UInt = #line
) -> Never {
  fatalError(
    """
    `\(function)` was called but is not implemented. Be sure to provide an implementation for
    this method when subclassing.
    """,
    file: file,
    line: line
  )
}
