// ∅ 2026 lil org

@testable import Big_Wallet
import ObjectiveC
import UIKit
import XCTest

@MainActor
final class ProgrammaticUIKitViewTests: XCTestCase {

    func testReusableViewHelpersRegisterProgrammaticClasses() {
        let tableView = UITableView(frame: CGRect(x: 0, y: 0, width: 320, height: 640), style: .grouped)
        tableView.registerReusableCell(type: AccountTableViewCell.self)
        tableView.registerReusableCell(type: PreviewAccountTableViewCell.self)
        tableView.registerReusableCell(type: MultilineLabelTableViewCell.self)
        tableView.registerReusableCell(type: ImageWithLabelTableViewCell.self)
        tableView.registerReusableCell(type: GasPriceSliderTableViewCell.self)
        tableView.registerReusableHeaderFooter(type: AccountsHeaderView.self)

        let accountCell = tableView.dequeueReusableCellOfType(AccountTableViewCell.self, for: IndexPath(row: 0, section: 0))
        let previewCell = tableView.dequeueReusableCellOfType(PreviewAccountTableViewCell.self, for: IndexPath(row: 1, section: 0))
        let multilineCell = tableView.dequeueReusableCellOfType(MultilineLabelTableViewCell.self, for: IndexPath(row: 2, section: 0))
        let imageCell = tableView.dequeueReusableCellOfType(ImageWithLabelTableViewCell.self, for: IndexPath(row: 3, section: 0))
        let sliderCell = tableView.dequeueReusableCellOfType(GasPriceSliderTableViewCell.self, for: IndexPath(row: 4, section: 0))
        let header = tableView.dequeueReusableHeaderFooterOfType(AccountsHeaderView.self)

        XCTAssertEqual(accountCell.reuseIdentifier, "AccountTableViewCell")
        XCTAssertEqual(previewCell.reuseIdentifier, "PreviewAccountTableViewCell")
        XCTAssertEqual(multilineCell.reuseIdentifier, "MultilineLabelTableViewCell")
        XCTAssertEqual(imageCell.reuseIdentifier, "ImageWithLabelTableViewCell")
        XCTAssertEqual(sliderCell.reuseIdentifier, "GasPriceSliderTableViewCell")
        XCTAssertEqual(header.reuseIdentifier, "AccountsHeaderView")
    }

    func testAllProgrammaticViewsPreserveSubviewOrderAndControlDefaults() throws {
        let accountCell = AccountTableViewCell(style: .default, reuseIdentifier: "defaults-account")
        assertSubviewOrder(
            accountCell.contentView.subviews,
            [accountCell.avatarImageView, accountCell.titleLabel, accountCell.moreButton]
        )
        XCTAssertEqual(accountCell.selectionStyle, .blue)
        XCTAssertEqual(accountCell.avatarImageView.contentMode, .scaleAspectFit)
        XCTAssertEqual(accountCell.avatarImageView.layer.cornerRadius, 15, accuracy: 0.01)
        XCTAssertEqual(accountCell.titleLabel.text, "label")
        assertFont(accountCell.titleLabel.font, equals: .systemFont(ofSize: 21, weight: .medium))
        XCTAssertFalse(accountCell.titleLabel.adjustsFontSizeToFitWidth)
        XCTAssertFalse(accountCell.titleLabel.adjustsFontForContentSizeCategory)
        XCTAssertTrue(accountCell.moreButton is ButtonWithExtendedArea)
        XCTAssertEqual((accountCell.moreButton as? ButtonWithExtendedArea)?.minimumHitArea, CGSize(width: 60, height: 60))
        XCTAssertTrue(accountCell.moreButton.configuration?.image?.isSymbolImage == true)
        XCTAssertEqual(
            accountCell.moreButton.configuration?.preferredSymbolConfigurationForImage?.description,
            UIImage.SymbolConfiguration(font: .systemFont(ofSize: 17)).description
        )

        let previewCell = PreviewAccountTableViewCell(style: .default, reuseIdentifier: "defaults-preview")
        assertSubviewOrder(
            previewCell.contentView.subviews,
            [previewCell.logoImageView, previewCell.titleLabel, previewCell.coinSwitch, previewCell.indexLabel]
        )
        XCTAssertEqual(previewCell.selectionStyle, .default)
        XCTAssertEqual(previewCell.logoImageView.contentMode, .scaleAspectFit)
        XCTAssertEqual(previewCell.logoImageView.layer.cornerRadius, 15, accuracy: 0.01)
        XCTAssertEqual(previewCell.titleLabel.text, "label")
        assertFont(previewCell.titleLabel.font, equals: .systemFont(ofSize: 21, weight: .medium))
        XCTAssertFalse(previewCell.titleLabel.adjustsFontSizeToFitWidth)
        XCTAssertFalse(previewCell.titleLabel.adjustsFontForContentSizeCategory)
        XCTAssertEqual(previewCell.indexLabel.text, "0")
        XCTAssertEqual(previewCell.indexLabel.textAlignment, .center)
        XCTAssertEqual(previewCell.indexLabel.minimumScaleFactor, 0.5, accuracy: 0.001)
        XCTAssertTrue(previewCell.indexLabel.adjustsFontSizeToFitWidth)
        assertFont(previewCell.indexLabel.font, equals: .systemFont(ofSize: 12))
        XCTAssertEqual(previewCell.indexLabel.textColor, .tertiaryLabel)
        XCTAssertTrue(previewCell.coinSwitch.isOn)
        XCTAssertEqual(previewCell.coinSwitch.contentHuggingPriority(for: .horizontal), .defaultHigh)
        XCTAssertEqual(previewCell.coinSwitch.contentHuggingPriority(for: .vertical), .defaultHigh)

        let header = AccountsHeaderView(reuseIdentifier: "defaults-header")
        assertDirectSubviewOrder(
            [header.titleLabel, header.editSectionButton, header.invisibleButton],
            in: header
        )
        XCTAssertTrue(header.contentView.subviews.isEmpty)
        XCTAssertEqual(header.titleLabel.text, "label")
        XCTAssertEqual(header.titleLabel.textColor, .secondaryLabel)
        XCTAssertEqual(header.titleLabel.minimumScaleFactor, 0.5, accuracy: 0.001)
        XCTAssertTrue(header.titleLabel.adjustsFontSizeToFitWidth)
        assertFont(header.titleLabel.font, equals: .systemFont(ofSize: 13))
        XCTAssertFalse(header.titleLabel.adjustsFontForContentSizeCategory)
        XCTAssertTrue(header.editSectionButton.configuration?.image?.isSymbolImage == true)
        XCTAssertEqual(
            header.editSectionButton.configuration?.preferredSymbolConfigurationForImage?.description,
            UIImage.SymbolConfiguration(font: .systemFont(ofSize: 13)).description
        )
        XCTAssertNil(header.invisibleButton.configuration?.image)
        XCTAssertNil(header.invisibleButton.backgroundColor)
        XCTAssertEqual(header.invisibleButton.alpha, 1, accuracy: 0.001)

        let multilineCell = MultilineLabelTableViewCell(style: .default, reuseIdentifier: "defaults-multiline")
        assertSubviewOrder(multilineCell.contentView.subviews, [multilineCell.multilineLabel])
        XCTAssertEqual(multilineCell.multilineLabel.text, "label")
        XCTAssertEqual(multilineCell.multilineLabel.numberOfLines, 0)
        XCTAssertEqual(multilineCell.multilineLabel.lineBreakMode, .byCharWrapping)
        XCTAssertEqual(multilineCell.multilineLabel.textAlignment, .left)
        assertFont(multilineCell.multilineLabel.font, equals: .systemFont(ofSize: 17))
        XCTAssertFalse(multilineCell.multilineLabel.adjustsFontSizeToFitWidth)
        XCTAssertFalse(multilineCell.multilineLabel.adjustsFontForContentSizeCategory)

        let imageCell = ImageWithLabelTableViewCell(style: .default, reuseIdentifier: "defaults-image")
        assertSubviewOrder(
            imageCell.contentView.subviews,
            [imageCell.titleLabel, imageCell.extraTitleLabel, imageCell.iconImageView]
        )
        XCTAssertEqual(imageCell.iconImageView.image, Images.circleFill)
        XCTAssertEqual(imageCell.iconImageView.contentMode, .scaleAspectFit)
        XCTAssertEqual(imageCell.iconImageView.tintColor, .secondarySystemFill)
        XCTAssertEqual(imageCell.iconImageView.layer.cornerRadius, 0, accuracy: 0.01)
        XCTAssertEqual(imageCell.titleLabel.text, "label")
        XCTAssertEqual(imageCell.titleLabel.numberOfLines, 0)
        XCTAssertEqual(imageCell.titleLabel.lineBreakMode, .byTruncatingTail)
        XCTAssertEqual(imageCell.titleLabel.textAlignment, .left)
        assertFont(imageCell.titleLabel.font, equals: .systemFont(ofSize: 21, weight: .medium))
        XCTAssertFalse(imageCell.titleLabel.adjustsFontSizeToFitWidth)
        XCTAssertFalse(imageCell.titleLabel.adjustsFontForContentSizeCategory)
        XCTAssertEqual(imageCell.extraTitleLabel.text, "label")
        XCTAssertEqual(imageCell.extraTitleLabel.numberOfLines, 1)
        XCTAssertEqual(imageCell.extraTitleLabel.lineBreakMode, .byTruncatingTail)
        XCTAssertEqual(imageCell.extraTitleLabel.textAlignment, .left)
        XCTAssertEqual(imageCell.extraTitleLabel.minimumScaleFactor, 0.5, accuracy: 0.001)
        XCTAssertTrue(imageCell.extraTitleLabel.adjustsFontSizeToFitWidth)
        XCTAssertEqual(imageCell.extraTitleLabel.textColor, .tertiaryLabel)
        assertFont(imageCell.extraTitleLabel.font, equals: .systemFont(ofSize: 21))
        XCTAssertFalse(imageCell.extraTitleLabel.adjustsFontForContentSizeCategory)

        let sliderCell = GasPriceSliderTableViewCell(style: .default, reuseIdentifier: "defaults-slider")
        assertSubviewOrder(
            sliderCell.contentView.subviews,
            [sliderCell.slowSpeedLabel, sliderCell.fastSpeedLabel, sliderCell.slider]
        )
        XCTAssertEqual(sliderCell.slowSpeedLabel.text, "🐢")
        XCTAssertEqual(sliderCell.fastSpeedLabel.text, "🐇")
        assertFont(sliderCell.slowSpeedLabel.font, equals: .systemFont(ofSize: 17))
        assertFont(sliderCell.fastSpeedLabel.font, equals: .systemFont(ofSize: 17))
        XCTAssertFalse(sliderCell.slowSpeedLabel.adjustsFontForContentSizeCategory)
        XCTAssertFalse(sliderCell.fastSpeedLabel.adjustsFontForContentSizeCategory)
        XCTAssertEqual(sliderCell.slider.minimumValue, 0)
        XCTAssertEqual(sliderCell.slider.maximumValue, 100)
        XCTAssertEqual(sliderCell.slider.value, 33, accuracy: 0.001)
        XCTAssertTrue(sliderCell.slider.isContinuous)

        let stateView = DataStateView(frame: CGRect(x: 0, y: 0, width: 414, height: 896))
        XCTAssertEqual(stateView.subviews.count, 5)
        let spinner = try XCTUnwrap(stateView.subviews[0] as? UIActivityIndicatorView)
        let loadingLabel = try XCTUnwrap(stateView.subviews[1] as? UILabel)
        let stateImageView = try XCTUnwrap(stateView.subviews[2] as? UIImageView)
        let descriptionLabel = try XCTUnwrap(stateView.subviews[3] as? UILabel)
        let stateButton = try XCTUnwrap(stateView.subviews[4] as? UIButton)
        XCTAssertEqual(spinner.style, .medium)
        XCTAssertTrue(spinner.isHidden)
        XCTAssertTrue(spinner.isAnimating)
        XCTAssertEqual(spinner.contentHuggingPriority(for: .horizontal), .defaultHigh)
        XCTAssertEqual(spinner.contentHuggingPriority(for: .vertical), .defaultHigh)
        XCTAssertEqual(loadingLabel.text, Strings.loading)
        XCTAssertTrue(loadingLabel.isHidden)
        XCTAssertEqual(loadingLabel.textColor, .secondaryLabel)
        assertFont(loadingLabel.font, equals: .systemFont(ofSize: 12))
        XCTAssertFalse(loadingLabel.adjustsFontForContentSizeCategory)
        XCTAssertEqual(stateImageView.image, UIImage(systemName: "wind"))
        XCTAssertEqual(stateImageView.contentMode, .scaleAspectFit)
        XCTAssertEqual(stateImageView.tintColor, .tertiaryLabel)
        XCTAssertEqual(
            stateImageView.preferredSymbolConfiguration?.description,
            UIImage.SymbolConfiguration(scale: .default)
                .applying(UIImage.SymbolConfiguration(weight: .thin)).description
        )
        XCTAssertEqual(descriptionLabel.text, "failed to load")
        XCTAssertEqual(descriptionLabel.textAlignment, .center)
        XCTAssertEqual(descriptionLabel.lineBreakMode, .byTruncatingTail)
        XCTAssertEqual(descriptionLabel.numberOfLines, 2)
        XCTAssertEqual(descriptionLabel.textColor, .secondaryLabel)
        assertFont(descriptionLabel.font, equals: .systemFont(ofSize: 17))
        XCTAssertFalse(descriptionLabel.adjustsFontForContentSizeCategory)
        let expectedFilledConfiguration = UIButton.Configuration.filled()
        XCTAssertEqual(stateButton.configuration?.cornerStyle, expectedFilledConfiguration.cornerStyle)
        XCTAssertEqual(stateButton.configuration?.baseForegroundColor, expectedFilledConfiguration.baseForegroundColor)
        XCTAssertEqual(stateButton.configuration?.baseBackgroundColor, expectedFilledConfiguration.baseBackgroundColor)
        XCTAssertEqual(stateButton.titleLabel?.lineBreakMode, .byWordWrapping)
        assertFont(stateButton.titleLabel?.font, equals: .systemFont(ofSize: 15, weight: .semibold))
        XCTAssertFalse(stateButton.titleLabel?.adjustsFontForContentSizeCategory ?? true)
        XCTAssertEqual(stateButton.configuration?.title, "retry")
        let attributedButtonTitle = try XCTUnwrap(stateButton.configuration?.attributedTitle)
        XCTAssertEqual(String(attributedButtonTitle.characters), "retry")
        assertFont(attributedButtonTitle.font, equals: .systemFont(ofSize: 15, weight: .semibold))
        XCTAssertNil(stateButton.configuration?.titleTextAttributesTransformer)
    }

