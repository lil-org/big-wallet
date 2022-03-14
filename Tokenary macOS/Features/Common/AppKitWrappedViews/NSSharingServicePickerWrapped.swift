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
        if self.isPresented {
            let picker = NSSharingServicePicker(items: self.config.sharingItems).then {
                $0.delegate = context.coordinator
            }

            // !! MUST BE CALLED IN ASYNC, otherwise blocks update
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
            for name in self.parent.config.excludedSharingServiceNames {
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

            // do here whatever more needed here with selected service

            sharingServicePicker.delegate = nil   // << cleanup
            self.parent.isPresented = false        // << dismiss
        }
    }
}

extension View {
    func activityShare(
        isPresented: Binding<Bool>,
        config: NSSharingServicePickerWrapped.Config
    ) -> some View {
        self.background(
            NSSharingServicePickerWrapped(isPresented: isPresented, config: config)
        )
    }
}
