// Copyright © 2023 Tokenary. All rights reserved.

import SwiftUI

extension Image {
    
    static var checkmark: Image { systemName("checkmark") }
    
    private static func systemName(_ systemName: String) -> Image {
        return Image(systemName: systemName)
    }
    
}
