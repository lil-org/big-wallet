// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import UIKit
import ComposableArchitecture
import SwiftUI

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
        case let .multiReSelect(currentlySelected, _): return currentlySelected
        default: return []
        }
    }
}

public final class ChainSelectionAssembly {
    public static func build(
        for mode: ChainSelectionMode,
        completion: @escaping ([SupportedChainType]) -> Void
    ) -> UIViewController {
        let contentView = ChainSelectionView(
            store: Store(
                initialState: self.buildInitialState(for: mode),
                reducer: chainSelectionReducer,
                environment: ChainSelectionEnvironment(completion: completion)
            )
        )
        return WrappingViewController(rootView: contentView)
    }
    
    private static func buildInitialState(for mode: ChainSelectionMode) -> ChainSelectionState {
        let currentlySelected = mode.currentlySelected
        let viewModels = mode.supportedCoinTypes.map { coinType in
            ChainSelectionState.ChainElementViewModel(
                icon: coinType.iconName,
                title: coinType.title,
                ticker: coinType.ticker,
                isSelected: currentlySelected.contains(coinType)
            )
        }
        return ChainSelectionState(
            mode: mode.stateMode,
            rows: .init(uniqueElements: viewModels)
        )
    }
}
