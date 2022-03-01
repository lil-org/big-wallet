// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import SwiftUI
import ComposableArchitecture

struct ChainSelectionState: Equatable {
    let mode: Mode
    var rows: IdentifiedArrayOf<ChainElementViewModel>
    var searchQuery: String = .empty
    var alert: AlertState<ChainSelectionActions>?
    
    var previousChoiceId: UUID?

    enum Mode {
        case singleSelect
        case multiSelect
    }
    
    struct ChainElementViewModel: Equatable, Identifiable {
        let id: UUID = UUID()
        let icon: String
        let title: String
        let ticker: String
        var isSelected: Bool = false
    }
    
    var filteredRows: IdentifiedArrayOf<ChainElementViewModel> {
        self.rows.filter {
            $0.title.lowercased().contains(self.searchQuery.lowercased()) ||
            $0.ticker.lowercased().contains(self.searchQuery.lowercased())
        }
    }
}

enum ChainSelectionActions: Equatable {
    case selectElement(id: UUID)
    case done
    case cancel
    case alertDismissed
    case searchQueryChanged(String)
}

struct ChainSelectionEnvironment {
    let completion: ([SupportedChainType]) -> Void
}

let chainSelectionReducer =
    Reducer<ChainSelectionState, ChainSelectionActions, ChainSelectionEnvironment> { state, action, environment in
    
    switch action {
    case .done:
        let selectedItems = state.rows.filter { $0.isSelected }
        if selectedItems.count == .zero {
            state.alert = .init(
                title: .init("You need to select at least one chain!"),
                dismissButton: .destructive(.init("Ok"))
            )
        } else {
            DispatchQueue.main.async {
                environment.completion(selectedItems.compactMap { SupportedChainType(rawValue: $0.title.lowercased()) })
            }
        }
        return .none
    case .cancel:
        DispatchQueue.main.async {
            environment.completion([])
        }
        return .none
    case .alertDismissed:
        state.alert = nil
        return .none
    case let .searchQueryChanged(newQuery):
        state.searchQuery = newQuery
        return .none
    case let .selectElement(id):
        if state.mode == .singleSelect {
            if let previousChoiceId = state.previousChoiceId {
                state.rows[id: previousChoiceId]?.isSelected.toggle()
                if previousChoiceId != id {
                    state.rows[id: id]?.isSelected.toggle()
                    state.previousChoiceId = id
                } else {
                    state.previousChoiceId = nil
                }
            } else {
                state.rows[id: id]?.isSelected.toggle()
                state.previousChoiceId = id
            }
        } else {
            state.rows[id: id]?.isSelected.toggle()
        }
        return .none
    }
}

public struct ChainSelectionView: View {
    let store: Store<ChainSelectionState, ChainSelectionActions>
    
    @Environment(\.colorScheme) var colorScheme
    
    public var body: some View {
        WithViewStore(self.store) { viewStore in
            VStack(spacing: .zero) {
                VStack {
                    HStack(alignment: .center) {
                        Button("Cancel") {
                            viewStore.send(.cancel)
                        }
                        Spacer()
                        Text("Ledgers")
                        Spacer()
                        Button("Done") {
                            viewStore.send(.done)
                        }
                    }
                    .font(.system(size: 15, weight: .medium))
                    .padding(.horizontal, 10)
                    SimpleSearchBar(
                        text: viewStore.binding(
                            get: \.searchQuery,
                            send: ChainSelectionActions.searchQueryChanged
                        )
                    )
                    .padding(.bottom, 10)
                }
                .padding(.horizontal, 10)
                .padding(.top, 15)
                .background(colorScheme == .dark ? Color(.systemGray5) : Color.white)
                
                List {
                    ForEach(viewStore.searchQuery.isEmpty ? viewStore.rows : viewStore.filteredRows) { rowViewModel in
                        HStack {
                            Image(rowViewModel.icon)
                                .resizable()
                                .frame(width: 40, height: 40, alignment: .center)
                                .foregroundColor(Color(UIColor.systemPink))
                            VStack(alignment: .center) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(rowViewModel.title)
                                        .foregroundColor(colorScheme == .dark ? Color.white : Color.black)
                                        .font(.headline)
                                    Text("(\(rowViewModel.ticker))")
                                        .foregroundColor(.gray)
                                        .font(.system(size: 17, weight: .medium))
                                }
                            }
                            Spacer()
                            if viewStore.mode == .multiSelect {
                                Image(systemName: rowViewModel.isSelected ? "checkmark.square.fill" : "square")
                                    .resizable()
                                    .frame(width: 20, height: 20, alignment: .center)
                                    .foregroundColor(colorScheme == .dark ? Color.white : Color.black)
                                    .padding(.trailing, 10)
                            } else {
                                if rowViewModel.isSelected {
                                    Image(systemName: "checkmark")
                                        .resizable()
                                        .frame(width: 20, height: 20, alignment: .center)
                                        .foregroundColor(colorScheme == .dark ? Color.white : Color.black)
                                        .padding(.trailing, 10)
                                }
                                
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewStore.send(.selectElement(id: rowViewModel.id))
                        }
                        .padding(.horizontal, -5)
                    }
                }
                .listStyle(PlainListStyle())
            }
            .edgesIgnoringSafeArea(.all)
            .alert(
                self.store.scope(state: \.alert),
                dismiss: .alertDismissed
            )
        }
        .gesture(
            DragGesture().onChanged { _ in
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                )
            }
        )
    }
}

struct ChainSelectionView_Previews: PreviewProvider {
    static var previews: some View {
        ChainSelectionView(
            store: Store(
                initialState: ChainSelectionState(
                    mode: .singleSelect,
                    rows: []
                ),
                reducer: chainSelectionReducer,
                environment: ChainSelectionEnvironment(completion: {_ in})
            )
        )
    }
}
