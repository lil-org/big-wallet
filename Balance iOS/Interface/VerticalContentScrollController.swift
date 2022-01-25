import UIKit
import NativeUIKit
import SparrowKit

class VerticalContentScrollController: SPScrollController {
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        scrollView.alwaysBounceVertical = true
        scrollView.contentInset = .init(
            top: NativeLayout.Spaces.Scroll.top_inset_transparent_navigation,
            left: .zero,
            bottom: NativeLayout.Spaces.Scroll.bottom_inset_reach_end,
            right: .zero
        )
        navigationController?.navigationBar.setAppearance(.transparentStandardOnly)
    }
}
