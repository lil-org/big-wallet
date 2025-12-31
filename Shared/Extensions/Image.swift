// ∅ 2026 lil org

import SwiftUI

extension Image {
    
    static var checkmark: Image { systemName("checkmark") }
    
    private static func systemName(_ systemName: String) -> Image {
        Image(systemName: systemName)
    }
    
}
