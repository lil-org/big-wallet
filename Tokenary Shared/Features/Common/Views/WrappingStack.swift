// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import SwiftUI

struct TightHeightGeometryReader<Content: View>: View {
    var alignment: Alignment
    @State
    private var height: CGFloat = .zero

    var content: (GeometryProxy) -> Content
    
    init(
        alignment: Alignment = .topLeading,
        @ViewBuilder content: @escaping (GeometryProxy) -> Content
    ) {
        self.alignment = alignment
        self.content = content
    }
    
    var body: some View {
        GeometryReader { geometryProxy in
            content(geometryProxy)
                .onSizeChange { size in
                    if height != size.height {
                        height = size.height
                    }
                }
                .frame(maxWidth: .infinity, alignment: alignment)
        }
        .frame(height: height)
    }
}

/// Overflowing stack
struct WrappingStack<Data: RandomAccessCollection, ID: Hashable, Content: View>: View {
    
    let data: Data
    var content: (Data.Element) -> Content
    var id: KeyPath<Data.Element, ID>
    
    @Environment(\.wrappingStackStyle)
    private var wrappingStackStyle: WrappingStackStyle
    
    @State private var sizes: [ID: CGSize] = [:]
    @State private var calculatesSizesKeys: Set<ID> = []
    
    private let idsForCalculatingSizes: Set<ID>
    private var dataForCalculatingSizes: [Data.Element] {
        var result: [Data.Element] = []
        var idsToProcess: Set<ID> = idsForCalculatingSizes
        idsToProcess.subtract(calculatesSizesKeys)
        
        data.forEach { item in
            let itemId = item[keyPath: id]
            if idsToProcess.contains(itemId) {
                idsToProcess.remove(itemId)
                result.append(item)
            }
        }
        return result
    }
    
    init(
        id: KeyPath<Data.Element, ID>,
        @ViewBuilder content create: () -> ForEach<Data, ID, Content>
    ) {
        let forEach = create()
        data = forEach.data
        self.content = forEach.content
        self.idsForCalculatingSizes = Set(data.map { $0[keyPath: id] })
        self.id = id
    }
    
    private func splitIntoLines(maxWidth: CGFloat) -> [Range<Data.Index>] {
        var width: CGFloat = 0
        var result: [Range<Data.Index>] = []
        var lineStart = data.startIndex
        var lineLength = 0
        
        for element in data {
            guard let elementWidth = sizes[element[keyPath: id]]?.width else { break }
            let newWidth = width + elementWidth
            if newWidth < maxWidth {
                width = newWidth + wrappingStackStyle.hSpacing
                lineLength += 1
            } else {
                width = elementWidth
                if lineLength == .zero {
                    lineLength += 1
                }
                let lineEnd = data.index(lineStart, offsetBy: lineLength)
                result.append(lineStart ..< lineEnd)
                lineLength = 0
                lineStart = lineEnd
            }
        }
        
        if lineStart != data.endIndex {
            result.append(lineStart ..< data.endIndex)
        }
        return result
    }
    
    var body: some View {
        if calculatesSizesKeys.isSuperset(of: idsForCalculatingSizes) {
            TightHeightGeometryReader(alignment: wrappingStackStyle.alignment) { geometry in
                let splitted = splitIntoLines(maxWidth: geometry.size.width)
                
                // All sizes are known
                VStack(
                    alignment: wrappingStackStyle.alignment.horizontal,
                    spacing: wrappingStackStyle.vSpacing
                ) {
                    ForEach(Array(splitted.enumerated()), id: \.offset) { list in
                        HStack(
                            alignment: wrappingStackStyle.alignment.vertical,
                            spacing: wrappingStackStyle.hSpacing
                        ) {
                            ForEach(data[list.element], id: id) {
                                content($0)
                            }
                        }
                    }
                }
            }
        } else {
            // Calculating sizes
            VStack {
                ForEach(dataForCalculatingSizes, id: id) { d in
                    content(d)
                        .onSizeChange { size in
                            let key = d[keyPath: id]
                            sizes[key] = size
                            calculatesSizesKeys.insert(key)
                        }
                }
            }
        }
    }
}

extension WrappingStack where ID == Data.Element.ID, Data.Element: Identifiable {
    init(
        @ViewBuilder content create: () -> ForEach<Data, ID, Content>
    ) {
        self.init(id: \Data.Element.id, content: create)
    }
}

struct WrappingStackStyleKey: EnvironmentKey {
    static let defaultValue = WrappingStackStyle(hSpacing: 8, vSpacing: 8, alignment: .leading)
}

struct WrappingStackStyle {
    let hSpacing: CGFloat
    let vSpacing: CGFloat
    let alignment: Alignment
}

extension EnvironmentValues {
    var wrappingStackStyle: WrappingStackStyle {
        get { self[WrappingStackStyleKey.self] }
        set { self[WrappingStackStyleKey.self] = newValue }
    }
}

extension View {
    func wrappingStackStyle(
        hSpacing: CGFloat = 8,
        vSpacing: CGFloat = 8,
        alignment: Alignment = .topLeading
    ) -> some View {
        let style = WrappingStackStyle(
            hSpacing: hSpacing, vSpacing: vSpacing, alignment: alignment
        )
        
        return environment(\.wrappingStackStyle, style)
    }
}
