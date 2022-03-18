// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI

public struct CheckBox: View {
    @State
    private var twoState: Bool = true
    public var body: some View {
        VStack(alignment: .center) {
            Path {
                pPath in
                pPath.move(to: .zero)
                pPath.addLines([
                    CGPoint(x: 0, y: 50),
                    CGPoint(x: 50, y: 100),
                    CGPoint(x: 100, y: 0)
                ])
            }
            .trim(from: 0, to: twoState ? 1.0 : 0)
            .stroke(Color.green, lineWidth: 8)
            .animation(Animation.linear(duration: 1).repeatForever(autoreverses: false))
        }
        .frame(width: 100, height: 100)
        .border(Color.red)
        .onAppear {
            twoState = true
        }
    }
}
