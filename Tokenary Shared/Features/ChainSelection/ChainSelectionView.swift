// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import SwiftUI

struct ChainSelectionState: Equatable {
    enum Mode {
        case singleSelect
        case multiSelect
    }
    
    struct ChainElementViewModel: Equatable, Identifiable {
        let id: UInt32
        let icon: String
        let title: String
        let ticker: String
        var isSelected: Bool = false
    }
    
    let mode: Mode
    var rows: [ChainElementViewModel]
    
    var previousChoiceId: UInt32?
}

class ChainSelectionStateProvider: ObservableObject {
    @Published
    var state: ChainSelectionState
    
    @Published
    var isDoneButtonEnabled: Bool = false
    
    let completion: ([ChainType]) -> Void
    
    init(state: ChainSelectionState, completion: @escaping ([ChainType]) -> Void) {
        self.state = state
        self.completion = completion
        self.updateDoneButtonState()
    }
    
    func doneButtonWasPressed() {
        let selectedItems = self.state.rows.filter { $0.isSelected }
        DispatchQueue.main.async {
            self.completion(selectedItems.compactMap { ChainType(rawValue: $0.id) })
        }
    }
    
    func cancelButtonWasPressed() {
        DispatchQueue.main.async {
            self.completion([])
        }
    }
    
    func elementWasSelected(with id: UInt32) {
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

struct ChainSelectionView: View {
    @ObservedObject
    var stateProvider: ChainSelectionStateProvider
    
    var body: some View {
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
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 15)
            .background(Color(light: .systemGray5, dark: .systemGray5))
            
            List {
                ForEach(self.stateProvider.state.rows) { rowViewModel in
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
//                        #if canImport(AppKit)
//                        Divider()
//                        #endif
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        self.stateProvider.elementWasSelected(with: rowViewModel.id)
                    }
                    .listRowSeparator(.visible)
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
