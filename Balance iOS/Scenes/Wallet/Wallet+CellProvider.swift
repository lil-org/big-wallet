import UIKit
import SPDiffable
import BlockiesSwift

extension SPDiffableTableDataSource.CellProvider {
    
    public static var wallet: SPDiffableTableDataSource.CellProvider  {
        return SPDiffableTableDataSource.CellProvider() { (tableView, indexPath, item) -> UITableViewCell? in
            guard let wrapperItem = item as? SPDiffableWrapperItem else { return nil }
            guard let walletModel = wrapperItem.model as? TokenaryWallet else { return nil }
            let cell = tableView.dequeueReusableCell(withClass: WalletTableViewCell.self, for: indexPath)
            
            var formattedAddress = walletModel.ethereumAddress ?? .space
            formattedAddress.insert("\n", at: formattedAddress.index(formattedAddress.startIndex, offsetBy: (formattedAddress.count / 2)))
            
            cell.adressLabel.text = formattedAddress
            
            if let name = walletModel.walletName {
                cell.titleLabel.text = name
                cell.titleLabel.textColor = .label
            } else {
                cell.titleLabel.text = "No Name"
                cell.titleLabel.textColor = .secondaryLabel
            }
            if let adress = walletModel.ethereumAddress {
                if let image = Blockies(seed: adress.lowercased()).createImage() {
                    cell.avatarView.avatarAppearance = .avatar(image)
                }
            }
            cell.adressLabel.numberOfLines = .zero
            cell.layoutSubviews()
            return cell
        }
    }
}
