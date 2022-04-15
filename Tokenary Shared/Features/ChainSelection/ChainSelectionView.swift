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
        updateDoneButtonState()
    }
    
    func doneButtonWasPressed() {
        let selectedItems = state.rows.filter { $0.isSelected }
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
        guard let rowIdx = state.rows.firstIndex(where: { $0.id == id }) else { return }
        if state.mode == .singleSelect {
            if let previousChoiceId = state.previousChoiceId {
                guard
                    let previousRowIdx = state.rows.firstIndex(where: { $0.id == previousChoiceId })
                else { return }
                state.rows[previousRowIdx].isSelected.toggle()
                if previousChoiceId != id {
                    state.rows[rowIdx].isSelected.toggle()
                    state.previousChoiceId = id
                } else {
                    state.previousChoiceId = nil
                }
            } else {
                state.rows[rowIdx].isSelected.toggle()
                state.previousChoiceId = id
            }
        } else {
            state.rows[rowIdx].isSelected.toggle()
        }
        updateDoneButtonState()
    }
    
    private func updateDoneButtonState() {
        if state.rows.contains(where: { $0.isSelected }) {
            isDoneButtonEnabled = true
        } else {
            isDoneButtonEnabled = false
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
                        stateProvider.cancelButtonWasPressed()
                    }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Text("Ledgers")
                    Spacer()
                    Button("Done") {
                        stateProvider.doneButtonWasPressed()
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
                ForEach(stateProvider.state.rows.indexed(), id: \.1.id) { index, rowViewModel in
                    HStack {
                        Image(rowViewModel.icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 40, height: 40, alignment: .center)
                            .clipShape(Circle())
                        VStack(alignment: .center) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(rowViewModel.title)
                                    .foregroundColor(Color.mainText)
                                    .font(.headline)
                                Text("(\(rowViewModel.ticker))")
                                    .foregroundColor(.gray)
                                    .font(.system(size: 17, weight: .medium))
                            }
                        }
                        Spacer()
                        Toggle(".empty", isOn: self.$stateProvider.state.rows[index].isSelected)
                            .frame(width: 20, height: 20, alignment: .center)
                            .foregroundColor(Color.mainText)
                            .padding(.trailing, 10)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        stateProvider.elementWasSelected(with: rowViewModel.id)
                    }
                    #if canImport(UIKit)
                    .listRowSeparator(.visible)
                    #endif // ToDo: Change when https://forums.swift.org/t/if-for-postfix-member-expressions/44159
                    #if canImport(AppKit)
                    Divider()
                    #endif
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
