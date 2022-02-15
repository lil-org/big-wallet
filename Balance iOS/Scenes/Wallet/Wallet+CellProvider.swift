import UIKit
import SPDiffable
import BlockiesSwift

extension SPDiffableTableDataSource.CellProvider {
    
    public static var wallet: SPDiffableTableDataSource.CellProvider  {
        return SPDiffableTableDataSource.CellProvider() { (tableView, indexPath, item) -> UITableViewCell? in
            guard let wrapperItem = item as? SPDiffableWrapperItem else { return nil }
            guard let walletModel = wrapperItem.model as? TokenaryWallet else { return nil }
            let cell = tableView.dequeueReusableCell(withClass: WalletTableViewCell.self, for: indexPath)
            
            let addAddress = {
                var formattedAddress = walletModel.ethereumAddress ?? .space
                formattedAddress.insert("\n", at: formattedAddress.index(formattedAddress.startIndex, offsetBy: (formattedAddress.count / 2)))
                
                cell.addressLabel.text = formattedAddress
                cell.addressLabel.minimumScaleFactor = 0.1
                cell.addressLabel.numberOfLines = 2
                cell.addressLabel.adjustsFontSizeToFitWidth = true
            }
            
            let addName = {
                if let name = walletModel.walletName {
                    cell.titleLabel.text = name
                    cell.titleLabel.textColor = .label
                } else {
                    cell.titleLabel.text = Texts.Wallet.no_name
                    cell.titleLabel.textColor = .secondaryLabel
                }
            }
            
            switch WalletStyle.current {
            case .nameAndAddress:
                addAddress()
                addName()
            case .onlyAddress:
                addAddress()
            case .onlyName:
                addName()
            }
            
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
