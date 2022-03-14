// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI

struct SimpleToast: View {
    struct ViewModel {
        var title: String
        var icon: Image
    }
    
    private var screen: CGRect {
        #if os(iOS)
        return UIScreen.main.bounds
        #else
        return NSScreen.main?.frame ?? .zero
        #endif
    }
    
    let viewModel: ViewModel
    
    @Binding
    var isShown: Bool
    
    var body: some View {
        ZStack(alignment: .center) {
            VStack {

                Spacer()
                HStack {
                    self.viewModel.icon
                    Text(self.viewModel.title)
                }
                .font(.headline)
                .foregroundColor(.primary)
                .padding([.top, .bottom], 20)
                .padding([.leading, .trailing], 40)
                .background(.ultraThinMaterial)
                .background(Color.secondarySystemBackground)
                .clipShape(Capsule())
            }
            
        }
        .frame(width: screen.width / 1.25)
        .transition(AnyTransition.move(edge: .bottom).combined(with: .opacity))
        .onTapGesture {
            withAnimation {
                self.isShown = false
            }
        }.onAppear(perform: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation {
                    self.isShown = false
                }
            }
        })
    }
}
