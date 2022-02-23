// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import UIKit
import SwiftUI

extension Image {
    public init(packageResource name: String, ofType type: String) {
        #if canImport(UIKit)
        guard let path = Bundle.main.path(forResource: name, ofType: type),
              let image = UIImage(contentsOfFile: path) else {
            self.init(name)
            return
        }
        self.init(uiImage: image)
        #elseif canImport(AppKit)
        guard let path = Bundle.module.path(forResource: name, ofType: type),
              let image = NSImage(contentsOfFile: path) else {
            self.init(name)
            return
        }
        self.init(nsImage: image)
        #else
        self.init(name)
        #endif
    }
    
    public init(_ name: String, defaultImage: String) {
        if let img = UIImage(named: name) {
            self.init(uiImage: img)
        } else {
            self.init(defaultImage)
        }
    }
        
    public init(_ name: String, defaultSystemImage: String) {
        if let img = UIImage(named: name) {
            self.init(uiImage: img)
        } else {
            self.init(systemName: defaultSystemImage)
        }
    }
    
    public init(_ image: UIImage?, defaultImage: String) {
        if let image = image {
            self.init(uiImage: image)
        } else {
            self.init(defaultImage)
        }
    }
}
