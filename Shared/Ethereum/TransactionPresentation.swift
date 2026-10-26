import WalletDomain
import WalletAuthority
import WalletNetworking
import Foundation

extension Transaction {
    var nonEmptyDataWithLabel: String? {
        if data.count > 2 {
            return dataWithLabel
        } else {
            return nil
        }
    }
    

    var dataWithLabel: String {
        return "\(Strings.data): \(data)"
    }
    

    func gasPriceWithLabel(chain: EthereumNetwork) -> String {
        let gwei: String
        if let gasPriceGwei = gasPriceGwei {
            gwei = String(gasPriceGwei) + (chain.symbolIsETH ? " \(Strings.gwei)" : "")
        } else {
            gwei = Strings.calculating.withEllipsis
        }
        return "\(Strings.gasPrice): \(gwei)"
    }
    

    func feeWithSymbol(
        chain: EthereumNetwork,
        price: Double?,
        label: String = Strings.fee
    ) -> String {
        return formattedNetworkFee(
            estimatedFeeValue,
            chain: chain,
            price: price,
            label: label
        )
    }


    private func formattedNetworkFee(
        _ fee: BigUInt?,
        chain: EthereumNetwork,
        price: Double?,
        label: String
    ) -> String {
        let feeString: String
        if let fee {
            let costString = chain.mightShowPrice
                ? cost(value: fee, price: price)
                : ""
            feeString = fee.eth(shortest: true) +
                " \(chain.symbol)" +
                costString
        } else {
            feeString = Strings.calculating.withEllipsis
        }
        return "\(label): \(feeString)"
    }


    func feeSummaryLines(
        chain: EthereumNetwork,
        price: Double?
    ) -> [String] {
        guard usesEIP1559Fees else {
            return [
                feeWithSymbol(chain: chain, price: price),
                gasPriceWithLabel(chain: chain),
            ]
        }

        return [
            formattedNetworkFee(
                maximumFeeValue,
                chain: chain,
                price: price,
                label: Strings.fee
            ),
        ]
    }
    

    func valueWithSymbol(chain: EthereumNetwork, price: Double?, withLabel: Bool) -> String? {
        guard let value,
              let value = EthereumQuantity.parseUInt256(
                  value,
                  allowPrefixless: true
              ) else {
            return nil
        }
        let costString = chain.mightShowPrice ? cost(value: value, price: price) : ""
        let valueString = "\(value.eth()) \(chain.symbol)" + costString
        return withLabel ? "\(Strings.value): " + valueString : valueString
    }
    

    private func cost(value: BigUInt, price: Double?) -> String {
        guard let price = price else { return "" }
        let ethValue = value.ethDouble
        let cost = NSNumber(floatLiteral: price * ethValue)
        let formatter = NumberFormatter()
        if cost.uintValue > 0 {
            formatter.maximumFractionDigits = 2
            formatter.minimumFractionDigits = 2
        } else {
            formatter.minimumFractionDigits = 2
            formatter.minimumSignificantDigits = 1
            formatter.maximumSignificantDigits = 1
        }
        if let costString = formatter.string(from: cost) {
            let exactly = value.isZero || price.isZero
            let sign = exactly ? "=" : "≈"
            return " \(sign) $\(costString)"
        } else {
            return ""
        }
    }
    

    var diplayDataInterpretation: String? {
        let result = externalInterpretation?.appending("\n\n") ?? ""

        if let interpretation = interpretation {
            return result + interpretation
        } else if let nonEmptyDataWithLabel = nonEmptyDataWithLabel {
            return result + nonEmptyDataWithLabel
        } else {
            return externalInterpretation
        }
    }
    
}
