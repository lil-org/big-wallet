// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI

struct Unwrap<Value, Content: View>: View {
    private let value: Value?
    private let contentProvider: (Value) -> Content

    init(_ value: Value?,
         @ViewBuilder content: @escaping (Value) -> Content) {
        self.value = value
        self.contentProvider = content
    }

    var body: some View {
        value.map(contentProvider)
    }
}

struct Unwrap2<Value1, Value2, Content: View>: View {
    private let value1: Value1?
    private let value2: Value2?
    
    private let contentProvider: (Value1, Value2) -> Content
    
    init(
        _ value1: Value1,
        _ value2: Value2,
        @ViewBuilder contentProvider: @escaping (Value1, Value2) -> Content
    ) {
        self.value1 = value1
        self.value2 = value2
        self.contentProvider = contentProvider
    }
    
    var body: some View {
        value1.flatMap { value1 in value2.flatMap { value2 in self.contentProvider(value1, value2) } }
    }
}
