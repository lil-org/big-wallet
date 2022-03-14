// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import SwiftUI

#if canImport(UIKit)
    import UIKit
    public typealias BridgedViewController = UIViewController
#elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
    import AppKit
    public typealias BridgedViewController = NSViewController
#endif

public enum ChainSelectionMode: Equatable {
    case singleSelect([SupportedChainType])
    case multiSelect([SupportedChainType])
    case multiReSelect(currentlySelected: [SupportedChainType], possibleElements: [SupportedChainType])
    
    fileprivate var stateMode: ChainSelectionState.Mode {
        switch self {
        case .singleSelect:
            return .singleSelect
        case .multiSelect:
            return .multiSelect
        case .multiReSelect:
            return .multiSelect
        }
    }
    
    fileprivate var supportedCoinTypes: [SupportedChainType] {
        switch self {
        case let .singleSelect(supportedChainTypes),
            let .multiSelect(supportedChainTypes),
            let .multiReSelect(_, possibleElements: supportedChainTypes):
            return supportedChainTypes
        }
    }
    
    fileprivate var currentlySelected: [SupportedChainType] {
        switch self {
        case let .multiReSelect(currentlySelected, _):
            return currentlySelected
        case let .singleSelect(supportedChainTypes),
            let .multiSelect(supportedChainTypes):
            return supportedChainTypes.contains(.ethereum) ? [.ethereum] : []
        }
    }
}

public final class ChainSelectionAssembly {
    public static func build(
        for mode: ChainSelectionMode,
        completion: @escaping ([SupportedChainType]) -> Void
    ) -> BridgedViewController {
        let stateProvider = ChainSelectionStateProvider(
            state: self.buildInitialState(for: mode),
            completion: completion
        )
        
        let contentView = ChainSelectionView(
            stateProvider: stateProvider
        )
        return WrappingViewController(rootView: contentView)
    }
    
    private static func buildInitialState(for mode: ChainSelectionMode) -> ChainSelectionState {
        let currentlySelected = mode.currentlySelected
        var previousChoiceId: UUID?
        let viewModels = mode.supportedCoinTypes.map { coinType -> ChainSelectionState.ChainElementViewModel in
            let isSelected = currentlySelected.contains(coinType)
            let newVM = ChainSelectionState.ChainElementViewModel(
                icon: coinType.iconName,
                title: coinType.title,
                ticker: coinType.ticker,
                isSelected: isSelected
            )
            if case .singleSelect(_) = mode, isSelected {
                previousChoiceId = newVM.id
            }
            return newVM
        }
        return ChainSelectionState(
            mode: mode.stateMode,
            rows: viewModels,
            previousChoiceId: previousChoiceId
        )
    }
}
