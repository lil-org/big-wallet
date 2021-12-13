// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

protocol GasPriceSliderDelegate: AnyObject {
    
    func sliderValueChanged(value: Double)
    
}

class GasPriceSliderTableViewCell: UITableViewCell {

    @IBOutlet weak var slowSpeedLabel: UILabel!
    @IBOutlet weak var fastSpeedLabel: UILabel!
    private weak var sliderDelegate: GasPriceSliderDelegate?
    @IBOutlet weak var slider: UISlider!
    
    @IBAction func sliderValueChanged(_ sender: Any) {
        sliderDelegate?.sliderValueChanged(value: Double(slider.value))
    }
    
    func setup(value: Double?, isEnabled: Bool, delegate: GasPriceSliderDelegate) {
        sliderDelegate = delegate
        update(value: value, isEnabled: isEnabled)
    }
    
    func update(value: Double?, isEnabled: Bool) {
        slider.isEnabled = isEnabled
        slowSpeedLabel.alpha = isEnabled ? 1 : 0.5
        fastSpeedLabel.alpha = isEnabled ? 1 : 0.5
        if let value = value {
            slider.value = Float(value)
        }
    }
    
}