    func testAccountCellMatchesLayoutAndSelectionStates() {
        let cell = AccountTableViewCell(style: .default, reuseIdentifier: "account")
        let delegate = AccountDelegateSpy()
        let image = UIImage(systemName: "person.circle")

        layout(cell, width: 320, height: 50)

        XCTAssertEqual(cell.avatarImageView.frame.minX, 16, accuracy: 0.5)
        XCTAssertEqual(cell.avatarImageView.frame.minY, 10, accuracy: 0.5)
        XCTAssertEqual(cell.avatarImageView.frame.width, 30, accuracy: 0.5)
        XCTAssertEqual(cell.avatarImageView.frame.height, 30, accuracy: 0.5)
        XCTAssertEqual(cell.titleLabel.frame.minX, 58, accuracy: 0.5)
        XCTAssertEqual(cell.moreButton.frame.maxX, 315, accuracy: 0.5)
        XCTAssertEqual(cell.separatorInset.left, effectiveSeparatorInset(source: 58), accuracy: 0.5)
        XCTAssertTrue(cell.moreButton is ButtonWithExtendedArea)

        cell.setup(title: "Primary", image: image, isDisabled: false, customSelectionStyle: true, isSelected: true, delegate: delegate)
        XCTAssertEqual(cell.selectionStyle, .none)
        XCTAssertEqual(cell.avatarImageView.image, image)
        XCTAssertEqual(cell.titleLabel.text, "Primary")
        XCTAssertEqual(cell.titleLabel.textColor, .white)
        XCTAssertEqual(cell.moreButton.tintColor, .white)
        XCTAssertEqual(cell.contentView.alpha, 1)

        cell.moreButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(delegate.tapCount, 1)
        XCTAssertTrue(delegate.lastCell === cell)

        let expandedPoint = CGPoint(x: -5, y: cell.moreButton.bounds.midY)
        XCTAssertTrue(cell.moreButton.hitTest(expandedPoint, with: nil) === cell.moreButton)

        cell.setup(title: "Disabled", image: nil, isDisabled: true, customSelectionStyle: false, isSelected: false, delegate: delegate)
        XCTAssertEqual(cell.selectionStyle, .blue)
        XCTAssertEqual(cell.contentView.alpha, 0.35, accuracy: 0.001)
        XCTAssertEqual(cell.titleLabel.textColor, .label)
    }

    func testPreviewAccountCellMatchesLayoutAndToggleSemantics() {
        let cell = PreviewAccountTableViewCell(style: .default, reuseIdentifier: "preview")
        let delegate = PreviewDelegateSpy()
        cell.setup(title: "Preview", image: UIImage(systemName: "circle"), index: 12, isEnabled: true, delegate: delegate)

        layout(cell, width: 320, height: 50)

        XCTAssertEqual(cell.indexLabel.frame.minX, 10, accuracy: 0.5)
        XCTAssertEqual(cell.indexLabel.frame.width, 16.5, accuracy: 0.5)
        XCTAssertEqual(cell.logoImageView.frame.minX, 34.5, accuracy: 0.5)
        XCTAssertEqual(cell.logoImageView.frame.width, 30, accuracy: 0.5)
        XCTAssertEqual(cell.titleLabel.frame.minX, 76.5, accuracy: 0.5)
        XCTAssertEqual(cell.separatorInset.left, effectiveSeparatorInset(source: 76.5), accuracy: 0.5)
        XCTAssertEqual(cell.indexLabel.text, "12")
        XCTAssertTrue(cell.coinSwitch.isOn)

        cell.toggle()
        XCTAssertFalse(cell.coinSwitch.isOn)
        XCTAssertEqual(delegate.toggleCount, 0)

        cell.coinSwitch.sendActions(for: .valueChanged)
        XCTAssertEqual(delegate.toggleCount, 1)
        XCTAssertTrue(delegate.lastCell === cell)
    }

    func testAccountCellsUseDirectionalConstraintsInRightToLeftLayout() {
        let cell = PreviewAccountTableViewCell(style: .default, reuseIdentifier: "rtl")
        cell.semanticContentAttribute = .forceRightToLeft
        cell.contentView.semanticContentAttribute = .forceRightToLeft
        layout(cell, width: 320, height: 50)

        XCTAssertEqual(cell.indexLabel.frame.maxX, 310, accuracy: 0.5)
        XCTAssertEqual(cell.logoImageView.frame.maxX, cell.indexLabel.frame.minX - 8, accuracy: 0.5)
        XCTAssertEqual(cell.titleLabel.frame.maxX, cell.logoImageView.frame.minX - 12, accuracy: 0.5)
    }

