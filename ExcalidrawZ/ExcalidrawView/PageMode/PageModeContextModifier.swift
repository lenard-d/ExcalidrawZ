import Combine
import Logging
import SwiftUI

@MainActor
struct PageModeContextModifier: ViewModifier {
    @ObservedObject var core: ExcalidrawCore
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if isEnabled {
                PageModeContextHost(core: core)
            }
        }
    }
}

@MainActor
private struct PageModeContextHost: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.excalidrawNativeViewportInsets) private var nativeViewportInsets
    @EnvironmentObject private var toolState: ToolState
    @EnvironmentObject private var fileState: FileState
    @EnvironmentObject private var lockedContentState: LockedContentStateStore
    @ObservedObject var core: ExcalidrawCore
    @State private var controller: PageModeController?
    @State private var refreshTask: Task<Void, Never>?
    @State private var owner: CanvasMutationSession?

    var body: some View {
        // Read context state in this body, before the deferred layout closure.
        let contextController = controller
        let canShowContext = available
#if DEBUG
        let _ = core.logger.debug("[PageModeContext] body controller=\(contextController != nil) available=\(canShowContext)")
#endif
        return GeometryReader { geometry in
#if DEBUG
            let _ = core.logger.debug("[PageModeContext] geometry size=\(geometry.size) insets=\(nativeViewportInsets)")
#endif
            if let controller = contextController, canShowContext {
                PageModeContextActions(controller: controller, selectedIDs: core.selectedElementIDs,
                    scroll: CGPoint(x: core.cameraState.scrollX, y: core.cameraState.scrollY),
                    zoom: core.cameraState.zoom,
                    viewport: CGRect(x: nativeViewportInsets.left, y: nativeViewportInsets.top,
                        width: geometry.size.width - nativeViewportInsets.left - nativeViewportInsets.right,
                        height: geometry.size.height - nativeViewportInsets.top - nativeViewportInsets.bottom),
                    refresh: refresh)
            }
        }
        .task { refresh() }
        .onChange(of: core.selectedElementIDs) { _ in refresh() }
        .onChange(of: core.contentChangeToken) { _ in refresh() }
        .onChange(of: core.isLoading) { _ in resetAndRefresh() }
        .onChange(of: fileState.currentActiveFile?.id) { _ in resetAndRefresh() }
        .onChange(of: lockedContentState.activeFileLockState) { _ in resetAndRefresh() }
        .onReceive(toolState.$excalidrawWebCoordinator) { incoming in
            if incoming !== core { clear() }
        }
        .onReceive(core.documentSyncController.canvasMutationSessionChanges.receive(on: RunLoop.main)) { _ in
            resetAndRefresh()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { refresh() } else { clear() }
        }
        .onDisappear { clear() }
    }

    private var available: Bool {
        scenePhase == .active && !core.isLoading && toolState.excalidrawWebCoordinator === core &&
        lockedContentState.activeFileLockState != .locked && core.selectedElementIDs.count == 1 &&
        (owner.map { core.documentSyncController.isCurrentCanvasMutationSession($0) } ?? true)
    }

    private func clear() {
        refreshTask?.cancel()
        refreshTask = nil
        controller?.invalidate()
        controller = nil
        owner = nil
    }

    private func resetAndRefresh() {
        clear()
        refresh()
    }

    /// Coalesces reads through cancellation. A running page action keeps its busy controller.
    private func refresh() {
        refreshTask?.cancel()
        guard available else { clear(); return }
        guard controller?.isBusy != true else { return }
        let selectedIDs = core.selectedElementIDs
        refreshTask = Task { @MainActor in
            do {
                let next = try PageModeCanvasBridge(core: core, toolState: toolState,
                    fileState: fileState, lockedContentState: lockedContentState).makeController()
                let nextOwner = core.documentSyncController.captureCanvasMutationSession()
                let didRead = await next.perform(.init(action: .list))
#if DEBUG
                core.logger.debug("[PageModeContext] admission read=\(didRead) cancelled=\(Task.isCancelled) available=\(available) selectionMatches=\(core.selectedElementIDs == selectedIDs) capturedOwner=\(nextOwner != nil) ownerCurrent=\(nextOwner.map { core.documentSyncController.isCurrentCanvasMutationSession($0) } ?? false) previousBusy=\(controller?.isBusy == true) nextValid=\(next.isValid) selectedPage=\(next.pages.contains { selectedIDs.contains($0.id) })")
#endif
                guard didRead, !Task.isCancelled,
                      available, core.selectedElementIDs == selectedIDs,
                      let nextOwner, core.documentSyncController.isCurrentCanvasMutationSession(nextOwner),
                      controller?.isBusy != true else { next.invalidate(); return }
                controller?.invalidate()
                controller = next
                owner = nextOwner
#if DEBUG
                core.logger.debug("[PageModeContext] published controller=\(controller != nil)")
#endif
            } catch {
                // A context read has no user action to fail. An unavailable owner hides it.
                if !Task.isCancelled { clear() }
            }
        }
    }
}

@MainActor
private struct PageModeContextActions: View {
    @ObservedObject var controller: PageModeController
    let selectedIDs: [String]
    let scroll: CGPoint
    let zoom: Double
    let viewport: CGRect
    let refresh: () -> Void
    @State private var controlsHeight: CGFloat = 52

    var body: some View {
#if DEBUG
        let _ = Logger(label: "PageModeContext").debug("[PageModeContext] actions valid=\(controller.isValid) pages=\(controller.pages.count) selected=\(selectedIDs.count) viewport=\(viewport)")
#endif
        if controller.isValid, selectedIDs.count == 1,
           let page = controller.pages.first(where: { $0.id == selectedIDs[0] }), !page.locked {
            let size = CGSize(width: min(280, viewport.width - 16), height: controlsHeight)
            let origin = PageModeContextPlacement.origin(page: page, scroll: scroll,
                zoom: zoom, viewport: viewport, controls: size)
#if DEBUG
            let _ = Logger(label: "PageModeContext").debug("[PageModeContext] placement page=\(page.x ?? 0),\(page.y ?? 0),\(page.width),\(page.height) scroll=\(scroll) zoom=\(zoom) controls=\(size) origin=\(String(describing: origin))")
#endif
            if let origin {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 8) {
                        Menu {
                            ForEach(PageModeLayout.allCases) { layout in
                                Button(layout.title) {
                                    Task {
                                        if await controller.perform(.init(action: .setLayout, pageID: page.id, layout: layout)) { refresh() }
                                    }
                                }
                            }
                        } label: {
                            Label((page.layout ?? .blank).title, systemImage: "line.3.horizontal")
                                .frame(minHeight: 44)
                        }
                        .accessibilityLabel(String(localized: "Page layout"))
                        .accessibilityValue((page.layout ?? .blank).title)
                        .accessibilityIdentifier("pages.context.layout")
                        Menu {
                            ForEach(PageModePlacement.allCases) { placement in
                                Button(placement.title) {
                                    Task {
                                        if await controller.createPage(after: page, placement: placement) { refresh() }
                                    }
                                }
                            }
                        } label: {
                            Label(String(localized: "New page"), systemImage: "plus")
                                .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("pages.context.add")
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.isBusy)
                    if let error = controller.errorMessage {
                        Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: size.width, alignment: .trailing)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: PageModeContextHeight.self, value: geometry.size.height)
                })
                .onPreferenceChange(PageModeContextHeight.self) { controlsHeight = $0 }
                .offset(x: origin.x, y: origin.y)
            }
        }
    }
}

private struct PageModeContextHeight: PreferenceKey {
    static let defaultValue: CGFloat = 52
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
