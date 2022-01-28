import UIKit
import SPDiffable
import NativeUIKit

class SettingsAppearanceController: SPDiffableTableController {
    
    init() {
        super.init(style: .insetGrouped)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.tableHeaderView = UIView()
        tableView.tableHeaderView?.frame.setHeight(NativeLayout.Spaces.default)
        navigationItem.title = "Appearance"
        configureDiffable(sections: content, cellProviders: SPDiffableTableDataSource.CellProvider.default)
    }
    
    // MARK: - Diffable
    
    internal var content: [SPDiffableSection] {
        var sections: [SPDiffableSection] = [
            .init(
                id: Section.automatic.id,
                header: nil,
                footer: SPDiffableTextHeaderFooter(text: "Interface will be same like system."),
                items: [
                    SPDiffableTableRowSwitch(
                        id: Item.automatic_switch.id,
                        text: "Automatic",
                        icon: nil,
                        isOn: Appearance.currentInterfaceAppearance == .system,
                        action: { [weak self] state in
                            guard let self = self else { return }
                            if state {
                                Appearance.currentInterfaceAppearance = .system
                            } else {
                                Appearance.currentInterfaceAppearance = .light
                            }
                            self.diffableDataSource?.set(self.content, animated: true, completion: nil)
                        }
                    )
                ]
            )
        ]
        
        if Appearance.currentInterfaceAppearance != .system {
            sections.append(
                .init(
                    id: Section.choose_list.id,
                    header: SPDiffableTextHeaderFooter(text: "Force"),
                    footer: SPDiffableTextHeaderFooter(text: "This style will be always. Ignoring system interface style."),
                    items: [
                        SPDiffableTableRow(
                            id: Item.force_light.id,
                            text: "Always Light",
                            detail: nil,
                            icon: nil,
                            accessoryType: Appearance.currentInterfaceAppearance == .light ? .checkmark : .none,
                            selectionStyle: .none,
                            action: { [weak self] item, indexPath in
                                guard let self = self else { return }
                                UIFeedbackGenerator.impactOccurred(.light)
                                Appearance.currentInterfaceAppearance = .light
                                self.diffableDataSource?.set(self.content, animated: true)
                            }
                        ),
                        SPDiffableTableRow(
                            id: Item.force_dark.id,
                            text: "Always Dark",
                            detail: nil,
                            icon: nil,
                            accessoryType: Appearance.currentInterfaceAppearance == .dark ? .checkmark : .none,
                            selectionStyle: .none,
                            action: { [weak self] item, indexPath in
                                guard let self = self else { return }
                                UIFeedbackGenerator.impactOccurred(.light)
                                Appearance.currentInterfaceAppearance = .dark
                                self.diffableDataSource?.set(self.content, animated: true)
                            }
                        )
                    ]
                )
            )
        }
        
        return sections
    }
    
    enum Section: String {
        
        case automatic
        case choose_list
        
        var id: String { rawValue }
    }
    
    enum Item: String {
        
        case automatic_switch
        case force_light
        case force_dark
        
        var id: String { rawValue }
    }
}
