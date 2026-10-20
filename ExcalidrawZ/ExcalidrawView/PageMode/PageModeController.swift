import Combine
import Foundation

@MainActor
final class PageModeController: ObservableObject {
    typealias Execute = @MainActor (PageModeCommand) async throws -> String
    typealias Render = @MainActor (PageModeExportSnapshot, PageModePage) async throws -> Data

    @Published private(set) var pages: [PageModePage] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isValid = true
    @Published var errorMessage: String?
    @Published var exportData: Data?

    private let execute: Execute
    private let render: Render
    private let isCurrent: @MainActor () -> Bool
    private var sessionObservation: AnyCancellable?

    init(execute: @escaping Execute, render: @escaping Render, isCurrent: @escaping @MainActor () -> Bool) {
        self.execute = execute
        self.render = render
        self.isCurrent = isCurrent
    }

    @discardableResult
    func perform(_ command: PageModeCommand) async -> Bool {
        guard beginAction() else { return false }
        defer { isBusy = false }
        do {
            _ = try await executeState(command)
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Keeps add and camera navigation in one busy interval, using the returned page ID.
    func createPage(paper: PageModePaper, layout: PageModeLayout) async -> Bool {
        await createPage(command: .init(action: .add, width: paper.width, height: paper.height, layout: layout))
    }

    func createPage(after page: PageModePage, placement: PageModePlacement) async -> Bool {
        await createPage(command: .init(action: .add, pageID: page.id, placement: placement))
    }

    private func createPage(command: PageModeCommand) async -> Bool {
        guard beginAction() else { return false }
        defer { isBusy = false }
        do {
            var command = command
            command.title = String(localized: "Page \(pages.count + 1)")
            let state = try await executeState(command)
            guard let id = state.openedPageID, state.pages.contains(where: { $0.id == id }) else {
                throw PageModeError.failedAction
            }
            _ = try await executeState(.init(action: .open, pageID: id))
            return true
        } catch {
            report(error)
            return false
        }
    }

    func exportPDF() async {
        guard beginAction() else { return }
        defer { isBusy = false }
        exportData = nil
        do {
            let json = try await execute(.init(action: .exportScene))
            try validate()
            let snapshot = try PageModeExportSnapshot(json: json)
            let writer = try PageModePDFWriter()
            for page in snapshot.pages {
                try Task.checkCancellation()
                try validate()
                let png = try await render(snapshot, page)
                try validate()
                try autoreleasepool { try writer.append(png: png, page: page) }
            }
            try validate()
            exportData = try writer.finish()
        } catch {
            report(error)
        }
    }

    func invalidate() {
        sessionObservation?.cancel()
        sessionObservation = nil
        isValid = false
        pages = []
        exportData = nil
        errorMessage = nil
    }

    func invalidateIfNeeded() {
        if !isCurrent() { invalidate() }
    }

    func observeSessionChanges(_ changes: AnyPublisher<Void, Never>) {
        sessionObservation = changes
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.invalidateIfNeeded() }
        invalidateIfNeeded()
    }

    private func beginAction() -> Bool {
        guard !isBusy, isValid else { return false }
        guard isCurrent() else {
            invalidate()
            return false
        }
        errorMessage = nil
        isBusy = true
        return true
    }

    private func executeState(_ command: PageModeCommand) async throws -> PageModeState {
        try validate()
        let result = try await execute(command)
        try validate()
        let state = try JSONDecoder().decode(PageModeState.self, from: Data(result.utf8))
        pages = state.pages
        return state
    }

    private func validate() throws {
        try Task.checkCancellation()
        guard isValid, isCurrent() else {
            invalidate()
            throw PageModeError.documentChanged
        }
    }

    private func report(_ error: Error) {
        guard isValid, isCurrent() else {
            invalidate()
            return
        }
        errorMessage = error.localizedDescription
    }
}
