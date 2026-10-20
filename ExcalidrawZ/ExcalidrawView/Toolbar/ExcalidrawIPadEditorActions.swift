#if os(iOS)
import SwiftUI
import SwiftyAlert

/// Actions that share the native iPad bar with the drawing tool picker.
struct ExcalidrawIPadEditorActions<FileProtection: View>: View {
    @ObservedObject var core: ExcalidrawCore
    @Environment(\.alertToast) private var alertToast
    @EnvironmentObject private var appPreference: AppPreference
    @EnvironmentObject private var fileState: FileState
    @EnvironmentObject private var toolState: ToolState
    @EnvironmentObject private var layoutState: LayoutState
    @ObservedObject private var aiChatPreferences = AIChatPreferences.shared
    @ViewBuilder var fileProtection: () -> FileProtection

    var body: some View {
        undoMenu
        Button {
            toolState.toggleActionsMenu()
        } label: {
            Label("Style", systemImage: "paintbrush.pointed")
        }
        .accessibilityIdentifier("toolbar.style")
        .accessibilityAddTraits(toolState.isActionsMenuPresneted ? .isSelected : [])

        ShareToolbarButton()
            .accessibilityIdentifier("toolbar.share")

        ExcalidrawToolbarToolContainer { sizeClass in
            let presentation = ExcalidrawToolbarToolPresentation(order: appPreference.toolbarToolOrder)
            let items = presentation.pickerItems(for: sizeClass)
            ExcalidrawToolbarMoreToolsMenu(
                overflowItems: sizeClass == .dense ? presentation.items : items.secondary,
                usesPrincipalLabel: true,
                usesStableLabel: true
            ) {
                Section {
                    penModeToggle
                    Toggle(isOn: Binding(
                        get: { toolState.isToolLocked },
                        set: { enabled in
                            if enabled != toolState.isToolLocked { toolState.toggleToolLock() }
                        }
                    )) {
                        Label(.localizable(.toolbarButtonLockToolHelp), systemImage: "repeat")
                    }
                    .accessibilityIdentifier("toolbar.toolLock")
                }
                Section {
                    zoomMenu
                    inspectorMenu
                }
                fileProtection()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
        }
        .labelStyle(.iconOnly)
    }

    private var penModeToggle: some View {
        Toggle(isOn: Binding(
            get: { toolState.inPenMode },
            set: { enabled in
                if case .file(let file) = fileState.currentActiveFile, file.inTrash {
                    layoutState.isResotreAlertIsPresented = true
                    return
                }
                run {
                    try await toolState.togglePenMode(enabled: enabled, pencilConnected: enabled)
                    if enabled { try await toolState.toggleTool(.freedraw) }
                }
            }
        )) {
            Label("Pen mode", systemImage: "pencil.tip.crop.circle")
        }
        .accessibilityIdentifier("toolbar.penMode")
    }

    private var undoMenu: some View {
        SwiftUI.Group {
            if core.canUndo {
                Menu {
                    undoActions
                } label: {
                    Label(.localizable(.generalButtonUndo), systemImage: "arrow.uturn.backward")
                } primaryAction: {
                    run { try await core.performUndo() }
                }
            } else {
                Menu {
                    undoActions
                } label: {
                    Label(.localizable(.generalButtonUndo), systemImage: "arrow.uturn.backward")
                }
            }
        }
        .disabled(!core.canUndo && !core.canRedo)
        .accessibilityIdentifier("toolbar.undo")
    }

    @ViewBuilder
    private var undoActions: some View {
        Button {
            run { try await core.performUndo() }
        } label: {
            Label(.localizable(.generalButtonUndo), systemImage: "arrow.uturn.backward")
        }
        .disabled(!core.canUndo)
        .accessibilityIdentifier("toolbar.undoAction")
        Button {
            run { try await core.performRedo() }
        } label: {
            Label(.localizable(.generalButtonRedo), systemImage: "arrow.uturn.forward")
        }
        .disabled(!core.canRedo)
        .accessibilityIdentifier("toolbar.redoAction")
    }

    private var zoomMenu: some View {
        Menu {
            Button {
                run { try await core.zoomToFit() }
            } label: {
                Label("Fit drawing", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityIdentifier("toolbar.zoomToFit")
            ForEach([0.5, 1, 2], id: \.self) { scale in
                Button {
                    run { try await core.zoomTo(scale) }
                } label: {
                    Text(scale, format: .percent.precision(.fractionLength(0)))
                }
                .accessibilityIdentifier("toolbar.zoom.\(Int(scale * 100))")
            }
        } label: {
            Label {
                Text(core.cameraState.zoom, format: .percent.precision(.fractionLength(0)))
            } icon: {
                Image(systemName: "magnifyingglass")
            }
        }
        .accessibilityLabel("Zoom")
        .accessibilityValue(Text(core.cameraState.zoom, format: .percent.precision(.fractionLength(0))))
        .accessibilityIdentifier("toolbar.zoom")
    }

    private var inspectorMenu: some View {
        Menu {
            inspectorAction(.preference, title: String(localizable: .canvasPreferencesTitle), icon: "slider.horizontal.3")
            inspectorAction(.search, title: String(localizable: .searchButtonTitle), icon: "magnifyingglass")
                .keyboardShortcut("f", modifiers: .command)
            inspectorAction(.library, title: String(localizable: .librariesTitle), icon: "book")
            inspectorAction(.history, title: String(localizable: .checkpoints), icon: "clock.arrow.circlepath")
            inspectorAction(.presentation, title: String(localizable: .presentationTitle), icon: "play")
            if aiChatPreferences.isAIEnabled && AIChatAvailability.isAvailable {
                inspectorAction(.aiChat, title: "AI Chat", icon: "sparkles")
            }
        } label: {
            Label("Inspector", systemImage: "sidebar.right")
        }
        .accessibilityIdentifier("toolbar.inspector")
    }

    private func inspectorAction(_ tab: LayoutState.InspectorTab, title: String, icon: String) -> some View {
        Toggle(isOn: Binding(
            get: {
                if tab == .aiChat && layoutState.isAIChatIslandMode { return true }
                return layoutState.isInspectorPresented && layoutState.activeInspectorTab == tab
            },
            set: { _ in
                if tab == .aiChat && layoutState.isAIChatIslandMode {
                    layoutState.isAIChatIslandMode = false
                } else {
                    layoutState.toggleInspector(tab)
                }
            }
        )) {
            Label(title, systemImage: icon)
        }
        .accessibilityIdentifier("toolbar.inspector.\(tab)")
        .disabled(fileState.activeCollaborationFileIsLoading)
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await action() } catch { alertToast(error) }
        }
    }
}
#endif
