// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import SwiftUI

struct ChainSelectionState: Equatable {
    let mode: Mode
    var rows: [ChainElementViewModel]
    var searchQuery: String = .empty
    
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
    
    var filteredRows: [ChainElementViewModel] {
        self.rows.filter {
            $0.title.lowercased().contains(self.searchQuery.lowercased()) ||
            $0.ticker.lowercased().contains(self.searchQuery.lowercased())
        }
    }
}

class ChainSelectionStateProvider: ObservableObject {
    @Published
    var state: ChainSelectionState
    
    @Published
    var isDoneButtonEnabled: Bool = false
    
    let completion: ([SupportedChainType]) -> Void
    
    init(state: ChainSelectionState, completion: @escaping ([SupportedChainType]) -> Void) {
        self.state = state
        self.completion = completion
        self.updateDoneButtonState()
    }
    
    public func doneButtonWasPressed() {
        let selectedItems = self.state.rows.filter { $0.isSelected }
        DispatchQueue.main.async {
            self.completion(selectedItems.compactMap { SupportedChainType(rawValue: $0.title.lowercased()) })
        }
    }
    
    public func cancelButtonWasPressed() {
        DispatchQueue.main.async {
            self.completion([])
        }
    }
    
    public func elementWasSelected(with id: UUID) {
        guard let rowIdx = self.state.rows.firstIndex(where: { $0.id == id }) else { return }
        if self.state.mode == .singleSelect {
            if let previousChoiceId = self.state.previousChoiceId {
                guard
                    let previousRowIdx = self.state.rows.firstIndex(where: { $0.id == previousChoiceId })
                else { return }
                self.state.rows[previousRowIdx].isSelected.toggle()
                if previousChoiceId != id {
                    self.state.rows[rowIdx].isSelected.toggle()
                    self.state.previousChoiceId = id
                } else {
                    self.state.previousChoiceId = nil
                }
            } else {
                self.state.rows[rowIdx].isSelected.toggle()
                self.state.previousChoiceId = id
            }
        } else {
            self.state.rows[rowIdx].isSelected.toggle()
        }
        self.updateDoneButtonState()
    }
    
    private func updateDoneButtonState() {
        if self.state.rows.contains(where: { $0.isSelected }) {
            self.isDoneButtonEnabled = true
        } else {
            self.isDoneButtonEnabled = false
        }
    }
}

public struct ChainSelectionView: View {
    @ObservedObject
    var stateProvider: ChainSelectionStateProvider
    
    @State
    var searchQuery: String = .empty
    
    public var body: some View {
        VStack(spacing: .zero) {
            VStack {
                HStack(alignment: .center) {
                    Button("Cancel") {
                        self.stateProvider.cancelButtonWasPressed()
                    }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Text("Ledgers")
                    Spacer()
                    Button("Done") {
                        self.stateProvider.doneButtonWasPressed()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!stateProvider.isDoneButtonEnabled)
                }
                .font(.system(size: 15, weight: .medium))
                .padding(.horizontal, 10)
                SimpleSearchBar(text: $searchQuery)
                    .padding(.bottom, 10)
                    .onChange(of: self.searchQuery) { newValue in
                        self.stateProvider.state.searchQuery = newValue
                    }
            }
            .padding(.horizontal, 10)
            .padding(.top, 15)
            .background(Color(light: .systemGray5, dark: .systemGray5))
            List {
                let rows = self.searchQuery.isEmpty
                    ? self.stateProvider.state.rows
                    : self.stateProvider.state.filteredRows
                ForEach(rows) { rowViewModel in
                    HStack {
                        Image(rowViewModel.icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 40, height: 40, alignment: .center)
                            .clipShape(Circle())
                        VStack(alignment: .center) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(rowViewModel.title)
                                    .foregroundColor(Color(light: .black, dark: .white))
                                    .font(.headline)
                                Text("(\(rowViewModel.ticker))")
                                    .foregroundColor(.gray)
                                    .font(.system(size: 17, weight: .medium))
                            }
                        }
                        Spacer()
                        if self.stateProvider.state.mode == .multiSelect {
                            Image(systemName: rowViewModel.isSelected ? "checkmark.square.fill" : "square")
                                .resizable()
                                .frame(width: 20, height: 20, alignment: .center)
                                .foregroundColor(Color(light: .black, dark: .white))
                                .padding(.trailing, 10)
                        } else {
                            if rowViewModel.isSelected {
                                Image(systemName: "checkmark")
                                    .resizable()
                                    .frame(width: 20, height: 20, alignment: .center)
                                    .foregroundColor(Color(light: .black, dark: .white))
                                    .padding(.trailing, 10)
                            }
                            
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        self.stateProvider.elementWasSelected(with: rowViewModel.id)
                    }
                }
            }
            .listStyle(PlainListStyle())
        }
        .edgesIgnoringSafeArea(.all)
        .gesture(
            DragGesture().onChanged { _ in
                ApplicationHelper.resignFirstResponder()
            }
        )
    }
}
