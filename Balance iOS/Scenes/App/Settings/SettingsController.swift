import UIKit
import SPSafeSymbols
import SPSettingsIcons
import NativeUIKit
import SPDiffable
import SparrowKit
import Constants
import SPPermissions
import SPPermissionsNotification
import SPAlert
import Intercom

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
        configureDiffable(sections: content, cellProviders: [.button] + SPDiffableTableDataSource.CellProvider.default)
        tableView.register(NativeLeftButtonTableViewCell.self)
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            self.diffableDataSource?.set(self.content, animated: true, completion: nil)
        }
    }
    
    internal var content: [SPDiffableSection] {
        return [
            .init(
                id: "notification",
                header: SPDiffableTextHeaderFooter(text: Texts.Settings.notification_header),
                footer: SPDiffableTextHeaderFooter(text: Texts.Settings.notification_footer),
                items: [
                    SPDiffableTableRowSwitch(
                        text: Texts.Settings.notification_title,
                        icon: .generateSettingsIcon("bell.fill", backgroundColor: .systemRed),
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
                id: "cell-style",
                header: SPDiffableTextHeaderFooter(text: Texts.Settings.wallet_style_header),
                footer: SPDiffableTextHeaderFooter(text: Texts.Settings.wallet_style_footer),
                items: [
                    SPDiffableTableRow(
                        text: Texts.Settings.wallet_style_title,
                        icon: .generateSettingsIcon(SPSafeSymbol.list.bulletRectangleFill.name, backgroundColor: .systemIndigo),
                        accessoryType: .disclosureIndicator,
                        selectionStyle: .default,
                        action: { item, indexPath in
                            guard let navigationController = self.navigationController else { return }
                            Presenter.App.Settings.showWalletStyle(on: navigationController)
                        }
                    )
                ]
            ),
            .init(
                id: "App",
                header: SPDiffableTextHeaderFooter(text: Texts.Settings.app_header),
                footer: SPDiffableTextHeaderFooter(text: Texts.Settings.app_footer),
                items: [
                    SPDiffableTableRow(
                        text: Texts.Settings.appearance_title,
                        icon: .generateSettingsIcon("lightbulb.fill", backgroundColor: .systemYellow),
                        accessoryType: .disclosureIndicator,
                        selectionStyle: .default,
                        action: { item, indexPath in
                            guard let navigationController = self.navigationController else { return }
                            Presenter.App.Settings.showAppearance(on: navigationController)
                        }
                    ),
                    SPDiffableTableRow(
                        text: Texts.Settings.language_title,
                        icon: .generateSettingsIcon("globe", backgroundColor: .systemGray),
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
                footer: SPDiffableTextHeaderFooter(text: Texts.Settings.about_footer),
                items: [
                    SPDiffableTableRow(
                        text: Texts.Settings.about_title,
                        icon: .generateSettingsIcon("person.2.fill", backgroundColor: .systemIndigo),
                        accessoryType: .disclosureIndicator,
                        selectionStyle: .default,
                        action: { item, indexPath in
                            self.tableView.deselectRow(at: indexPath, animated: true)
                            UIApplication.shared.open(URL.init(string: "https://twitter.com/Balance_io")!, options: [:], completionHandler: nil)
                        }
                    ),
                    SPDiffableTableRow(
                        text: Texts.Settings.intercom_title,
                        icon: .generateSettingsIcon("questionmark.circle.fill", backgroundColor: .systemGreen),
                        accessoryType: .disclosureIndicator,
                        selectionStyle: .default,
                        action: { item, indexPath in
                            self.tableView.deselectRow(at: indexPath, animated: true)
                            Intercom.presentMessenger()
                        }
                    )
                ]
            ),
            .init(id: "destroy", header: nil, footer: nil, items: [
                NativeDiffableLeftButton(
                    text: Texts.Wallet.Destroy.action,
                    textColor: .destructiveColor,
                    detail: nil,
                    detailColor: .clear,
                    icon: .init(SPSafeSymbol.exclamationmark.triangleFill).withTintColor(.destructiveColor, renderingMode: .alwaysOriginal),
                    accessoryType: .none,
                    action: { item, indexPath in
                        guard let cell = self.tableView.cellForRow(at: indexPath) else { return }
                        WalletsManager.startDestroyProcess(on: self, sourceView: cell, completion: { destroyed in
                            if destroyed {
                                /*Presenter.App.showOnboarding(on: self, afterAction: {
                                    Presenter.Crypto.showWalletOnboarding(on: self)
                                    Flags.seen_tutorial = true
                                })*/
                                SPAlert.present(title: Texts.Wallet.Destroy.completed, message: nil, preset: .done, completion:  nil)
                            }
                        })
                    }
                )
            ])
        ]
    }
}
