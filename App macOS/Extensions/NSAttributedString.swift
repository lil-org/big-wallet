// ∅ 2025 lil org

import WalletCore

extension NSAttributedString {
    
    static func accountImageAttachment(account: Account) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = account.image?.withCornerRadius(7)
        attachment.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
        let attachmentString = NSAttributedString(attachment: attachment)
        return attachmentString
    }
    
}
