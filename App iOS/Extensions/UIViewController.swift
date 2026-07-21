// ∅ 2026 lil org

import ObjectiveC
import UIKit

private var adaptiveLargeTitleAdditionalSafeAreaTopKey: UInt8 = 0

fileprivate final class AdaptiveLargeTitleHeaderView: UIView {

    private enum Constants {
#if os(visionOS)
        // Keep visionOS titles below the navigation material, with enough space
        // to avoid feeling pinned to its lower edge.
        static let topInset: CGFloat = 8
#else
        static let topInset: CGFloat = 0
#endif
        static let bottomInset: CGFloat = 11
        static let horizontalInset: CGFloat = 20
        static let baseFontSize: CGFloat = 34
        static let minimumFontScale: CGFloat = 0.72
        static let preferredMaximumNumberOfLines = 2
    }

    private struct TitleLayout {
        let font: UIFont
        let lineBreakMode: NSLineBreakMode
        let height: CGFloat
    }

    private struct LayoutCache {
        let title: String
        let availableWidth: CGFloat
        let contentSizeCategory: UIContentSizeCategory
        let layout: TitleLayout

        func matches(title: String, availableWidth: CGFloat, contentSizeCategory: UIContentSizeCategory) -> Bool {
            return self.title == title &&
                abs(self.availableWidth - availableWidth) <= 0.5 &&
                self.contentSizeCategory == contentSizeCategory
        }
    }

    private let titleLabel = UILabel()
    private var layoutCache: LayoutCache?
    fileprivate static let fixedHeaderAccessibilityIdentifier = "AdaptiveLargeTitleHeaderView.fixed"

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func update(title: String, width: CGFloat) -> CGFloat {
        let availableWidth = max(0, width - Constants.horizontalInset * 2)
        let contentSizeCategory = traitCollection.preferredContentSizeCategory
        let layout = cachedLayout(for: title,
                                  availableWidth: availableWidth,
                                  contentSizeCategory: contentSizeCategory)
        titleLabel.text = title
        titleLabel.font = layout.font
        titleLabel.lineBreakMode = layout.lineBreakMode

        frame = CGRect(x: 0, y: 0, width: width, height: layout.height)
        return layout.height
    }

    private func setup() {
        backgroundColor = .systemBackground
        isUserInteractionEnabled = false

        titleLabel.numberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.textAlignment = .natural
        titleLabel.isAccessibilityElement = true
        titleLabel.accessibilityTraits.insert(.header)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Constants.horizontalInset),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Constants.horizontalInset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Constants.topInset),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Constants.bottomInset),
        ])
    }

    private func cachedLayout(for title: String,
                              availableWidth: CGFloat,
                              contentSizeCategory: UIContentSizeCategory) -> TitleLayout {
        if let layoutCache,
           layoutCache.matches(title: title,
                               availableWidth: availableWidth,
                               contentSizeCategory: contentSizeCategory) {
            return layoutCache.layout
        }

        let layout = Self.fittingLayout(for: title,
                                        availableWidth: availableWidth,
                                        compatibleWith: traitCollection)
        layoutCache = LayoutCache(title: title,
                                  availableWidth: availableWidth,
                                  contentSizeCategory: contentSizeCategory,
                                  layout: layout)
        return layout
    }

    private static func height(for title: String,
                               availableWidth: CGFloat,
                               font: UIFont,
                               lineBreakMode: NSLineBreakMode) -> CGFloat {
        let textHeight = textBounds(for: title,
                                    width: availableWidth,
                                    font: font,
                                    lineBreakMode: lineBreakMode).height
        return ceil(Constants.topInset + max(textHeight, font.lineHeight) + Constants.bottomInset)
    }

    private static func fittingLayout(for title: String,
                                      availableWidth: CGFloat,
                                      compatibleWith traitCollection: UITraitCollection) -> TitleLayout {
        let minimumBaseSize = Constants.baseFontSize * Constants.minimumFontScale
        var baseSize = Constants.baseFontSize

        while baseSize > minimumBaseSize {
            let font = largeTitleFont(baseSize: baseSize, compatibleWith: traitCollection)
            if titleFits(title,
                         width: availableWidth,
                         font: font,
                         lineBreakMode: .byWordWrapping,
                         maximumNumberOfLines: Constants.preferredMaximumNumberOfLines) {
                return TitleLayout(font: font,
                                   lineBreakMode: .byWordWrapping,
                                   height: height(for: title,
                                                  availableWidth: availableWidth,
                                                  font: font,
                                                  lineBreakMode: .byWordWrapping))
            }
            baseSize -= 1
        }

        let font = largeTitleFont(baseSize: minimumBaseSize, compatibleWith: traitCollection)
        let lineBreakMode: NSLineBreakMode = titleFits(title,
                                                       width: availableWidth,
                                                       font: font,
                                                       lineBreakMode: .byWordWrapping,
                                                       maximumNumberOfLines: nil) ? .byWordWrapping : .byCharWrapping
        return TitleLayout(font: font,
                           lineBreakMode: lineBreakMode,
                           height: height(for: title,
                                          availableWidth: availableWidth,
                                          font: font,
                                          lineBreakMode: lineBreakMode))
    }

    private static func titleFits(_ title: String,
                                  width: CGFloat,
                                  font: UIFont,
                                  lineBreakMode: NSLineBreakMode,
                                  maximumNumberOfLines: Int?) -> Bool {
        let bounds = textBounds(for: title, width: width, font: font, lineBreakMode: lineBreakMode)
        let heightFits: Bool
        if let maximumNumberOfLines {
            let maximumHeight = font.lineHeight * CGFloat(maximumNumberOfLines)
            heightFits = ceil(bounds.height) <= ceil(maximumHeight)
        } else {
            heightFits = true
        }
        return ceil(bounds.width) <= width && heightFits
    }

    private static func textBounds(for title: String,
                                   width: CGFloat,
                                   font: UIFont,
                                   lineBreakMode: NSLineBreakMode) -> CGRect {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = lineBreakMode

        return (title as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: font,
                .paragraphStyle: paragraphStyle,
            ],
            context: nil
        )
    }

    private static func largeTitleFont(baseSize: CGFloat, compatibleWith traitCollection: UITraitCollection) -> UIFont {
        let font = UIFont.systemFont(ofSize: baseSize, weight: .bold)
        return UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: font, compatibleWith: traitCollection)
    }

}

