// Copyright © 2022 Tokenary. All rights reserved.

import AppKit
import SwiftUI

struct NSSharingServicePickerWrapped: NSViewRepresentable {
    @Binding var isPresented: Bool
    struct Config {
        let sharingItems: [Any]
        var excludedSharingServiceNames: [NSSharingService.Name]
    }
    var config: Config

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isPresented {
            let picker = NSSharingServicePicker(items: config.sharingItems).then {
                $0.delegate = context.coordinator
            }

            DispatchQueue.main.async {
                picker.show(relativeTo: .zero, of: nsView, preferredEdge: .minY)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    class Coordinator: NSObject, NSSharingServicePickerDelegate {
        let parent: NSSharingServicePickerWrapped

        init(parent: NSSharingServicePickerWrapped) {
            self.parent = parent
        }
        
        func sharingServicePicker(
            _ sharingServicePicker: NSSharingServicePicker,
            sharingServicesForItems items: [Any],
            proposedSharingServices proposedServices: [NSSharingService]
        ) -> [NSSharingService] {
            var excludedServices = [NSSharingService]()
            for name in parent.config.excludedSharingServiceNames {
                if let service = NSSharingService(named: name) {
                    excludedServices += [service]
                }
            }
            return proposedServices.filter { !excludedServices.contains($0) }
        }

        func sharingServicePicker(
            _ sharingServicePicker: NSSharingServicePicker,
            didChoose service: NSSharingService?
        ) {
            sharingServicePicker.delegate = nil
            parent.isPresented = false
        }
    }
}

extension View {
    func activityShare(
        isPresented: Binding<Bool>,
        config: NSSharingServicePickerWrapped.Config
    ) -> some View {
        background(
            NSSharingServicePickerWrapped(isPresented: isPresented, config: config)
        )
    }
}
