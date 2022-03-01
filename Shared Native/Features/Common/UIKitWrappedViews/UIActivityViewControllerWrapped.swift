// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI

struct UIActivityViewControllerWrapper: UIViewControllerRepresentable {
    struct Config {
        let activityItems: [Any]
        var applicationActivities: [UIActivity]?
        var excludedActivityTypes: [UIActivity.ActivityType]?
    }

    @Binding
    var isPresented: Bool

    private let activityVCWrapper: UIActivityViewController

    init(
        isPresented: Binding<Bool>,
        config: Config
    ) {
        self._isPresented = isPresented
        self.activityVCWrapper = UIActivityViewController(
            activityItems: config.activityItems,
            applicationActivities: config.applicationActivities
        ).then {
            $0.completionWithItemsHandler = { _, _, _, _ in
                isPresented.wrappedValue = false
            }
            $0.excludedActivityTypes = config.excludedActivityTypes
        }
    }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(
        _ uiViewController: UIViewController,
        context: Context
    ) {
        if self.isPresented, self.activityVCWrapper.view.window == nil {
            uiViewController.present(activityVCWrapper, animated: true, completion: nil)
        } else if !self.isPresented, self.activityVCWrapper.view.window != nil {
            self.activityVCWrapper.dismissAnimated()
        }
    }
}

extension View {
    func activityShare(
        isPresented: Binding<Bool>,
        config: UIActivityViewControllerWrapper.Config
    ) -> some View {
        self.background(
            UIActivityViewControllerWrapper(isPresented: isPresented, config: config)
        )
    }
}