    func testAccountsHeaderMatchesGeometryVisibilityAndCallback() {
        let header = AccountsHeaderView(reuseIdentifier: "header")
        let delegate = HeaderDelegateSpy()
        header.set(title: "Multicoin Wallet", showsButton: true, sectionIndex: 4, delegate: delegate)
        layout(header, width: 414, height: 37)

        XCTAssertNil(header.backgroundColor)
        XCTAssertTrue(header.contentView.subviews.isEmpty)
        XCTAssertEqual(header.titleLabel.text, "MULTICOIN WALLET")
        XCTAssertEqual(header.titleLabel.frame.minX, 16, accuracy: 0.5)
        XCTAssertEqual(header.titleLabel.frame.maxY, 31, accuracy: 0.5)
        XCTAssertEqual(header.editSectionButton.frame.minX, header.titleLabel.frame.maxX, accuracy: 0.5)
        XCTAssertEqual(header.editSectionButton.frame.width, 32, accuracy: 0.5)
        XCTAssertEqual(header.invisibleButton.frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(header.invisibleButton.frame.maxY, 37, accuracy: 0.5)
        XCTAssertEqual(header.invisibleButton.frame.height, 40, accuracy: 0.5)
        XCTAssertEqual(header.invisibleButton.frame.maxX, header.editSectionButton.frame.maxX + 20, accuracy: 0.5)

        header.editSectionButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(delegate.tapCount, 0)
        header.invisibleButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(delegate.tapCount, 1)
        XCTAssertEqual(delegate.lastSection, 4)
        XCTAssertTrue(delegate.lastHeader === header)

        header.set(title: "Private Key Wallets", showsButton: false, sectionIndex: 0, delegate: delegate)
        XCTAssertTrue(header.editSectionButton.isHidden)
        XCTAssertTrue(header.invisibleButton.isHidden)
    }

    func testMultilineCellPreservesTypographyWrappingAndMargins() {
        let cell = MultilineLabelTableViewCell(style: .default, reuseIdentifier: "multiline")
        cell.setup(text: String(repeating: "Long value ", count: 12), largeFont: true, oneLine: false, pro: false)
        layout(cell, width: 320, height: 100)

        XCTAssertEqual(cell.multilineLabel.frame.minX, 16, accuracy: 0.5)
        XCTAssertEqual(cell.multilineLabel.frame.minY, 12, accuracy: 0.5)
        XCTAssertLessThanOrEqual(cell.multilineLabel.frame.maxX, 308.5)
        XCTAssertEqual(cell.multilineLabel.numberOfLines, 0)
        XCTAssertEqual(cell.multilineLabel.lineBreakMode, .byCharWrapping)
        XCTAssertEqual(cell.multilineLabel.font.pointSize, 21, accuracy: 0.01)
        XCTAssertEqual(cell.multilineLabel.textColor, .label)
        XCTAssertEqual(cell.separatorInset.left, effectiveSeparatorInset(source: 16), accuracy: 0.5)

        cell.setup(text: "Professional interpretation", largeFont: true, oneLine: true, pro: true)
        XCTAssertEqual(cell.multilineLabel.numberOfLines, 1)
        XCTAssertEqual(cell.multilineLabel.lineBreakMode, .byTruncatingTail)
        XCTAssertEqual(cell.multilineLabel.font.pointSize, 17, accuracy: 0.01)
        XCTAssertTrue(cell.multilineLabel.font.fontDescriptor.symbolicTraits.contains(.traitItalic))
        XCTAssertEqual(cell.multilineLabel.textColor, .secondaryLabel)
    }

    func testImageLabelCellPreservesNilGeometryAndReuseBehavior() {
        let cell = ImageWithLabelTableViewCell(style: .default, reuseIdentifier: "image")
        let image = UIImage(systemName: "network")!
        cell.setup(text: "Network", extraText: nil, imageURL: nil, image: image)
        layout(cell, width: 320, height: 50)

        XCTAssertEqual(cell.iconImageView.frame.minX, 16, accuracy: 0.5)
        XCTAssertEqual(cell.iconImageView.frame.width, 30, accuracy: 0.5)
        XCTAssertEqual(cell.titleLabel.frame.minX, 54, accuracy: 0.5)
        XCTAssertEqual(cell.titleLabel.frame.minY, 12, accuracy: 0.5)
        XCTAssertNil(cell.extraTitleLabel.text)
        XCTAssertEqual(cell.extraTitleLabel.frame.minX, cell.titleLabel.frame.maxX + 12, accuracy: 0.5)
        XCTAssertEqual(cell.extraTitleLabel.contentCompressionResistancePriority(for: .horizontal), .defaultLow)
        XCTAssertEqual(cell.iconImageView.image, image)
        XCTAssertEqual(cell.iconImageView.layer.cornerRadius, 15, accuracy: 0.01)

        cell.setup(text: "Unchanged image", extraText: nil, imageURL: nil, image: nil)
        XCTAssertEqual(cell.iconImageView.image, image)
        XCTAssertEqual(cell.iconImageView.layer.cornerRadius, 15, accuracy: 0.01)

        cell.prepareForReuse()
        XCTAssertEqual(cell.iconImageView.image, Images.circleFill)
        XCTAssertEqual(cell.iconImageView.layer.cornerRadius, 0, accuracy: 0.01)
        XCTAssertEqual(cell.iconImageView.tintColor, .secondarySystemFill)
    }

    func testImageLabelCellPreservesAccessoryLayoutAndRemoteImageLifecycle() async throws {
        ProgrammaticUIKitURLSessionDataTaskStub.install()
        defer { ProgrammaticUIKitURLSessionDataTaskStub.uninstall() }

        let remoteImage = solidImage(color: .magenta)
        let staleImage = solidImage(color: .red)
        let replacementImage = solidImage(color: .green)
        let localImage = solidImage(color: .cyan)
        ProgrammaticUIKitURLSessionDataTaskStub.reset(with: try XCTUnwrap(remoteImage.pngData()))
        let pathPrefix = "/\(UUID().uuidString)"
        let remotePath = "\(pathPrefix)/remote.png"
        let stalePath = "\(pathPrefix)/stale.png"
        let replacementPath = "\(pathPrefix)/replacement.png"
        let cancelledPath = "\(pathPrefix)/cancelled.png"
        let ignoredPath = "\(pathPrefix)/ignored.png"

        let cell = ImageWithLabelTableViewCell(style: .default, reuseIdentifier: "remote-image")
        cell.accessoryType = .disclosureIndicator
        cell.setup(
            text: "A deliberately long network title",
            extraText: "Long extra value",
            imageURL: "https://programmatic-uikit.invalid\(remotePath)",
            image: nil
        )
        layout(cell, width: 320, height: 56)

        let remoteTask = try XCTUnwrap(
            ProgrammaticUIKitURLSessionDataTaskStub.task(for: remotePath)
                as? ProgrammaticUIKitStubDataTask
        )
        XCTAssertTrue(remoteTask.wasResumed)
        try await waitUntil { self.imagesMatch(cell.iconImageView.image, remoteImage) }
        assertImage(cell.iconImageView.image, matches: remoteImage)
        XCTAssertEqual(cell.iconImageView.layer.cornerRadius, 0, accuracy: 0.01)
        XCTAssertEqual(cell.iconImageView.tintColor, .secondarySystemFill)
        XCTAssertEqual(cell.accessoryType, .disclosureIndicator)
        XCTAssertLessThan(cell.contentView.frame.maxX, cell.bounds.maxX)
        XCTAssertLessThanOrEqual(cell.extraTitleLabel.frame.maxX, cell.contentView.bounds.maxX)

        ProgrammaticUIKitURLSessionDataTaskStub.setResponse(
            try XCTUnwrap(staleImage.pngData()),
            delay: 0.15,
            for: stalePath
        )
        cell.setup(
            text: "Stale request",
            extraText: nil,
            imageURL: "https://programmatic-uikit.invalid\(stalePath)",
            image: nil
        )
        let staleTask = try XCTUnwrap(
            ProgrammaticUIKitURLSessionDataTaskStub.task(for: stalePath)
                as? ProgrammaticUIKitStubDataTask
        )
        XCTAssertTrue(staleTask.wasResumed)

        ProgrammaticUIKitURLSessionDataTaskStub.setResponse(
            try XCTUnwrap(replacementImage.pngData()),
            delay: 0,
            for: replacementPath
        )
        cell.setup(
            text: "Replacement request",
            extraText: nil,
            imageURL: "https://programmatic-uikit.invalid\(replacementPath)",
            image: nil
        )
        let replacementTask = try XCTUnwrap(
            ProgrammaticUIKitURLSessionDataTaskStub.task(for: replacementPath)
                as? ProgrammaticUIKitStubDataTask
        )
        XCTAssertTrue(staleTask.wasCancelled)
        XCTAssertTrue(replacementTask.wasResumed)
        try await waitUntil { self.imagesMatch(cell.iconImageView.image, replacementImage) }
        try await Task.sleep(nanoseconds: 250_000_000)
        assertImage(cell.iconImageView.image, matches: replacementImage)

        ProgrammaticUIKitURLSessionDataTaskStub.setResponse(
            try XCTUnwrap(staleImage.pngData()),
            delay: 0.15,
            for: cancelledPath
        )
        cell.setup(
            text: "Pending reuse",
            extraText: nil,
            imageURL: "https://programmatic-uikit.invalid\(cancelledPath)",
            image: nil
        )
        let cancelledTask = try XCTUnwrap(
            ProgrammaticUIKitURLSessionDataTaskStub.task(for: cancelledPath)
                as? ProgrammaticUIKitStubDataTask
        )
        XCTAssertTrue(cancelledTask.wasResumed)
        cell.prepareForReuse()
        XCTAssertTrue(cancelledTask.wasCancelled)
        try await Task.sleep(nanoseconds: 250_000_000)
        assertImage(cell.iconImageView.image, matches: Images.circleFill)

        cell.setup(
            text: "Local wins",
            extraText: nil,
            imageURL: "https://programmatic-uikit.invalid\(ignoredPath)",
            image: localImage
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(cell.iconImageView.image === localImage)
        XCTAssertFalse(ProgrammaticUIKitURLSessionDataTaskStub.requestedPaths.contains(ignoredPath))
    }

    func testGasSliderPreservesLayoutValuesEnabledStateAndEvents() {
        let cell = GasPriceSliderTableViewCell(style: .default, reuseIdentifier: "gas")
        let delegate = SliderDelegateSpy()
        cell.setup(value: 42, isEnabled: true, delegate: delegate)
        layout(cell, width: 326, height: 65)

        XCTAssertEqual(cell.slowSpeedLabel.frame.minX, 20, accuracy: 0.5)
        XCTAssertEqual(cell.slider.frame.minX, cell.slowSpeedLabel.frame.maxX + 8, accuracy: 0.5)
        XCTAssertEqual(cell.slider.frame.minY, 16, accuracy: 0.5)
        XCTAssertEqual(cell.slider.frame.height, 33, accuracy: 0.5)
        XCTAssertEqual(cell.fastSpeedLabel.frame.minX, cell.slider.frame.maxX + 8, accuracy: 0.5)
        XCTAssertEqual(cell.fastSpeedLabel.frame.maxX, 306, accuracy: 0.5)
        XCTAssertEqual(cell.slider.minimumValue, 0)
        XCTAssertEqual(cell.slider.maximumValue, 100)
        XCTAssertEqual(cell.slider.value, 42, accuracy: 0.001)

        cell.update(value: nil, isEnabled: false)
        XCTAssertEqual(cell.slider.value, 42, accuracy: 0.001)
        XCTAssertFalse(cell.slider.isEnabled)
        XCTAssertEqual(cell.slowSpeedLabel.alpha, 0.5, accuracy: 0.001)
        XCTAssertEqual(cell.fastSpeedLabel.alpha, 0.5, accuracy: 0.001)

        cell.slider.sendActions(for: .touchDown)
        XCTAssertEqual(delegate.startedCount, 1)
        XCTAssertEqual(delegate.endedCount, 0)

        cell.slider.value = 55
        cell.slider.sendActions(for: .valueChanged)
        XCTAssertEqual(delegate.changedValues, [55])
        XCTAssertEqual(delegate.endedCount, 0)

        cell.slider.sendActions(for: .touchUpInside)
        XCTAssertEqual(delegate.endedCount, 1)
        cell.slider.sendActions(for: .touchUpOutside)
        XCTAssertEqual(delegate.endedCount, 2)
        cell.slider.sendActions(for: .touchCancel)
        XCTAssertEqual(delegate.endedCount, 3)

        XCTAssertEqual(delegate.startedCount, 1)
        XCTAssertEqual(delegate.changedValues, [55])
        XCTAssertEqual(delegate.endedCount, 3)
    }

    func testDataStateViewPreservesStatesActionsHitTestingAndKeyboardOffsets() throws {
        let host = DataStateHostViewController()
        host.view.frame = CGRect(x: 0, y: 0, width: 414, height: 896)
        if case .unknown = host.dataState {
            // The first access creates the single hidden overlay in its archived initial state.
        } else {
            XCTFail("The data-state container must begin in the unknown state")
        }

        let stateViews = host.view.subviews.compactMap { $0 as? DataStateView }
        let stateView = try XCTUnwrap(stateViews.first)
        let button = try XCTUnwrap(stateView.subviews[4] as? UIButton)
        let spinner = try XCTUnwrap(stateView.subviews[0] as? UIActivityIndicatorView)
        let loadingLabel = try XCTUnwrap(stateView.subviews[1] as? UILabel)
        let imageView = try XCTUnwrap(stateView.subviews[2] as? UIImageView)
        let descriptionLabel = try XCTUnwrap(stateView.subviews[3] as? UILabel)

        XCTAssertEqual(stateViews.count, 1)
        XCTAssertTrue(stateView.isHidden)
        XCTAssertTrue(spinner.isAnimating)
        host.view.layoutIfNeeded()
        XCTAssertEqual(stateView.frame, host.view.bounds)
        assertConstraint(
            in: host.view,
            firstItem: stateView,
            firstAttribute: .leading,
            secondItem: host.view,
            secondAttribute: .leading,
            constant: 0
        )
        assertConstraint(
            in: host.view,
            firstItem: stateView,
            firstAttribute: .trailing,
            secondItem: host.view,
            secondAttribute: .trailing,
            constant: 0
        )
        assertConstraint(
            in: host.view,
            firstItem: stateView,
            firstAttribute: .top,
            secondItem: host.view,
            secondAttribute: .top,
            constant: 0
        )
        assertConstraint(
            in: host.view,
            firstItem: stateView,
            firstAttribute: .bottom,
            secondItem: host.view,
            secondAttribute: .bottom,
            constant: 0
        )

        host.dataState = .unknown
        XCTAssertTrue(stateView.isHidden)
        XCTAssertFalse(spinner.isAnimating)
        XCTAssertTrue(button.isHidden)

        var actionCount = 0
        host.configureDataState(.noData, description: "Nothing here", image: UIImage(systemName: "tray"), buttonTitle: "Add Wallet") {
            actionCount += 1
        }
        host.dataState = .noData
        host.view.layoutIfNeeded()

        XCTAssertFalse(stateView.isHidden)
        XCTAssertEqual(stateView.backgroundColor, .systemGroupedBackground)
        XCTAssertEqual(descriptionLabel.text, "Nothing here")
        XCTAssertEqual(button.currentTitle, "Add Wallet")
        XCTAssertFalse(button.isHidden)
        XCTAssertTrue(spinner.isHidden)
        XCTAssertFalse(imageView.isHidden)

        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(actionCount, 1)

        let expandedButtonFrame = button.frame.insetBy(dx: -30, dy: -30)
        let justInsideExpandedButton = CGPoint(x: expandedButtonFrame.minX + 0.5, y: expandedButtonFrame.midY)
        let justOutsideExpandedButton = CGPoint(x: expandedButtonFrame.minX - 0.5, y: expandedButtonFrame.midY)
        XCTAssertTrue(stateView.point(inside: justInsideExpandedButton, with: nil))
        XCTAssertFalse(stateView.point(inside: justOutsideExpandedButton, with: nil))
        XCTAssertFalse(stateView.point(inside: CGPoint(x: 0, y: 0), with: nil))

        host.dataState = .loading
        XCTAssertFalse(stateView.isHidden)
        XCTAssertFalse(spinner.isHidden)
        XCTAssertTrue(spinner.isAnimating)
        XCTAssertFalse(loadingLabel.isHidden)
        XCTAssertEqual(loadingLabel.text, Strings.loading)
        XCTAssertTrue(imageView.isHidden)
        XCTAssertTrue(descriptionLabel.isHidden)
        XCTAssertTrue(button.isHidden)

        host.dataState = .hasData
        XCTAssertTrue(stateView.isHidden)
        XCTAssertFalse(spinner.isAnimating)
        XCTAssertTrue(loadingLabel.isHidden)
        _ = host.dataState
        XCTAssertEqual(host.view.subviews.compactMap { $0 as? DataStateView }.count, 1)

        let centerConstraint = try XCTUnwrap(stateView.constraints.first {
            ($0.firstItem as? UIActivityIndicatorView) === spinner && $0.firstAttribute == .centerY
        })
        XCTAssertEqual(centerConstraint.constant, -50, accuracy: 0.001)
        host.dataStateShouldMoveWithKeyboard(false)
        stateView.keyboardWill(show: true, height: 300, animtaionOptions: [], duration: 0)
        XCTAssertEqual(centerConstraint.constant, -50, accuracy: 0.001)

        host.dataStateShouldMoveWithKeyboard(true)
        stateView.keyboardWill(show: true, height: 300, animtaionOptions: [], duration: 0)
        XCTAssertEqual(centerConstraint.constant, -105, accuracy: 0.001)
        stateView.keyboardWill(show: false, height: 0, animtaionOptions: [], duration: 0)
        XCTAssertEqual(centerConstraint.constant, -50, accuracy: 0.001)
    }

    func testDataStateDefaultFallbacksKeepButtonsHiddenWithoutActions() throws {
        let host = DataStateHostViewController()
        host.view.frame = CGRect(x: 0, y: 0, width: 414, height: 896)
        host.dataState = .failedToLoad
        host.view.layoutIfNeeded()

        let stateView = try XCTUnwrap(host.view.subviews.compactMap { $0 as? DataStateView }.first)
        let button = try XCTUnwrap(descendants(of: UIButton.self, in: stateView).first)
        let imageView = try XCTUnwrap(stateView.subviews.compactMap { $0 as? UIImageView }.first)
        let descriptionLabel = try XCTUnwrap(descendants(of: UILabel.self, in: stateView).first { $0.numberOfLines == 2 })

        XCTAssertEqual(descriptionLabel.text, Strings.failedToLoad)
        XCTAssertEqual(imageView.image, Images.failedToLoad)
        XCTAssertEqual(button.currentTitle, Strings.tryAgain)
        XCTAssertTrue(button.isHidden)

        var actionCount = 0
        host.configureDataState(.noData, description: nil, image: nil, buttonTitle: nil) {
            actionCount += 1
        }
        host.dataState = .noData

        XCTAssertEqual(descriptionLabel.text, Strings.noData)
        XCTAssertEqual(imageView.image, Images.noData)
        XCTAssertEqual(button.currentTitle, Strings.refresh)
        XCTAssertFalse(button.isHidden)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(actionCount, 1)
    }

    func testAutomaticSizingAtCompactAndRegularWidths() {
        let longText = String(repeating: "long localized content ", count: 16)
        let compactCell = MultilineLabelTableViewCell(style: .default, reuseIdentifier: "compact")
        compactCell.setup(text: longText, largeFont: true, oneLine: false, pro: false)
        let compactHeight = fittingHeight(of: compactCell, width: 320)

        let regularCell = MultilineLabelTableViewCell(style: .default, reuseIdentifier: "regular")
        regularCell.setup(text: longText, largeFont: true, oneLine: false, pro: false)
        let regularHeight = fittingHeight(of: regularCell, width: 768)

        XCTAssertGreaterThan(compactHeight, regularHeight)
        XCTAssertGreaterThanOrEqual(regularHeight, 50)

        for width: CGFloat in [320, 768] {
            let accountCell = AccountTableViewCell(style: .default, reuseIdentifier: "minimum-row-\(width)")
            XCTAssertEqual(fittingHeight(of: accountCell, width: width), 50, accuracy: 0.5)
            let previewCell = PreviewAccountTableViewCell(style: .default, reuseIdentifier: "minimum-preview-row-\(width)")
            XCTAssertEqual(fittingHeight(of: previewCell, width: width), 50, accuracy: 0.5)
            let sliderCell = GasPriceSliderTableViewCell(style: .default, reuseIdentifier: "fixed-slider-row-\(width)")
            XCTAssertEqual(fittingHeight(of: sliderCell, width: width), 65, accuracy: 0.5)
        }

        let compactImageCell = ImageWithLabelTableViewCell(style: .default, reuseIdentifier: "compact-image")
        compactImageCell.setup(text: longText, extraText: nil, imageURL: nil, image: Images.circleFill)
        let compactImageHeight = fittingHeight(of: compactImageCell, width: 320)
        let regularImageCell = ImageWithLabelTableViewCell(style: .default, reuseIdentifier: "regular-image")
        regularImageCell.setup(text: longText, extraText: nil, imageURL: nil, image: Images.circleFill)
        let regularImageHeight = fittingHeight(of: regularImageCell, width: 768)
        XCTAssertGreaterThan(compactImageHeight, regularImageHeight)
        XCTAssertGreaterThanOrEqual(regularImageHeight, 50)
    }

    func testAllDirectionalLayoutsMirrorInRightToLeftMode() {
        let accountCell = AccountTableViewCell(style: .default, reuseIdentifier: "rtl-account")
        forceRightToLeft(accountCell)
        layout(accountCell, width: 320, height: 50)
        XCTAssertEqual(accountCell.avatarImageView.frame.maxX, 304, accuracy: 0.5)
        XCTAssertEqual(accountCell.titleLabel.frame.maxX, accountCell.avatarImageView.frame.minX - 12, accuracy: 0.5)
        XCTAssertEqual(accountCell.moreButton.frame.minX, 5, accuracy: 0.5)

        let header = AccountsHeaderView(reuseIdentifier: "rtl-header")
        header.set(title: "Accounts", showsButton: true, sectionIndex: 0, delegate: HeaderDelegateSpy())
        forceRightToLeft(header)
        layout(header, width: 414, height: 37)
        XCTAssertEqual(header.titleLabel.frame.maxX, 398, accuracy: 0.5)
        XCTAssertEqual(header.editSectionButton.frame.maxX, header.titleLabel.frame.minX, accuracy: 0.5)

        let imageCell = ImageWithLabelTableViewCell(style: .default, reuseIdentifier: "rtl-image")
        imageCell.setup(text: "Title", extraText: "Extra", imageURL: nil, image: Images.circleFill)
        forceRightToLeft(imageCell)
        layout(imageCell, width: 320, height: 50)
        XCTAssertEqual(imageCell.iconImageView.frame.maxX, 304, accuracy: 0.5)
        XCTAssertEqual(imageCell.titleLabel.frame.maxX, imageCell.iconImageView.frame.minX - 8, accuracy: 0.5)
        XCTAssertEqual(imageCell.extraTitleLabel.frame.maxX, imageCell.titleLabel.frame.minX - 12, accuracy: 0.5)

        let sliderCell = GasPriceSliderTableViewCell(style: .default, reuseIdentifier: "rtl-slider")
        forceRightToLeft(sliderCell)
        layout(sliderCell, width: 326, height: 65)
        XCTAssertEqual(sliderCell.slowSpeedLabel.frame.maxX, 306, accuracy: 0.5)
        XCTAssertEqual(sliderCell.fastSpeedLabel.frame.minX, 20, accuracy: 0.5)

        let multilineCell = MultilineLabelTableViewCell(style: .default, reuseIdentifier: "rtl-multiline")
        multilineCell.setup(text: "RTL", largeFont: false, oneLine: true, pro: false)
        forceRightToLeft(multilineCell)
        layout(multilineCell, width: 320, height: 50)
        XCTAssertEqual(multilineCell.multilineLabel.frame.maxX, 304, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(multilineCell.multilineLabel.frame.minX, 11.5)
    }

    func testDynamicSystemColorsResolveInLightAndDarkAppearances() throws {
        let accountCell = AccountTableViewCell(style: .default, reuseIdentifier: "dark")
        accountCell.setup(title: "Dark", image: nil, isDisabled: false, customSelectionStyle: false, isSelected: false, delegate: AccountDelegateSpy())
        let selectedAccountCell = AccountTableViewCell(style: .default, reuseIdentifier: "selected")
        selectedAccountCell.setup(title: "Selected", image: nil, isDisabled: false, customSelectionStyle: true, isSelected: true, delegate: AccountDelegateSpy())
        let disabledAccountCell = AccountTableViewCell(style: .default, reuseIdentifier: "disabled")
        disabledAccountCell.setup(title: "Disabled", image: nil, isDisabled: true, customSelectionStyle: false, isSelected: false, delegate: AccountDelegateSpy())
        let multilineCell = MultilineLabelTableViewCell(style: .default, reuseIdentifier: "dark-multiline")
        multilineCell.setup(text: "Dark", largeFont: false, oneLine: false, pro: true)
        let previewCell = PreviewAccountTableViewCell(style: .default, reuseIdentifier: "colors-preview")
        let header = AccountsHeaderView(reuseIdentifier: "colors-header")
        let imageCell = ImageWithLabelTableViewCell(style: .default, reuseIdentifier: "colors-image")
        let stateView = DataStateView(frame: .zero)
        let stateImageView = try XCTUnwrap(stateView.subviews[2] as? UIImageView)
        let stateDescriptionLabel = try XCTUnwrap(stateView.subviews[3] as? UILabel)

        for traits in [
            UITraitCollection(userInterfaceStyle: .light),
            UITraitCollection(userInterfaceStyle: .dark)
        ] {
            XCTAssertEqual(accountCell.titleLabel.textColor.resolvedColor(with: traits), UIColor.label.resolvedColor(with: traits))
            XCTAssertEqual(accountCell.backgroundColor?.resolvedColor(with: traits), UIColor.secondarySystemGroupedBackground.resolvedColor(with: traits))
            XCTAssertEqual(selectedAccountCell.titleLabel.textColor.resolvedColor(with: traits), UIColor.white.resolvedColor(with: traits))
            XCTAssertEqual(selectedAccountCell.backgroundColor?.resolvedColor(with: traits), UIColor.tintColor.resolvedColor(with: traits))
            XCTAssertEqual(
                disabledAccountCell.backgroundColor?.resolvedColor(with: traits),
                UIColor.secondarySystemGroupedBackground.withAlphaComponent(0.35).resolvedColor(with: traits)
            )
            XCTAssertEqual(multilineCell.multilineLabel.textColor.resolvedColor(with: traits), UIColor.secondaryLabel.resolvedColor(with: traits))
            XCTAssertEqual(previewCell.indexLabel.textColor.resolvedColor(with: traits), UIColor.tertiaryLabel.resolvedColor(with: traits))
            XCTAssertEqual(header.titleLabel.textColor.resolvedColor(with: traits), UIColor.secondaryLabel.resolvedColor(with: traits))
            XCTAssertEqual(imageCell.extraTitleLabel.textColor.resolvedColor(with: traits), UIColor.tertiaryLabel.resolvedColor(with: traits))
            XCTAssertEqual(imageCell.iconImageView.tintColor.resolvedColor(with: traits), UIColor.secondarySystemFill.resolvedColor(with: traits))
            XCTAssertEqual(stateView.backgroundColor?.resolvedColor(with: traits), UIColor.systemGroupedBackground.resolvedColor(with: traits))
            XCTAssertEqual(stateImageView.tintColor.resolvedColor(with: traits), UIColor.tertiaryLabel.resolvedColor(with: traits))
            XCTAssertEqual(stateDescriptionLabel.textColor.resolvedColor(with: traits), UIColor.secondaryLabel.resolvedColor(with: traits))
        }
    }

    func testArchivedRuntimePropertiesMatchTheFormerNibs() throws {
        let accountCell = AccountTableViewCell(style: .default, reuseIdentifier: "properties-account")
        XCTAssertFalse(accountCell.titleLabel.isOpaque)
        XCTAssertEqual(accountCell.titleLabel.contentHuggingPriority(for: .horizontal), UILayoutPriority(251))
        XCTAssertEqual(accountCell.moreButton.configuration?.title, "")

        let previewCell = PreviewAccountTableViewCell(style: .default, reuseIdentifier: "properties-preview")
        XCTAssertFalse(previewCell.titleLabel.isOpaque)
        XCTAssertFalse(previewCell.indexLabel.isOpaque)
        XCTAssertFalse(previewCell.coinSwitch.isOpaque)

        let header = AccountsHeaderView(reuseIdentifier: "properties-header")
        XCTAssertFalse(header.titleLabel.isOpaque)
        XCTAssertTrue(header.invisibleButton.allTargets.contains(AnyHashable(NSNull())))
        XCTAssertEqual(header.editSectionButton.configuration?.title, "")
        XCTAssertEqual(header.invisibleButton.configuration?.title, "")

        let multilineCell = MultilineLabelTableViewCell(style: .default, reuseIdentifier: "properties-multiline")
        XCTAssertFalse(multilineCell.contentView.isOpaque)
        XCTAssertFalse(multilineCell.multilineLabel.isOpaque)
        XCTAssertEqual(multilineCell.multilineLabel.contentHuggingPriority(for: .horizontal), UILayoutPriority(251))
        XCTAssertEqual(multilineCell.multilineLabel.contentHuggingPriority(for: .vertical), UILayoutPriority(251))

        let imageCell = ImageWithLabelTableViewCell(style: .default, reuseIdentifier: "properties-image")
        XCTAssertFalse(imageCell.contentView.isOpaque)
        XCTAssertTrue(imageCell.iconImageView.isOpaque)
        XCTAssertFalse(imageCell.titleLabel.isOpaque)
        XCTAssertFalse(imageCell.extraTitleLabel.isOpaque)
        XCTAssertEqual(imageCell.titleLabel.contentHuggingPriority(for: .horizontal), UILayoutPriority(251))
        XCTAssertEqual(imageCell.extraTitleLabel.contentHuggingPriority(for: .vertical), UILayoutPriority(251))

        let sliderCell = GasPriceSliderTableViewCell(style: .default, reuseIdentifier: "properties-slider")
        XCTAssertFalse(sliderCell.contentView.isOpaque)
        XCTAssertFalse(sliderCell.slowSpeedLabel.isOpaque)
        XCTAssertFalse(sliderCell.fastSpeedLabel.isOpaque)
        XCTAssertEqual(sliderCell.slowSpeedLabel.contentHuggingPriority(for: .horizontal), UILayoutPriority(251))
        XCTAssertEqual(sliderCell.fastSpeedLabel.contentHuggingPriority(for: .vertical), UILayoutPriority(251))

        let stateView = DataStateView(frame: CGRect(x: 0, y: 0, width: 414, height: 896))
        let spinner = try XCTUnwrap(descendants(of: UIActivityIndicatorView.self, in: stateView).first)
        let imageView = try XCTUnwrap(stateView.subviews.compactMap { $0 as? UIImageView }.first)
        let labels = stateView.subviews.compactMap { $0 as? UILabel }
        let button = try XCTUnwrap(descendants(of: UIButton.self, in: stateView).first)
        XCTAssertTrue(spinner.isHidden)
        XCTAssertTrue(spinner.isAnimating)
        XCTAssertFalse(spinner.isOpaque)
        XCTAssertTrue(labels.allSatisfy { !$0.isOpaque })
        XCTAssertTrue(labels.allSatisfy {
            $0.contentHuggingPriority(for: .horizontal) == UILayoutPriority(251)
        })
        XCTAssertEqual(imageView.contentHuggingPriority(for: .vertical), UILayoutPriority(251))
        XCTAssertEqual(
            imageView.preferredSymbolConfiguration?.description,
            UIImage.SymbolConfiguration(scale: .default)
                .applying(UIImage.SymbolConfiguration(weight: .thin)).description
        )
        XCTAssertEqual(button.configuration?.title, "retry")
        XCTAssertNil(button.currentTitle)
    }

    func testConstraintRelationsConstantsAndPrioritiesMatchTheFormerNibs() {
        let accountCell = AccountTableViewCell(style: .default, reuseIdentifier: "constraints-account")
        let titleToMoreConstraint = accountCell.contentView.constraints.first { constraint in
            let items = [constraint.firstItem as AnyObject?, constraint.secondItem as AnyObject?]
            return items.contains { $0 === accountCell.titleLabel }
                && items.contains { $0 === accountCell.moreButton }
        }
        XCTAssertNil(titleToMoreConstraint)
        assertConstraint(in: accountCell.contentView, firstItem: accountCell.avatarImageView, firstAttribute: .top, secondItem: accountCell.contentView, secondAttribute: .top, constant: 10)
        assertConstraint(in: accountCell.contentView, firstItem: accountCell.avatarImageView, firstAttribute: .leading, secondItem: accountCell.contentView, secondAttribute: .leading, constant: 16)
        assertConstraint(in: accountCell.contentView, firstItem: accountCell.avatarImageView, firstAttribute: .width, constant: 30)
        assertConstraint(in: accountCell.contentView, firstItem: accountCell.avatarImageView, firstAttribute: .width, secondItem: accountCell.avatarImageView, secondAttribute: .height, constant: 0)
        assertConstraint(in: accountCell.contentView, firstItem: accountCell.contentView, firstAttribute: .bottom, relation: .greaterThanOrEqual, secondItem: accountCell.avatarImageView, secondAttribute: .bottom, constant: 10)
        assertConstraint(in: accountCell.contentView, firstItem: accountCell.titleLabel, firstAttribute: .leading, secondItem: accountCell.avatarImageView, secondAttribute: .trailing, constant: 12)
        assertConstraint(in: accountCell.contentView, firstItem: accountCell.titleLabel, firstAttribute: .centerY, secondItem: accountCell.contentView, secondAttribute: .centerY, constant: 0)
        assertConstraint(in: accountCell.contentView, firstItem: accountCell.moreButton, firstAttribute: .centerY, secondItem: accountCell.contentView, secondAttribute: .centerY, constant: 0)
        assertConstraint(in: accountCell.contentView, firstItem: accountCell.contentView, firstAttribute: .trailing, secondItem: accountCell.moreButton, secondAttribute: .trailing, constant: 5)

        let previewCell = PreviewAccountTableViewCell(style: .default, reuseIdentifier: "constraints-preview")
        assertConstraint(in: previewCell.contentView, firstItem: previewCell.indexLabel, firstAttribute: .leading, secondItem: previewCell.contentView, secondAttribute: .leading, constant: 10)
        assertConstraint(in: previewCell.contentView, firstItem: previewCell.indexLabel, firstAttribute: .centerY, secondItem: previewCell.contentView, secondAttribute: .centerY, constant: 0)
        assertConstraint(in: previewCell.contentView, firstItem: previewCell.indexLabel, firstAttribute: .width, constant: 16.5)
        assertConstraint(in: previewCell.contentView, firstItem: previewCell.logoImageView, firstAttribute: .top, secondItem: previewCell.contentView, secondAttribute: .top, constant: 10)
        assertConstraint(in: previewCell.contentView, firstItem: previewCell.logoImageView, firstAttribute: .leading, secondItem: previewCell.indexLabel, secondAttribute: .trailing, constant: 8)
        assertConstraint(in: previewCell.contentView, firstItem: previewCell.logoImageView, firstAttribute: .width, constant: 30)
        assertConstraint(in: previewCell.contentView, firstItem: previewCell.logoImageView, firstAttribute: .width, secondItem: previewCell.logoImageView, secondAttribute: .height, constant: 0)
        assertConstraint(in: previewCell.contentView, firstItem: previewCell.contentView, firstAttribute: .bottom, relation: .greaterThanOrEqual, secondItem: previewCell.logoImageView, secondAttribute: .bottom, constant: 10)
        assertConstraint(in: previewCell.contentView, firstItem: previewCell.titleLabel, firstAttribute: .leading, secondItem: previewCell.logoImageView, secondAttribute: .trailing, constant: 12)
        assertConstraint(in: previewCell.contentView, firstItem: previewCell.titleLabel, firstAttribute: .centerY, secondItem: previewCell.contentView, secondAttribute: .centerY, constant: 0)
        assertConstraint(in: previewCell.contentView, firstItem: previewCell.coinSwitch, firstAttribute: .leading, relation: .greaterThanOrEqual, secondItem: previewCell.titleLabel, secondAttribute: .trailing, constant: 8)
        assertConstraint(in: previewCell.contentView, firstItem: previewCell.coinSwitch, firstAttribute: .centerY, secondItem: previewCell.contentView, secondAttribute: .centerY, constant: 0)
        assertConstraint(in: previewCell.contentView, firstItem: previewCell.contentView, firstAttribute: .trailing, secondItem: previewCell.coinSwitch, secondAttribute: .trailing, constant: 12)

        let header = AccountsHeaderView(reuseIdentifier: "constraints-header")
        let safeArea = header.safeAreaLayoutGuide
        assertConstraint(in: header, firstItem: header.titleLabel, firstAttribute: .leading, secondItem: safeArea, secondAttribute: .leading, constant: 16)
        assertConstraint(in: header, firstItem: safeArea, firstAttribute: .bottom, secondItem: header.titleLabel, secondAttribute: .bottom, constant: 6)
        assertConstraint(in: header, firstItem: safeArea, firstAttribute: .trailing, relation: .greaterThanOrEqual, secondItem: header.titleLabel, secondAttribute: .trailing, constant: 16)
        assertConstraint(in: header, firstItem: header.editSectionButton, firstAttribute: .leading, secondItem: header.titleLabel, secondAttribute: .trailing, constant: 0)
        assertConstraint(in: header, firstItem: header.editSectionButton, firstAttribute: .width, constant: 32)
        assertConstraint(in: header, firstItem: header.editSectionButton, firstAttribute: .firstBaseline, secondItem: header.titleLabel, secondAttribute: .firstBaseline, constant: 0)
        assertConstraint(in: header, firstItem: header.invisibleButton, firstAttribute: .leading, secondItem: safeArea, secondAttribute: .leading, constant: 0)
        assertConstraint(in: header, firstItem: header.invisibleButton, firstAttribute: .trailing, secondItem: header.editSectionButton, secondAttribute: .trailing, constant: 20)
        assertConstraint(in: header, firstItem: header.invisibleButton, firstAttribute: .height, constant: 40)
        assertConstraint(in: header, firstItem: safeArea, firstAttribute: .bottom, secondItem: header.invisibleButton, secondAttribute: .bottom, constant: 0)

        let multilineCell = MultilineLabelTableViewCell(style: .default, reuseIdentifier: "constraints-multiline")
        assertConstraint(in: multilineCell.contentView, firstItem: multilineCell.multilineLabel, firstAttribute: .top, secondItem: multilineCell.contentView, secondAttribute: .top, constant: 12)
        assertConstraint(in: multilineCell.contentView, firstItem: multilineCell.multilineLabel, firstAttribute: .leading, secondItem: multilineCell.contentView, secondAttribute: .leading, constant: 16)
        assertConstraint(in: multilineCell.contentView, firstItem: multilineCell.contentView, firstAttribute: .bottom, relation: .greaterThanOrEqual, secondItem: multilineCell.multilineLabel, secondAttribute: .bottom, constant: 12)
        assertConstraint(in: multilineCell.contentView, firstItem: multilineCell.contentView, firstAttribute: .trailing, relation: .greaterThanOrEqual, secondItem: multilineCell.multilineLabel, secondAttribute: .trailing, constant: 12)

        let imageCell = ImageWithLabelTableViewCell(style: .default, reuseIdentifier: "constraints-image")
        assertConstraint(in: imageCell.contentView, firstItem: imageCell.iconImageView, firstAttribute: .leading, secondItem: imageCell.contentView, secondAttribute: .leading, constant: 16)
        assertConstraint(in: imageCell.contentView, firstItem: imageCell.iconImageView, firstAttribute: .centerY, secondItem: imageCell.contentView, secondAttribute: .centerY, constant: 0)
        assertConstraint(in: imageCell.contentView, firstItem: imageCell.iconImageView, firstAttribute: .height, constant: 30)
        assertConstraint(in: imageCell.contentView, firstItem: imageCell.iconImageView, firstAttribute: .width, secondItem: imageCell.iconImageView, secondAttribute: .height, constant: 0)
        assertConstraint(in: imageCell.contentView, firstItem: imageCell.titleLabel, firstAttribute: .top, secondItem: imageCell.contentView, secondAttribute: .top, constant: 12)
        assertConstraint(in: imageCell.contentView, firstItem: imageCell.titleLabel, firstAttribute: .leading, secondItem: imageCell.iconImageView, secondAttribute: .trailing, constant: 8)
        assertConstraint(in: imageCell.contentView, firstItem: imageCell.contentView, firstAttribute: .bottom, relation: .greaterThanOrEqual, secondItem: imageCell.titleLabel, secondAttribute: .bottom, constant: 12)
        assertConstraint(in: imageCell.contentView, firstItem: imageCell.contentView, firstAttribute: .trailing, relation: .greaterThanOrEqual, secondItem: imageCell.titleLabel, secondAttribute: .trailing, constant: 8)
        assertConstraint(in: imageCell.contentView, firstItem: imageCell.extraTitleLabel, firstAttribute: .leading, secondItem: imageCell.titleLabel, secondAttribute: .trailing, constant: 12)
        assertConstraint(in: imageCell.contentView, firstItem: imageCell.extraTitleLabel, firstAttribute: .centerY, secondItem: imageCell.titleLabel, secondAttribute: .centerY, constant: 0)
        assertConstraint(in: imageCell.contentView, firstItem: imageCell.contentView, firstAttribute: .trailing, relation: .greaterThanOrEqual, secondItem: imageCell.extraTitleLabel, secondAttribute: .trailing, constant: 12)
        XCTAssertEqual(imageCell.extraTitleLabel.contentCompressionResistancePriority(for: .horizontal), .defaultLow)

        let sliderCell = GasPriceSliderTableViewCell(style: .default, reuseIdentifier: "constraints-slider")
        assertConstraint(in: sliderCell.contentView, firstItem: sliderCell.slowSpeedLabel, firstAttribute: .leading, secondItem: sliderCell.contentView, secondAttribute: .leading, constant: 20)
        assertConstraint(in: sliderCell.contentView, firstItem: sliderCell.slowSpeedLabel, firstAttribute: .centerY, secondItem: sliderCell.slider, secondAttribute: .centerY, constant: 0)
        assertConstraint(in: sliderCell.contentView, firstItem: sliderCell.slider, firstAttribute: .top, secondItem: sliderCell.contentView, secondAttribute: .top, constant: 16)
        assertConstraint(in: sliderCell.contentView, firstItem: sliderCell.slider, firstAttribute: .leading, secondItem: sliderCell.slowSpeedLabel, secondAttribute: .trailing, constant: 8)
        assertConstraint(in: sliderCell.contentView, firstItem: sliderCell.slider, firstAttribute: .height, constant: 33)
        assertConstraint(in: sliderCell.contentView, firstItem: sliderCell.contentView, firstAttribute: .bottom, secondItem: sliderCell.slider, secondAttribute: .bottom, constant: 16)
        assertConstraint(in: sliderCell.contentView, firstItem: sliderCell.fastSpeedLabel, firstAttribute: .leading, secondItem: sliderCell.slider, secondAttribute: .trailing, constant: 8)
        assertConstraint(in: sliderCell.contentView, firstItem: sliderCell.fastSpeedLabel, firstAttribute: .centerY, secondItem: sliderCell.slider, secondAttribute: .centerY, constant: 0)
        assertConstraint(in: sliderCell.contentView, firstItem: sliderCell.contentView, firstAttribute: .trailing, secondItem: sliderCell.fastSpeedLabel, secondAttribute: .trailing, constant: 20)

        let stateView = DataStateView(frame: .zero)
        let spinner = stateView.subviews[0]
        let loadingLabel = stateView.subviews[1]
        let imageView = stateView.subviews[2]
        let descriptionLabel = stateView.subviews[3]
        let button = stateView.subviews[4]
        assertConstraint(in: stateView, firstItem: imageView, firstAttribute: .top, relation: .greaterThanOrEqual, secondItem: stateView, secondAttribute: .top, constant: 150)
        assertConstraint(in: stateView, firstItem: imageView, firstAttribute: .centerX, secondItem: stateView, secondAttribute: .centerX, constant: 0)
        assertConstraint(in: stateView, firstItem: imageView, firstAttribute: .width, secondItem: imageView, secondAttribute: .height, constant: 0)
        assertConstraint(in: stateView, firstItem: imageView, firstAttribute: .width, relation: .lessThanOrEqual, constant: 200)
        assertConstraint(in: stateView, firstItem: imageView, firstAttribute: .width, secondItem: stateView, secondAttribute: .width, constant: 0, multiplier: 3.0 / 7.0, priority: .defaultHigh)
        assertConstraint(in: stateView, firstItem: descriptionLabel, firstAttribute: .top, secondItem: imageView, secondAttribute: .bottom, constant: 8)
        assertConstraint(in: stateView, firstItem: descriptionLabel, firstAttribute: .centerX, secondItem: stateView, secondAttribute: .centerX, constant: 0)
        assertConstraint(in: stateView, firstItem: descriptionLabel, firstAttribute: .width, secondItem: stateView, secondAttribute: .width, constant: -40)
        assertConstraint(in: stateView, firstItem: button, firstAttribute: .top, secondItem: descriptionLabel, secondAttribute: .bottom, constant: 52)
        assertConstraint(in: stateView, firstItem: button, firstAttribute: .centerX, secondItem: stateView, secondAttribute: .centerX, constant: 0)
        assertConstraint(in: stateView, firstItem: button, firstAttribute: .height, constant: 52)
        assertConstraint(in: stateView, firstItem: button, firstAttribute: .width, relation: .greaterThanOrEqual, constant: 140)
        assertConstraint(in: stateView, firstItem: spinner, firstAttribute: .centerX, secondItem: stateView, secondAttribute: .centerX, constant: 0)
        assertConstraint(in: stateView, firstItem: spinner, firstAttribute: .top, secondItem: imageView, secondAttribute: .bottom, constant: -58.5)
        assertConstraint(in: stateView, firstItem: spinner, firstAttribute: .centerY, secondItem: stateView, secondAttribute: .centerY, constant: -50)
        assertConstraint(in: stateView, firstItem: loadingLabel, firstAttribute: .top, secondItem: spinner, secondAttribute: .bottom, constant: 8)
        assertConstraint(in: stateView, firstItem: loadingLabel, firstAttribute: .centerX, secondItem: spinner, secondAttribute: .centerX, constant: 0)
    }

    private func layout(_ view: UIView, width: CGFloat, height: CGFloat) {
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    private func assertSubviewOrder(
        _ actual: [UIView],
        _ expected: [UIView],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actualView, expectedView) in zip(actual, expected) {
            XCTAssertTrue(actualView === expectedView, file: file, line: line)
        }
    }

    private func assertDirectSubviewOrder(
        _ expected: [UIView],
        in parent: UIView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = parent.subviews.filter { candidate in
            expected.contains { candidate === $0 }
        }
        assertSubviewOrder(actual, expected, file: file, line: line)
        for view in expected {
            XCTAssertTrue(view.superview === parent, file: file, line: line)
        }
    }

    private func assertFont(
        _ actual: UIFont?,
        equals expected: UIFont,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            XCTFail("Expected a font", file: file, line: line)
            return
        }
        XCTAssertEqual(actual.pointSize, expected.pointSize, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actual.fontName, expected.fontName, file: file, line: line)
    }

    private func assertConstraint(
        in root: UIView,
        firstItem: AnyObject,
        firstAttribute: NSLayoutConstraint.Attribute,
        relation: NSLayoutConstraint.Relation = .equal,
        secondItem: AnyObject? = nil,
        secondAttribute: NSLayoutConstraint.Attribute = .notAnAttribute,
        constant: CGFloat,
        multiplier: CGFloat = 1,
        priority: UILayoutPriority = .required,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let matches = allConstraints(in: root).filter { constraint in
            guard let actualFirstItem = constraint.firstItem as AnyObject?,
                  actualFirstItem === firstItem,
                  constraint.firstAttribute == firstAttribute,
                  constraint.relation == relation,
                  constraint.secondAttribute == secondAttribute
            else { return false }

            if let secondItem {
                guard let actualSecondItem = constraint.secondItem as AnyObject? else { return false }
                return actualSecondItem === secondItem
            }
            return constraint.secondItem == nil
        }

        XCTAssertEqual(matches.count, 1, "Expected exactly one authored constraint", file: file, line: line)
        guard let constraint = matches.first else { return }
        XCTAssertEqual(constraint.constant, constant, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(constraint.multiplier, multiplier, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(constraint.priority, priority, file: file, line: line)
    }

    private func allConstraints(in root: UIView) -> [NSLayoutConstraint] {
        root.constraints + root.subviews.flatMap(allConstraints(in:))
    }

    private func assertImage(
        _ actual: UIImage?,
        matches expected: UIImage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(normalizedImageData(actual), normalizedImageData(expected), file: file, line: line)
    }

    private func imagesMatch(_ lhs: UIImage?, _ rhs: UIImage?) -> Bool {
        normalizedImageData(lhs) == normalizedImageData(rhs)
    }

    private func normalizedImageData(_ image: UIImage?) -> Data? {
        guard let image else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData()
    }

    private func fittingHeight(of cell: UITableViewCell, width: CGFloat) -> CGFloat {
        cell.bounds = CGRect(x: 0, y: 0, width: width, height: 1)
        cell.contentView.bounds = cell.bounds
        return cell.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
    }

    private func forceRightToLeft(_ view: UIView) {
        view.semanticContentAttribute = .forceRightToLeft
        if let cell = view as? UITableViewCell {
            cell.contentView.semanticContentAttribute = .forceRightToLeft
        }
    }

    private func solidImage(color: UIColor) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for asynchronous view state")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func descendants<View: UIView>(of type: View.Type, in root: UIView) -> [View] {
        root.subviews.flatMap { subview -> [View] in
            let match = subview as? View
            return (match.map { [$0] } ?? []) + descendants(of: type, in: subview)
        }
    }

    private func effectiveSeparatorInset(source: CGFloat) -> CGFloat {
#if os(visionOS)
        return source
#else
        return source + 8
#endif
    }
}

private final class AccountDelegateSpy: AccountTableViewCellDelegate {
    private(set) var tapCount = 0
    private(set) weak var lastCell: AccountTableViewCell?

    func didTapMoreButton(accountCell: AccountTableViewCell) {
        tapCount += 1
        lastCell = accountCell
    }
}

private final class PreviewDelegateSpy: PreviewAccountTableViewCellDelegate {
    private(set) var toggleCount = 0
    private(set) weak var lastCell: PreviewAccountTableViewCell?

    func didToggleSwitch(_ sender: PreviewAccountTableViewCell) {
        toggleCount += 1
        lastCell = sender
    }
}

private final class HeaderDelegateSpy: AccountsHeaderViewDelegate {
    private(set) var tapCount = 0
    private(set) var lastSection: Int?
    private(set) weak var lastHeader: AccountsHeaderView?

    func didTapEditButton(_ sender: AccountsHeaderView, sectionIndex: Int) {
        tapCount += 1
        lastSection = sectionIndex
        lastHeader = sender
    }
}

private final class SliderDelegateSpy: GasPriceSliderDelegate {
    private(set) var startedCount = 0
    private(set) var endedCount = 0
    private(set) var changedValues = [Double]()

    func sliderInteractionStarted() {
        startedCount += 1
    }

    func sliderInteractionEnded() {
        endedCount += 1
    }

    func sliderValueChanged(value: Double) {
        changedValues.append(value)
    }
}

private final class DataStateHostViewController: UIViewController, DataStateContainer {}

private enum ProgrammaticUIKitURLSessionDataTaskStub {
    private struct Response {
        let data: Data
        let delay: TimeInterval
    }

    private static let lock = NSLock()
    private static var isInstalled = false
    private static var defaultResponse = Response(data: Data(), delay: 0)
    private static var responses = [String: Response]()
    private static var tasks = [String: URLSessionDataTask]()
    private static var recordedPaths = Set<String>()

    static var requestedPaths: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return recordedPaths
    }

    static func install() {
        guard !isInstalled,
              let original = class_getInstanceMethod(
                URLSession.self,
                NSSelectorFromString("dataTaskWithURL:completionHandler:")
              ),
              let replacement = class_getInstanceMethod(
                URLSession.self,
                #selector(URLSession.programmaticUIKit_dataTask(with:completionHandler:))
              )
        else {
            XCTFail("Could not install the URLSession data-task stub")
            return
        }
        method_exchangeImplementations(original, replacement)
        isInstalled = true
    }

    static func uninstall() {
        guard isInstalled,
              let original = class_getInstanceMethod(
                URLSession.self,
                NSSelectorFromString("dataTaskWithURL:completionHandler:")
              ),
              let replacement = class_getInstanceMethod(
                URLSession.self,
                #selector(URLSession.programmaticUIKit_dataTask(with:completionHandler:))
              )
        else { return }
        method_exchangeImplementations(original, replacement)
        isInstalled = false
    }

    static func reset(with responseData: Data) {
        lock.lock()
        defaultResponse = Response(data: responseData, delay: 0)
        responses = [:]
        recordedPaths = []
        tasks = [:]
        lock.unlock()
    }

    static func setResponse(_ data: Data, delay: TimeInterval, for path: String) {
        lock.lock()
        responses[path] = Response(data: data, delay: delay)
        lock.unlock()
    }

    static func response(for path: String) -> (data: Data, delay: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        let response = responses[path] ?? defaultResponse
        return (response.data, response.delay)
    }

    static func record(task: URLSessionDataTask, for path: String) {
        lock.lock()
        recordedPaths.insert(path)
        tasks[path] = task
        lock.unlock()
    }

    static func task(for path: String) -> URLSessionDataTask? {
        lock.lock()
        defer { lock.unlock() }
        return tasks[path]
    }
}

private extension URLSession {
    @objc(programmaticUIKit_dataTaskWithURL:completionHandler:)
    dynamic func programmaticUIKit_dataTask(
        with url: URL,
        completionHandler: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void
    ) -> URLSessionDataTask {
        guard url.host == "programmatic-uikit.invalid" else {
            return programmaticUIKit_dataTask(with: url, completionHandler: completionHandler)
        }

        let response = ProgrammaticUIKitURLSessionDataTaskStub.response(for: url.path)
        let task = ProgrammaticUIKitStubDataTask(
            url: url,
            responseData: response.data,
            responseDelay: response.delay,
            completionHandler: completionHandler
        )
        ProgrammaticUIKitURLSessionDataTaskStub.record(task: task, for: url.path)
        return task
    }
}

private final class ProgrammaticUIKitStubDataTask: URLSessionDataTask, @unchecked Sendable {
    private let stateLock = NSLock()
    private let url: URL
    private let responseData: Data
    private let responseDelay: TimeInterval
    private let completionHandler: @Sendable (Data?, URLResponse?, Error?) -> Void
    private var didScheduleCompletion = false
    private var cancelled = false
    private var resumed = false

    var wasCancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled
    }

    var wasResumed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return resumed
    }

    init(
        url: URL,
        responseData: Data,
        responseDelay: TimeInterval,
        completionHandler: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void
    ) {
        self.url = url
        self.responseData = responseData
        self.responseDelay = responseDelay
        self.completionHandler = completionHandler
        super.init()
    }

    override func cancel() {
        stateLock.lock()
        cancelled = true
        stateLock.unlock()
    }

    override func resume() {
        stateLock.lock()
        resumed = true
        let shouldScheduleCompletion = !didScheduleCompletion
        didScheduleCompletion = true
        stateLock.unlock()

        guard shouldScheduleCompletion else { return }
        let url = url
        let responseData = responseData
        let completionHandler = completionHandler
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + responseDelay) {
            let urlResponse = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/png"]
            )!
            completionHandler(responseData, urlResponse, nil)
        }
    }
}
