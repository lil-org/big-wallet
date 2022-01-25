import UIKit
import SPDiffable

class SettingsController: SPDiffableTableController {
    
    init() {
        super.init(style: .insetGrouped)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = Texts.Settings.title
        configureDiffable(sections: content, cellProviders: SPDiffableTableDataSource.CellProvider.default)
    }
    
    internal var content: [SPDiffableSection] {
        return [
            .init(
                id: "notification",
                header: SPDiffableTextHeaderFooter(text: "Notifications"),
                footer: SPDiffableTextHeaderFooter(text: "Here description about notification and dont boring user. Maybe some anonces."),
                items: [
                    SPDiffableTableRowSwitch(
                        text: "Notifcations",
                        icon: .init(named: "Settings Icon - Notifications"),
                        isOn: true,
                        action: { state in
                            
                        }
                    )
                ]
            ),
            .init(
                id: "App",
                header: SPDiffableTextHeaderFooter(text: "App"),
                footer: SPDiffableTextHeaderFooter(text: "Here description about notification and dont boring user. Maybe some anonces."),
                items: [
                    SPDiffableTableRow(
                        text: "Colors",
                        icon: .init(named: "Settings Icon - Colors"),
                        accessoryType: .disclosureIndicator,
                        selectionStyle: .default,
                        action: { item, indexPath in
                            
                        }
                    ),
                    SPDiffableTableRow(
                        text: "Appearance",
                        icon: .init(named: "Settings Icon - Appearance"),
                        accessoryType: .disclosureIndicator,
                        selectionStyle: .default,
                        action: { item, indexPath in
                            
                        }
                    ),
                    SPDiffableTableRow(
                        text: "Languages",
                        icon: .init(named: "Settings Icon - Languages"),
                        accessoryType: .disclosureIndicator,
                        selectionStyle: .default,
                        action: { item, indexPath in
                            
                        }
                    )
                ]
            ),
            .init(
                id: "about",
                header: nil,
                footer: SPDiffableTextHeaderFooter(text: "Deescription about app and usage and privacy."),
                items: [
                    SPDiffableTableRow(
                        text: "About App",
                        icon: .init(named: "Settings Icon - About Us"),
                        accessoryType: .disclosureIndicator,
                        selectionStyle: .default,
                        action: { item, indexPath in
                            
                        }
                    )
                ]
            )
        ]
    }
}
