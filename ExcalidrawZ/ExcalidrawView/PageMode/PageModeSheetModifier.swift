import SwiftUI

@MainActor
struct PageModeSheetModifier: ViewModifier {
    @EnvironmentObject private var toolState: ToolState
    @EnvironmentObject private var fileState: FileState
    @EnvironmentObject private var lockedContentState: LockedContentStateStore
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            if let core = toolState.excalidrawWebCoordinator {
                PageModeSheetHost(core: core, toolState: toolState, fileState: fileState, lockedContentState: lockedContentState)
            } else {
                PageModeUnavailableSheet(message: PageModeError.unavailable.localizedDescription)
            }
        }
    }
}

@MainActor
private struct PageModeSheetHost: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var core: ExcalidrawCore
    @ObservedObject var toolState: ToolState
    @ObservedObject var fileState: FileState
    @ObservedObject var lockedContentState: LockedContentStateStore
    @State private var controller: PageModeController?
    @State private var errorMessage: String?

    var body: some View {
        SwiftUI.Group {
            if let controller {
                PageModeSheet(controller: controller)
            } else {
                PageModeUnavailableSheet(message: errorMessage ?? PageModeError.unavailable.localizedDescription)
            }
        }
        .task {
            guard controller == nil, errorMessage == nil else { return }
            do {
                controller = try PageModeCanvasBridge(core: core, toolState: toolState, fileState: fileState, lockedContentState: lockedContentState).makeController()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .onChange(of: fileState.currentActiveFile?.id) { _ in controller?.invalidate() }
        .onReceive(lockedContentState.$activeFileLockState) { state in
            if state == .locked { controller?.invalidate() }
        }
        .onReceive(core.$isLoading) { loading in
            if loading { controller?.invalidate() }
        }
        .onReceive(core.$contentChangeToken) { _ in controller?.invalidateIfNeeded() }
        .onChange(of: scenePhase) { phase in
            if phase == .background { controller?.invalidate() }
        }
    }
}

private struct PageModeUnavailableSheet: View {
    @Environment(\.dismiss) private var dismiss
    let message: String

    var body: some View {
        NavigationStack {
            Text(message)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(String(localized: "Pages"))
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done")) { dismiss() }
                    }
                }
        }
        .frame(minWidth: 280, idealWidth: 480, idealHeight: 600)
    }
}
