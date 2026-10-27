import Foundation
import WalletAuthority
func forbidden(_ data: Data) throws { _ = try JSONDecoder().decode(NativeApprovalReview.self, from: data) }
