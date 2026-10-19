import Foundation

/// Keeps the requesting window alive until its own final save succeeds.
@MainActor
final class ExternalSaveWindowCloseDecision {
    private var task: Task<Void, Never>?
    private var requestID = UUID()

    @discardableResult
    func requestClose(
        participant: any ExternalSaveTerminationParticipant,
        originalShouldClose: @escaping () -> Bool,
        close: @escaping () -> Void
    ) -> Task<Void, Never> {
        if let task { return task }
        let owner = participant.terminationSaveToken
        let id = UUID()
        requestID = id
        let request = Task { @MainActor [weak self] in
            defer { if self?.requestID == id { self?.task = nil } }
            guard await participant.flushPendingCanvasSnapshotBeforeTermination(),
                  !Task.isCancelled, self?.requestID == id,
                  participant.terminationSaveToken == owner,
                  !participant.hasPendingExternalSnapshot,
                  originalShouldClose(),
                  participant.terminationSaveToken == owner,
                  !participant.hasPendingExternalSnapshot else { return }
            close()
        }
        task = request
        return request
    }

    func cancel() {
        requestID = UUID()
        task?.cancel()
        task = nil
    }
}

#if os(macOS)
import AppKit
import SwiftUI

/// Forwards SwiftUI's window delegate methods and preserves its close veto.
@MainActor
private final class ExternalSaveWindowCloseDelegate: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?
    private weak var original: (any NSWindowDelegate)?
    var participant: (any ExternalSaveTerminationParticipant)?
    private let decision = ExternalSaveWindowCloseDecision()
    private var approvedClose = false

    func attach(to window: NSWindow?) {
        guard let window else { detach(); return }
        if self.window !== window { detach() }
        if window.delegate !== self {
            original = window.delegate
            self.window = window
            window.delegate = self
        }
    }

    func detach() {
        decision.cancel()
        if let window, window.delegate === self { window.delegate = original }
        window = nil
        original = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return original?.windowShouldClose?(sender) ?? true }
        if approvedClose { return true }
        guard let participant else { return original?.windowShouldClose?(sender) ?? true }
        decision.requestClose(participant: participant, originalShouldClose: { [weak self, weak sender] in
            guard let self, let sender, sender === self.window, sender.delegate === self else { return false }
            return self.original?.windowShouldClose?(sender) ?? true
        }, close: { [weak self, weak sender] in
            guard let self, let sender, sender === self.window, sender.delegate === self else { return }
            self.approvedClose = true
            defer { self.approvedClose = false }
            sender.performClose(nil)
        })
        return false
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if original?.responds(to: selector) == true { return original }
        return super.forwardingTarget(for: selector)
    }
}

@MainActor
private struct ExternalSaveWindowCloseAttachment: NSViewRepresentable {
    let participant: any ExternalSaveTerminationParticipant

    final class WindowReader: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }

    func makeCoordinator() -> ExternalSaveWindowCloseDelegate { ExternalSaveWindowCloseDelegate() }

    func makeNSView(context: Context) -> WindowReader {
        let view = WindowReader()
        view.onWindowChange = { [weak coordinator = context.coordinator] in coordinator?.attach(to: $0) }
        context.coordinator.participant = participant
        return view
    }

    func updateNSView(_ view: WindowReader, context: Context) {
        context.coordinator.participant = participant
        context.coordinator.attach(to: view.window)
    }

    static func dismantleNSView(_ view: WindowReader, coordinator: ExternalSaveWindowCloseDelegate) {
        view.onWindowChange = nil
        coordinator.detach()
    }
}

extension View {
    func guardExternalSaveWindowClose(participant: any ExternalSaveTerminationParticipant) -> some View {
        background(ExternalSaveWindowCloseAttachment(participant: participant).frame(width: 0, height: 0))
    }
}
#endif