fileprivate final class AdaptiveLargeTitleTableHeaderView: UIView {

    private let titleHeaderView = AdaptiveLargeTitleHeaderView()
    private var accessoryView: UIView?
    fileprivate var compensatedAutomaticTopInset: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func update(title: String,
                width: CGFloat,
                titleTopInset: CGFloat,
                accessoryView: UIView?,
                accessoryInsets: UIEdgeInsets) -> CGFloat {
        let titleHeight = titleHeaderView.update(title: title, width: width)
        let titleAreaHeight = titleTopInset + titleHeight
        titleHeaderView.frame = CGRect(x: 0, y: titleTopInset, width: width, height: titleHeight)

        updateAccessoryView(accessoryView)

        let accessoryHeight: CGFloat
        if let accessoryView {
            let availableWidth = max(0, width - accessoryInsets.left - accessoryInsets.right)
            let fittingHeight = Self.fittingHeight(for: accessoryView, width: availableWidth)
            accessoryView.frame = CGRect(x: accessoryInsets.left,
                                         y: titleAreaHeight + accessoryInsets.top,
                                         width: availableWidth,
                                         height: fittingHeight)
            accessoryHeight = accessoryInsets.top + fittingHeight + accessoryInsets.bottom
        } else {
            accessoryHeight = 0
        }

        let height = titleAreaHeight + accessoryHeight
        frame = CGRect(x: 0, y: 0, width: width, height: height)
        return height
    }

    private func setup() {
        addSubview(titleHeaderView)
    }

    private func updateAccessoryView(_ newAccessoryView: UIView?) {
        guard accessoryView !== newAccessoryView else { return }

        accessoryView?.removeFromSuperview()
        accessoryView = newAccessoryView

        if let newAccessoryView {
            addSubview(newAccessoryView)
        }
    }

    private static func fittingHeight(for view: UIView, width: CGFloat) -> CGFloat {
        let fittingSize = view.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return max(view.bounds.height, fittingSize.height)
    }

}

