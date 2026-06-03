// ∅ 2026 lil org

import UIKit

func loadNib<View: UIView>(_ type: View.Type) -> View {
    return Bundle.main.loadNibNamed(String(describing: type), owner: nil, options: nil)![0] as! View
}
