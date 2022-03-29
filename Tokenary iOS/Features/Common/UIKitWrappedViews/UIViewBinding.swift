// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI
import UIKit

struct UIViewBinding: UIViewRepresentable {
    let binding: Binding<UIView?>

    init(as binding: Binding<UIView?>) {
        self.binding = binding
    }

    class Coordinator {
        var binding: Binding<UIView?>
        
        init(binding: Binding<UIView?>) {
            self.binding = binding
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(binding: binding)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        binding.wrappedValue = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.binding.wrappedValue = nil
        context.coordinator.binding = binding
        binding.wrappedValue = view
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.binding.wrappedValue = nil
    }
}
