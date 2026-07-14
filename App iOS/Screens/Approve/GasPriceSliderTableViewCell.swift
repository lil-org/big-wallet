// ∅ 2026 lil org

import UIKit

protocol GasPriceSliderDelegate: AnyObject {
    
    func sliderInteractionStarted()
    func sliderInteractionEnded()
    func sliderValueChanged(value: Double)
    
}

class GasPriceSliderTableViewCell: UITableViewCell {

    let slowSpeedLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isOpaque = false
        label.contentMode = .left
        label.text = "🐢"
        label.font = .systemFont(ofSize: 17)
        label.setContentHuggingPriority(UILayoutPriority(251), for: .horizontal)
        label.setContentHuggingPriority(UILayoutPriority(251), for: .vertical)
        return label
    }()

    let fastSpeedLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isOpaque = false
        label.contentMode = .left
        label.text = "🐇"
        label.font = .systemFont(ofSize: 17)
        label.setContentHuggingPriority(UILayoutPriority(251), for: .horizontal)
        label.setContentHuggingPriority(UILayoutPriority(251), for: .vertical)
        return label
    }()

    private weak var sliderDelegate: GasPriceSliderDelegate?

    let slider: UISlider = {
        let slider = UISlider()
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.minimumValue = 0
        slider.maximumValue = 100
        slider.value = 33
        slider.isContinuous = true
        return slider
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupViewHierarchy()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViewHierarchy()
    }

    @IBAction func sliderInteractionStarted(_ sender: Any) {
        sliderDelegate?.sliderInteractionStarted()
    }

    @IBAction func sliderInteractionEnded(_ sender: Any) {
        sliderDelegate?.sliderInteractionEnded()
    }
    
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

    private func setupViewHierarchy() {
        contentView.isOpaque = false
        contentView.clipsToBounds = true
        contentView.isMultipleTouchEnabled = true
        contentView.contentMode = .center

        contentView.addSubview(slowSpeedLabel)
        contentView.addSubview(fastSpeedLabel)
        contentView.addSubview(slider)

        slider.addTarget(self, action: #selector(sliderInteractionStarted(_:)), for: .touchDown)
        slider.addTarget(self, action: #selector(sliderInteractionEnded(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        slider.addTarget(self, action: #selector(sliderValueChanged(_:)), for: .valueChanged)

        NSLayoutConstraint.activate([
            slowSpeedLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            slowSpeedLabel.centerYAnchor.constraint(equalTo: slider.centerYAnchor),

            slider.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            slider.leadingAnchor.constraint(equalTo: slowSpeedLabel.trailingAnchor, constant: 8),
            slider.heightAnchor.constraint(equalToConstant: 33),
            contentView.bottomAnchor.constraint(equalTo: slider.bottomAnchor, constant: 16),

            fastSpeedLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 8),
            fastSpeedLabel.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            contentView.trailingAnchor.constraint(equalTo: fastSpeedLabel.trailingAnchor, constant: 20)
        ])
    }
    
}
