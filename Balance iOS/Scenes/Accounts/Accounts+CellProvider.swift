import UIKit
import SPDiffable
import BlockiesSwift

extension SPDiffableTableDataSource.CellProvider {
    
    public static var wallet: SPDiffableTableDataSource.CellProvider  {
        return SPDiffableTableDataSource.CellProvider() { (tableView, indexPath, item) -> UITableViewCell? in
            guard let wrapperItem = item as? SPDiffableWrapperItem else { return nil }
            guard let walletModel = wrapperItem.model as? TokenaryWallet else { return nil }
            let cell = tableView.dequeueReusableCell(withClass: Account2TableViewCell.self, for: indexPath)
            cell.adressLabel.text = walletModel.ethereumAddress
            cell.titleLabel.text = ["First Wallet", "Second Wallet", "Custom Name Wallet", "Additional Wallet"].randomElement()!
            if let adress = walletModel.ethereumAddress {
                if let image = Blockies(seed: adress.lowercased()).createImage() {
                    cell.avatarView.avatarAppearance = .avatar(image)
                }
            }
            cell.layoutSubviews()
            return cell
        }
    }
}