extension UIViewController {
    
    var inNavigationController: UINavigationController {
        let navigationController = UINavigationController()
        navigationController.viewControllers = [self]
        return navigationController
    }
    
    @objc func dismissAnimated() {
        dismiss(animated: true)
    }

    func configureAdaptiveLargeTitle(_ title: String) {
        hideSystemTitleForAdaptiveLargeTitle()
        updateAdaptiveLargeTitleLayout(title)
    }

    func configureAdaptiveLargeTitle(_ title: String,
                                     tableView: UITableView,
                                     accessoryView: UIView? = nil,
                                     accessoryInsets: UIEdgeInsets = .zero) {
        hideSystemTitleForAdaptiveLargeTitle()
        updateAdaptiveLargeTitleLayout(title,
                                       tableView: tableView,
                                       accessoryView: accessoryView,
                                       accessoryInsets: accessoryInsets)
    }

    @discardableResult
    func updateAdaptiveLargeTitleLayout(_ title: String) -> CGFloat? {
        guard isViewLoaded else { return nil }

        let width = view.bounds.width
        guard width > 0 else { return nil }

        hideSystemTitleForAdaptiveLargeTitle()

        let headerView = fixedAdaptiveLargeTitleHeaderView()
        let height = headerView.update(title: title, width: width)
        let currentAdaptiveInset = adaptiveLargeTitleAdditionalSafeAreaTop
        let baseSafeAreaTop = max(0, view.safeAreaInsets.top - currentAdaptiveInset)
        headerView.frame = CGRect(x: 0, y: baseSafeAreaTop, width: width, height: height)
        let externalTopInset = additionalTopSafeAreaInsetExcludingAdaptiveLargeTitle(currentAdaptiveInset)
        let desiredAdditionalTopInset = externalTopInset + height
        if abs(currentAdaptiveInset - height) > 0.5 ||
            abs(additionalSafeAreaInsets.top - desiredAdditionalTopInset) > 0.5 {
            additionalSafeAreaInsets.top = desiredAdditionalTopInset
            adaptiveLargeTitleAdditionalSafeAreaTop = height
        }
        view.bringSubviewToFront(headerView)
        return height
    }

    @discardableResult
    func updateAdaptiveLargeTitleLayout(_ title: String,
                                        tableView: UITableView,
                                        accessoryView: UIView? = nil,
                                        accessoryInsets: UIEdgeInsets = .zero) -> CGFloat? {
        let width = tableView.bounds.width
        guard width > 0 else { return nil }

        hideSystemTitleForAdaptiveLargeTitle()

        let currentHeaderView = tableView.tableHeaderView
        if let currentHeaderView, !(currentHeaderView is AdaptiveLargeTitleTableHeaderView) {
            assertionFailure("Adaptive large title cannot replace an existing table header view")
            return nil
        }

        let currentFrame = currentHeaderView?.frame ?? .zero
        let headerView = (currentHeaderView as? AdaptiveLargeTitleTableHeaderView) ?? AdaptiveLargeTitleTableHeaderView()
        let topSafeAreaHeight = max(0, view.safeAreaInsets.top)
        // Move UIKit's automatic top adjustment into the scrolling header. This
        // keeps the title below navigation material without stacking both insets.
        let automaticTopInset = tableView.adjustedContentInset.top - tableView.contentInset.top
        let externalTopInset = tableView.contentInset.top + headerView.compensatedAutomaticTopInset
        let desiredTopInset = externalTopInset - automaticTopInset
        if abs(tableView.contentInset.top - desiredTopInset) > 0.5 {
            tableView.contentInset.top = desiredTopInset
        }
        headerView.compensatedAutomaticTopInset = automaticTopInset
        let height = headerView.update(title: title,
                                       width: width,
                                       titleTopInset: topSafeAreaHeight,
                                       accessoryView: accessoryView,
                                       accessoryInsets: accessoryInsets)
        let needsUpdate = currentHeaderView !== headerView ||
            abs(currentFrame.width - width) > 0.5 ||
            abs(currentFrame.height - height) > 0.5

        if needsUpdate {
            tableView.tableHeaderView = headerView
        }
        return height
    }

