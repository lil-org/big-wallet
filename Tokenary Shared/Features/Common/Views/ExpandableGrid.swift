// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI

/// This layouts elements on all it's given width, so external padding needs to be enforced
struct ExpandableGrid<
    ElementData: RandomAccessCollection,
    ElementView: View,
    ElementIndex: Hashable // rewrite using Identifiable
>: View {
    
    @Environment(\.expandableGridStyle)
    private var expandableGridStyle: ExpandableGridStyle
    
    @State
    private var activeElementIndex: Int = .zero
    
    @State
    private var alignmentGuides: [AnyHashable: CGPoint] = [:]
    
    fileprivate let elementData: ElementData
    fileprivate let elementView: (ElementData.Element) -> ElementView
    fileprivate let elementIndex: KeyPath<ElementData.Element, ElementIndex>
    
    @State
    private var gridHeight: CGFloat = .zero
    
    var body: some View {
        GeometryReader { geometryProxy in
            ZStack(alignment: .topLeading) {
                ForEach(elementData, id: elementIndex) { currentElementData in
                    
                    elementView(currentElementData)
                        .modifier(
                            ExpandableGridElementModifier(
                                activeElementIndex: $activeElementIndex,
                                elementIndex: currentElementData[keyPath: elementIndex]
                            )
                        )
                        .alignmentGuide(.top, computeValue: { _ in
                            alignmentGuides[currentElementData[keyPath: elementIndex], default: .zero].y
                        })
                        .alignmentGuide(.leading, computeValue: { _ in
                            alignmentGuides[currentElementData[keyPath: elementIndex], default: .zero].x
                        })
                        .opacity(alignmentGuides[currentElementData[keyPath: elementIndex]] == nil ? 1 : .zero)
                }
            }.onPreferenceChange(ExpandableGridPreferenceKey.self, perform: { preferences in
                positionElements(using: geometryProxy, having: preferences)
            })
        }
    }
    
    private func positionElements(
        using geometryProxy: GeometryProxy,
        having preferencesData: [ExpandableGridPreferenceData]
    ) {
        DispatchQueue.global(qos: .userInteractive).async {
            // Here we preform simplest possible plane tiling with rectangles
            //  All rectangles are assumed to have the same height
            
            var currentAlignmentGuides: [AnyHashable: CGPoint] = [:]
            var currentGridHeight: CGFloat = .zero
            var widths: [CGFloat] = [.zero]
            var currentRowIndex: Int = .zero
            
            preferencesData.forEach { elementPreference in
                let currentRowWidth = widths[currentRowIndex]
                let elementBounds = geometryProxy[elementPreference.bounds]
                let elementWidth = elementBounds.width + self.expandableGridStyle.hSpacing
                
                let offset: CGPoint
                if currentRowWidth + elementWidth < geometryProxy.size.width {
                    widths[currentRowIndex] += elementWidth
                    offset = .init(
                        x: -currentRowWidth, y: -currentGridHeight
                    )
                } else {
                    currentRowIndex += 1
                    widths.append(elementWidth)
                    currentGridHeight += expandableGridStyle.vSpacing
                    offset = .init(
                        x: .zero, y: -currentGridHeight
                    )
                }
                currentAlignmentGuides[elementPreference.index] = offset
            }
            
            DispatchQueue.main.async {
                let gridHeight = currentGridHeight.isZero ? currentGridHeight : self.expandableGridStyle.vSpacing
                self.alignmentGuides = currentAlignmentGuides
                self.gridHeight = gridHeight - self.expandableGridStyle.vSpacing
            }
        }
    }
}

private struct ExpandableGridStyleKey: EnvironmentKey {
    static let defaultValue = ExpandableGridStyle(hSpacing: 8, vSpacing: 8)
}

private struct ExpandableGridStyle {
    let hSpacing: CGFloat
    let vSpacing: CGFloat
}

private extension EnvironmentValues {
    var expandableGridStyle: ExpandableGridStyle {
        get { self[ExpandableGridStyleKey.self] }
        set { self[ExpandableGridStyleKey.self] = newValue }
    }
}

private struct ExpandableGridPreferenceData: Equatable {
    let index: AnyHashable
    let bounds: Anchor<CGRect>
}

private struct ExpandableGridPreferenceKey: PreferenceKey {
    static var defaultValue: [ExpandableGridPreferenceData] = []
    
    static func reduce(value: inout [ExpandableGridPreferenceData], nextValue: () -> [ExpandableGridPreferenceData]) {
        value.append(contentsOf: nextValue())
    }
}

private struct ExpandableGridElementModifier<ElementIndex: Hashable>: ViewModifier {
    @Binding
    var activeElementIndex: Int
    let elementIndex: ElementIndex
    
    private var geometryProxiedView: some View {
        Color.clear
            .anchorPreference(
                key: ExpandableGridPreferenceKey.self,
                value: .bounds,
                transform: {[
                    ExpandableGridPreferenceData(index: AnyHashable(elementIndex), bounds: $0)
                ]}
            )
    }
    
    func body(content: Content) -> some View { content.background(geometryProxiedView) }
}

extension ExpandableGrid where ElementIndex == ElementData.Element.ID, ElementData.Element: Identifiable {
    init(_ data: ElementData, content: @escaping (ElementData.Element) -> ElementView) {
        self.elementData = data
        self.elementIndex = \ElementData.Element.id
        self.elementView = content
    }
}

extension View {
    func expandableGridStyle(
        hSpacing: CGFloat = 8,
        vSpacing: CGFloat = 8,
        animation: Animation? = .default
    ) -> some View {
        let style = ExpandableGridStyle(
            hSpacing: hSpacing, vSpacing: vSpacing
        )
        return environment(\.expandableGridStyle, style)
    }
}
