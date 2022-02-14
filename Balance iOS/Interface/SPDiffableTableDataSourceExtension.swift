import UIKit
import SPDiffable
import NativeUIKit

extension SPDiffableTableDataSource.CellProvider {
    
    public static var buttonMultiLinesMonospaced: SPDiffableTableDataSource.CellProvider  {
        return SPDiffableTableDataSource.CellProvider() { (tableView, indexPath, item) -> UITableViewCell? in
            guard item.id == "address-public-id" else { return nil }
            guard let item = item as? NativeDiffableLeftButton else { return nil }
            let cell = tableView.dequeueReusableCell(withClass: NativeLeftButtonTableViewCell.self, for: indexPath)
            cell.textLabel?.text = item.text
            cell.textLabel?.font = .preferredFont(forTextStyle: .body, weight: .medium).monospaced
            cell.textLabel?.minimumScaleFactor = 0.1
            cell.textLabel?.adjustsFontSizeToFitWidth = true
            cell.textLabel?.textColor = item.textColor
            cell.textLabel?.numberOfLines = 2
            cell.detailTextLabel?.text = item.detail
            cell.detailTextLabel?.textColor = item.detailColor
            cell.imageView?.image = item.icon
            cell.accessoryType = item.accessoryType
            cell.higlightStyle = .content
            return cell
        }
    }
    
    public static var blockiesAddressRow: SPDiffableTableDataSource.CellProvider  {
        return SPDiffableTableDataSource.CellProvider() { (tableView, indexPath, item) -> UITableViewCell? in
            guard item.id == "blockies-address-row" else { return nil }
            guard let item = item as? SPDiffableTableRow else { return nil }
            let cell = tableView.dequeueReusableCell(withClass: BlockiesAddressTableViewCell.self, for: indexPath)
            cell.addressLabel.text = item.text
            
            cell.avatarView.avatarAppearance = .avatar(item.icon!)
            
            cell.accessoryType = item.accessoryType
            
            cell.layoutSubviews()
            
            return cell
        }
    }
    
    public static var buttonMultiLines: SPDiffableTableDataSource.CellProvider  {
        return SPDiffableTableDataSource.CellProvider() { (tableView, indexPath, item) -> UITableViewCell? in
            guard let item = item as? NativeDiffableLeftButton else { return nil }
            let cell = tableView.dequeueReusableCell(withClass: NativeLeftButtonTableViewCell.self, for: indexPath)
            cell.textLabel?.text = item.text
            cell.textLabel?.textColor = item.textColor
            cell.textLabel?.numberOfLines = .zero
            cell.detailTextLabel?.text = item.detail
            cell.detailTextLabel?.textColor = item.detailColor
            cell.imageView?.image = item.icon
            cell.accessoryType = item.accessoryType
            cell.higlightStyle = .content
            return cell
        }
    }
    
    public static var rowDetailMultiLines: SPDiffableTableDataSource.CellProvider  {
        return SPDiffableTableDataSource.CellProvider() { (tableView, indexPath, item) -> UITableViewCell? in
            guard let item = item as? SPDiffableTableRow else { return nil }
            let cell = tableView.dequeueReusableCell(withIdentifier: SPDiffableTableViewCell.reuseIdentifier, for: indexPath) as! SPDiffableTableViewCell
            cell.textLabel?.text = item.text
            cell.textLabel?.numberOfLines = .zero
            cell.detailTextLabel?.text = item.detail
            cell.detailTextLabel?.numberOfLines = .zero
            cell.imageView?.image = item.icon
            cell.accessoryType = item.accessoryType
            cell.selectionStyle = item.selectionStyle
            return cell
        }
    }
    
    public static var balance: SPDiffableTableDataSource.CellProvider  {
        return SPDiffableTableDataSource.CellProvider() { (tableView, indexPath, item) -> UITableViewCell? in
            guard let wrapperItem = item as? SPDiffableWrapperItem else { return nil }
            guard let data = wrapperItem.model as? BalanceData else { return nil }
            let cell = tableView.dequeueReusableCell(withIdentifier: SPDiffableSubtitleTableViewCell.reuseIdentifier, for: indexPath) as! SPDiffableSubtitleTableViewCell
            cell.textLabel?.text = data.chain.name
            cell.textLabel?.font = UIFont.preferredFont(forTextStyle: .footnote, weight: .medium)
            cell.textLabel?.textColor = .secondaryLabel
            cell.textLabel?.numberOfLines = .zero
            cell.detailTextLabel?.text = "\((data.balance ?? "0")) \(data.chain.symbol)"
            cell.detailTextLabel?.font = UIFont.preferredFont(forTextStyle: .body)
            cell.detailTextLabel?.textColor = .label
            cell.detailTextLabel?.adjustsFontSizeToFitWidth = true
            cell.detailTextLabel?.minimumScaleFactor = 0.1
            cell.imageView?.image = nil
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }
    }
}
