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
        GeometryReader { geometry in
            if let controller, available {
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
#if DEBUG
        trace("refresh")
#endif
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
                trace("list success=\(didRead) pages=\(next.pages.count) selectedPage=\(next.pages.contains { selectedIDs.contains($0.id) }) cancelled=\(Task.isCancelled)")
#endif
                guard didRead, !Task.isCancelled,
                      available, core.selectedElementIDs == selectedIDs,
                      let nextOwner, core.documentSyncController.isCurrentCanvasMutationSession(nextOwner),
                      controller?.isBusy != true else { next.invalidate(); return }
                controller?.invalidate()
                controller = next
                owner = nextOwner
            } catch {
#if DEBUG
                trace("read error=\(error.localizedDescription)")
#endif
                // A context read has no user action to fail. An unavailable owner hides it.
                if !Task.isCancelled { clear() }
            }
        }
    }

#if DEBUG
    private func trace(_ stage: String) {
        core.logger.debug("[PageModeContext] \(stage) active=\(scenePhase == .active) loading=\(core.isLoading) activeCore=\(toolState.excalidrawWebCoordinator === core) locked=\(lockedContentState.activeFileLockState == .locked) selected=\(core.selectedElementIDs.count) ownerCurrent=\(owner.map { core.documentSyncController.isCurrentCanvasMutationSession($0) } ?? true) camera=\(core.cameraState.scrollX),\(core.cameraState.scrollY),\(core.cameraState.zoom)")
    }
#endif
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
        let _ = Logger(label: "PageModeContext").debug("actions valid=\(controller.isValid) selected=\(selectedIDs.count) pages=\(controller.pages.count) viewport=\(viewport) controlsHeight=\(controlsHeight)")
#endif
        if controller.isValid, selectedIDs.count == 1,
           let page = controller.pages.first(where: { $0.id == selectedIDs[0] }), !page.locked {
            let size = CGSize(width: min(280, viewport.width - 16), height: controlsHeight)
            let origin = PageModeContextPlacement.origin(page: page, scroll: scroll,
                zoom: zoom, viewport: viewport, controls: size)
#if DEBUG
            let _ = Logger(label: "PageModeContext").debug("placement visible=\(origin != nil) page=\(page.x ?? .nan),\(page.y ?? .nan),\(page.width),\(page.height) scroll=\(scroll) zoom=\(zoom) viewport=\(viewport) controls=\(size)")
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
