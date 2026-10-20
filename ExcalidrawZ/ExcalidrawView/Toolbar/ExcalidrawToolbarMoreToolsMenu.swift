//
//  ExcalidrawToolbarMoreToolsMenu.swift
//  ExcalidrawZ
//
//  Created by Codex on 2026/06/07.
//

import SwiftUI

import SFSafeSymbols

struct ExcalidrawToolbarMoreToolsMenu: View {
    @EnvironmentObject private var toolState: ToolState

    var overflowItems: [ExcalidrawToolbarToolPresentation.Item] = []
    var usesPrincipalLabel = false

    @State private var isMathInputSheetPresented = false
    @State private var isMermaidInputSheetPresented = false
    @State private var isPDFPickerPresented = false
    @State private var isPageModeSheetPresented = false

    var body: some View {
        Menu {
            if !overflowItems.isEmpty {
                Section {
                    Picker(selection: $toolState.activatedTool) {
                        ForEach(overflowItems) { item in
                            Label {
                                Text(item.menuTitle(localizedName: item.tool.localization))
                            } icon: {
                                Image(systemSymbol: item.tool.menuSystemSymbol)
                            }
                            .tag(item.tool)
                        }
                    } label: {
                        Text(.localizable(.toolbarActiveToolTitle))
                    }
                    .pickerStyle(.inline)
                }
                Divider()
            }
#if DEBUG
#if !os(iOS)
            Button {
                Task {
                    try? await toolState.excalidrawWebCoordinator?.toggleToolbarAction(tool: .text2Diagram)
                }
            } label: {
                Text(.localizable(.toolbarText2Diagram))
            }
#endif
#endif
            Button {
                isMermaidInputSheetPresented.toggle()
            } label: {
                Text(.localizable(.toolbarMermaid))
            }

            Button {
                isMathInputSheetPresented.toggle()
            } label: {
                Text(.localizable(.toolbarLatexMath))
            }

            Button {
                isPDFPickerPresented.toggle()
            } label: {
                Text(localizable: .toolbarInsertPDF)
            }

            Button(String(localized: "Pages")) {
                isPageModeSheetPresented = true
            }
        } label: {
            if usesPrincipalLabel {
                menuLabel.labelStyle(.iconOnly).frame(width: 32, height: 32)
            } else {
                menuLabel
            }
        }
        .accessibilityIdentifier("toolbar.moreTools")
        .menuIndicator(.hidden)
#if os(iOS)
        .menuOrder(.fixed)
#endif
        .modifier(MermaidInputSheetViewModifier(isPresented: $isMermaidInputSheetPresented))
        .modifier(MathInputSheetViewModifier(isPresented: $isMathInputSheetPresented))
        .modifier(PDFInsertSheetViewModifier(isPresented: $isPDFPickerPresented))
        .modifier(PageModeSheetModifier(isPresented: $isPageModeSheetPresented))
    }

    @ViewBuilder
    private var menuLabel: some View {
        if #available(macOS 15.0, iOS 18.0, *) {
            Label(.localizable(.toolbarMoreTools), systemImage: "xmark.triangle.circle.square")
        } else if #available(macOS 13.0, iOS 16.0, *) {
            Label(.localizable(.toolbarMoreTools), systemSymbol: .chartXyaxisLine)
        } else {
            Label(.localizable(.toolbarMoreTools), systemSymbol: .chartXyaxisLine)
        }
    }
}
