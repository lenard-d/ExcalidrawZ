//
//  ExcalidrawToolbarMoreToolsMenu.swift
//  ExcalidrawZ
//
//  Created by Codex on 2026/06/07.
//

import SwiftUI

import SFSafeSymbols

struct ExcalidrawToolbarMoreToolsMenu<AdditionalActions: View>: View {
    @EnvironmentObject private var toolState: ToolState

    var overflowItems: [ExcalidrawToolbarToolPresentation.Item] = []
    var usesPrincipalLabel = false
    var usesStableLabel = false
    var accessibilityIdentifier = "toolbar.moreTools"
    @ViewBuilder var additionalActions: () -> AdditionalActions

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
            Section {
                Button {
                    isMermaidInputSheetPresented.toggle()
                } label: {
                    Label(.localizable(.toolbarMermaid), systemImage: "point.3.connected.trianglepath.dotted")
                }
                .accessibilityIdentifier("toolbar.insertMermaid")

                Button {
                    isMathInputSheetPresented.toggle()
                } label: {
                    Label(.localizable(.toolbarLatexMath), systemImage: "function")
                }
                .accessibilityIdentifier("toolbar.insertMath")

                Button {
                    isPDFPickerPresented.toggle()
                } label: {
                    Label(.localizable(.toolbarInsertPDF), systemImage: "doc.richtext")
                }
                .accessibilityIdentifier("toolbar.insertPDF")

                Button {
                    isPageModeSheetPresented = true
                } label: {
                    Label(String(localized: "Pages"), systemImage: "rectangle.stack")
                }
                .accessibilityIdentifier("toolbar.pages")
            } header: {
                Text("Insert")
            }

            additionalActions()
        } label: {
            if usesPrincipalLabel {
                menuLabel.labelStyle(.iconOnly).frame(width: 44, height: 44).contentShape(Circle())
            } else {
                menuLabel
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityValue(activeOverflowItem.map { $0.menuTitle(localizedName: $0.tool.localization) } ?? "")
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
        if usesStableLabel {
            Label(.localizable(.toolbarMoreTools), systemImage: "ellipsis.circle")
        } else if let item = activeOverflowItem {
            Label {
                Text(.localizable(.toolbarMoreTools))
            } icon: {
                item.tool.icon().frame(width: 20, height: 20)
            }
            .foregroundStyle(Color.accentColor)
        } else if #available(macOS 15.0, iOS 18.0, *) {
            Label(.localizable(.toolbarMoreTools), systemImage: "xmark.triangle.circle.square")
        } else if #available(macOS 13.0, iOS 16.0, *) {
            Label(.localizable(.toolbarMoreTools), systemSymbol: .chartXyaxisLine)
        } else {
            Label(.localizable(.toolbarMoreTools), systemSymbol: .chartXyaxisLine)
        }
    }

    private var activeOverflowItem: ExcalidrawToolbarToolPresentation.Item? {
        guard usesPrincipalLabel else { return nil }
        return overflowItems.first { $0.tool == toolState.activatedTool }
    }
}

extension ExcalidrawToolbarMoreToolsMenu where AdditionalActions == EmptyView {
    init(
        overflowItems: [ExcalidrawToolbarToolPresentation.Item] = [],
        usesPrincipalLabel: Bool = false,
        usesStableLabel: Bool = false,
        accessibilityIdentifier: String = "toolbar.moreTools"
    ) {
        self.overflowItems = overflowItems
        self.usesPrincipalLabel = usesPrincipalLabel
        self.usesStableLabel = usesStableLabel
        self.accessibilityIdentifier = accessibilityIdentifier
        self.additionalActions = { EmptyView() }
    }
}