    func removeFixedAdaptiveLargeTitleLayout() {
        guard isViewLoaded else { return }
        let currentAdaptiveInset = adaptiveLargeTitleAdditionalSafeAreaTop
        if currentAdaptiveInset > 0 {
            additionalSafeAreaInsets.top = additionalTopSafeAreaInsetExcludingAdaptiveLargeTitle(currentAdaptiveInset)
            adaptiveLargeTitleAdditionalSafeAreaTop = 0
        }
        view.subviews
            .first(where: { $0.accessibilityIdentifier == AdaptiveLargeTitleHeaderView.fixedHeaderAccessibilityIdentifier })?
            .removeFromSuperview()
    }

    private func fixedAdaptiveLargeTitleHeaderView() -> AdaptiveLargeTitleHeaderView {
        if let headerView = view.subviews.first(where: {
            $0.accessibilityIdentifier == AdaptiveLargeTitleHeaderView.fixedHeaderAccessibilityIdentifier
        }) as? AdaptiveLargeTitleHeaderView {
            return headerView
        }

        let headerView = AdaptiveLargeTitleHeaderView()
        headerView.accessibilityIdentifier = AdaptiveLargeTitleHeaderView.fixedHeaderAccessibilityIdentifier
        view.addSubview(headerView)
        return headerView
    }

    private func hideSystemTitleForAdaptiveLargeTitle() {
        // The adaptive header owns title rendering; avoid a second, truncated compact title.
        navigationItem.title = nil
        navigationController?.navigationBar.prefersLargeTitles = false
        navigationItem.largeTitleDisplayMode = .never
    }

    private func additionalTopSafeAreaInsetExcludingAdaptiveLargeTitle(_ adaptiveInset: CGFloat) -> CGFloat {
        let currentTopInset = additionalSafeAreaInsets.top
        guard currentTopInset >= adaptiveInset else { return currentTopInset }
        return currentTopInset - adaptiveInset
    }

    private var adaptiveLargeTitleAdditionalSafeAreaTop: CGFloat {
        get {
            guard let value = objc_getAssociatedObject(self, &adaptiveLargeTitleAdditionalSafeAreaTopKey) as? NSNumber else {
                return 0
            }
            return CGFloat(value.doubleValue)
        }
        set {
            objc_setAssociatedObject(self,
                                     &adaptiveLargeTitleAdditionalSafeAreaTopKey,
                                     NSNumber(value: Double(newValue)),
                                     .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
    
    func showMessageAlert(text: String, completion: (() -> Void)? = nil) {
        let alert = UIAlertController(title: text, message: nil, preferredStyle: .alert)
        let okAction = UIAlertAction(title: Strings.ok, style: .default) { _ in
            completion?()
        }
        alert.addAction(okAction)
        present(alert, animated: true)
    }
    
    func showTextInputAlert(title: String, message: String?, initialText: String?, placeholder: String, completion: @escaping ((String?) -> Void)) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = placeholder
            textField.text = initialText
        }
        let okAction = UIAlertAction(title: Strings.ok, style: .default) { [weak alert] _ in
            completion(alert?.textFields?.first?.text ?? "")
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel) { _ in
            completion(nil)
        }
        alert.addAction(okAction)
        alert.addAction(cancelAction)
        present(alert, animated: true)
        alert.textFields?.first?.becomeFirstResponder()
    }
    
    func showPasswordAlert(title: String, message: String?, completion: @escaping ((String?) -> Void)) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.isSecureTextEntry = true
            textField.textContentType = .oneTimeCode
        }
        let okAction = UIAlertAction(title: Strings.ok, style: .default) { [weak alert] _ in
            completion(alert?.textFields?.first?.text ?? "")
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel) { _ in
            completion(nil)
        }
        alert.addAction(okAction)
        alert.addAction(cancelAction)
        present(alert, animated: true)
        alert.textFields?.first?.becomeFirstResponder()
    }
}
