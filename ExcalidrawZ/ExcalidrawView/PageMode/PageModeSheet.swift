import SwiftUI
import UniformTypeIdentifiers

struct PageModeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject var controller: PageModeController
    @State private var paper: PageModePaper = .a4Portrait
    @State private var renamedPage: PageModePage?
    @State private var isRenamePresented = false
    @State private var pageTitle = ""
    @State private var removedPage: PageModePage?
    @State private var isRemovePresented = false
    @State private var isExportPresented = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = controller.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .padding()
                        .accessibilityIdentifier("pages.error")
                }
                List {
                    Section {
                        Button(String(localized: "Canvas")) {
                            open(.init(action: .canvas))
                        }
                        Text(String(localized: "Pages are frames on the canvas. Draw inside a page to include your notes in its export."))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Section {
                        ForEach(Array(controller.pages.enumerated()), id: \.element.id) { index, page in
                            pageRow(page, index: index)
                        }
                        if controller.pages.isEmpty {
                            Text(String(localized: "Add a blank page to start your notes. Your existing drawing stays in place."))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Section {
                        Picker(String(localized: "Paper size"), selection: $paper) {
                            ForEach(PageModePaper.allCases) { paper in
                                Text(paper.title).tag(paper)
                            }
                        }
                        Button(String(localized: "Add page")) {
                            Task {
                                let command = PageModeCommand(
                                    action: .add,
                                    title: String(localized: "Page \(controller.pages.count + 1)"),
                                    width: paper.width,
                                    height: paper.height
                                )
                                if await controller.perform(command), let page = controller.pages.last {
                                    open(.init(action: .open, pageID: page.id))
                                }
                            }
                        }
                        .accessibilityIdentifier("pages.add")
                    }
                    Section {
                        Button(String(localized: "Export pages as PDF")) {
                            Task {
                                await controller.exportPDF()
                                isExportPresented = controller.exportData != nil
                            }
                        }
                        .disabled(controller.pages.isEmpty)
                        Text(String(localized: "Exports one image per page, in this order. Use the drawing's normal export to keep an editable Excalidraw file."))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(controller.isBusy || !controller.isValid)
                if controller.isBusy {
                    Text(String(localized: "Working…"))
                        .padding(.vertical, 8)
                        .accessibilityIdentifier("pages.working")
                }
            }
            .navigationTitle(String(localized: "Pages"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        .frame(minWidth: 280, idealWidth: 480, idealHeight: 600)
        .task { await controller.perform(.init(action: .list)) }
        .onChange(of: controller.isValid) { valid in
            if !valid { dismiss() }
        }
        .alert(String(localized: "Rename page"), isPresented: $isRenamePresented) {
            TextField(String(localized: "Page title"), text: $pageTitle)
            Button(String(localized: "Cancel"), role: .cancel) { renamedPage = nil }
            Button(String(localized: "Rename")) {
                guard let page = renamedPage else { return }
                let title = pageTitle
                renamedPage = nil
                Task { await controller.perform(.init(action: .rename, pageID: page.id, title: title)) }
            }
            .disabled(pageTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pageTitle.utf16.count > 120)
        }
        .confirmationDialog(String(localized: "Remove page boundary?"), isPresented: $isRemovePresented, titleVisibility: .visible) {
            Button(String(localized: "Remove page"), role: .destructive) {
                guard let page = removedPage else { return }
                removedPage = nil
                Task { await controller.perform(.init(action: .remove, pageID: page.id)) }
            }
        } message: {
            Text(String(localized: "All drawing content stays on the canvas. You can undo this change in the editor."))
        }
        .fileExporter(
            isPresented: $isExportPresented,
            document: controller.exportData.map(PageModePDFDocument.init(data:)),
            contentType: .pdf,
            defaultFilename: String(localized: "Pages")
        ) { result in
            if case .failure(let error) = result { controller.errorMessage = error.localizedDescription }
            controller.exportData = nil
        }
        .onDisappear { controller.invalidate() }
    }

    private func pageRow(_ page: PageModePage, index: Int) -> some View {
        HStack {
            Button {
                open(.init(action: .open, pageID: page.id))
            } label: {
                Text("\(index + 1). \(page.title.isEmpty ? String(localized: "Untitled page") : page.title)")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pages.open.\(index)")
            Menu {
                Button(String(localized: "Rename page")) {
                    pageTitle = page.title
                    renamedPage = page
                    isRenamePresented = true
                }
                Button(String(localized: "Move earlier")) {
                    Task { await controller.perform(.init(action: .move, pageID: page.id, offset: -1)) }
                }
                .disabled(index == 0)
                Button(String(localized: "Move later")) {
                    Task { await controller.perform(.init(action: .move, pageID: page.id, offset: 1)) }
                }
                .disabled(index == controller.pages.count - 1)
                Button(String(localized: "Remove page"), role: .destructive) {
                    removedPage = page
                    isRemovePresented = true
                }
            } label: {
                Label(String(localized: "Page actions"), systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(page.locked)
            .accessibilityLabel(String(localized: "Actions for page \(index + 1)"))
        }
    }

    private func open(_ command: PageModeCommand) {
        Task {
            if await controller.perform(command) { dismiss() }
        }
    }
}

private struct PageModePDFDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw PageModeError.invalidExport }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
