import UIKit
import SPDiffable
import SparrowKit
import Constants
import SPPermissions
import SPPermissionsNotification

class SettingsController: SPDiffableTableController {
    
    init() {
        super.init(style: .insetGrouped)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = Texts.Settings.title
        configureDiffable(sections: content, cellProviders: SPDiffableTableDataSource.CellProvider.default)
        
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            self.diffableDataSource?.set(self.content, animated: true, completion: nil)
        }
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
                        icon: .init(named: "settings-notifications"),
                        isOn: SPPermissions.Permission.notification.authorized,
                        action: { state in
                            if SPPermissions.Permission.notification.notDetermined {
                                SPPermissions.Permission.notification.request {
                                    self.diffableDataSource?.set(self.content, animated: true, completion: nil)
                                }
                            } else {
                                self.diffableDataSource?.set(self.content, animated: true, completion: nil)
                                UIApplication.shared.openSettings()
                            }
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
                        text: "Appearance",
                        icon: .init(named: "settings-appearance"),
                        accessoryType: .disclosureIndicator,
                        selectionStyle: .default,
                        action: { item, indexPath in
                            guard let navigationController = self.navigationController else { return }
                            Presenter.App.Settings.showAppearance(on: navigationController)
                        }
                    ),
                    SPDiffableTableRow(
                        text: "Languages",
                        icon: .init(named: "settings-language"),
                        accessoryType: .disclosureIndicator,
                        selectionStyle: .default,
                        action: { item, indexPath in
                            guard let navigationController = self.navigationController else { return }
                            Presenter.App.Settings.showLanguages(on: navigationController)
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
                        icon: .init(named: "settings-aboutus"),
                        accessoryType: .disclosureIndicator,
                        selectionStyle: .default,
                        action: { item, indexPath in
                            self.tableView.deselectRow(at: indexPath, animated: true)
                            UIApplication.shared.open(URL.init(string: "https://twitter.com/Balance_io")!, options: [:], completionHandler: nil)
                        }
                    )
                ]
            ),
            .init(id: "destroy", header: nil, footer: nil, items: [
                SPDiffableTableRow(text: "Destroy (Debug Only!)", selectionStyle: .default, action: { item, indexPath in
                    
                    do {
                        try? WalletsManager.shared.destroy()
                    }
                    Keychain.shared.removePassword()
                    Flags.seen_tutorial = false
                    Flags.show_safari_extension_advice = true
                    delay(1, closure: {
                        fatalError()
                    })
                })
            ])
        ]
    }
}
