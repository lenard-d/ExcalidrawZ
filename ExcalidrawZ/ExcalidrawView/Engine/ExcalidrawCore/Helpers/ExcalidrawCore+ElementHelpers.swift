//
//  ExcalidrawCore+ElementHelpers.swift
//  ExcalidrawZ
//
//  Created by Codex on 2026/06/18.
//

import Foundation

extension ExcalidrawCore {
    /// Registers document work before the bridge can suspend. Previews and collaboration own no local document save.
    @MainActor
    func callOwnedCanvasMutation(
        _ script: String,
        arguments: [String: Any] = [:],
        reason: String
    ) async throws -> Any? {
        try Task.checkCancellation()
        if parent == nil || parent?.type == .collaboration {
            return try await webView.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page)
        }

        var result: Any?
        try await documentSyncController.performOwnedCanvasMutation(reason: reason) { session in
            guard !self.isLoading, !self.webView.isLoading else { throw CancellationError() }
            var ownedArguments = arguments
            ownedArguments["expectedFileID"] = session.fileID
            result = try await self.webView.callAsyncJavaScript(
                """
                if (!window.excalidrawZHelper?._api ||
                    window.excalidrawZHelper.currentFileId !== expectedFileID) {
                    throw new Error("The canvas document changed.");
                }
                \(script)
                """,
                arguments: ownedArguments,
                contentWorld: .page
            )
        }
        return result
    }

    @MainActor
    func getSelectedElementIDs() async throws -> [String] {
        let result = try await webView.callAsyncJavaScript(
            "return window.excalidrawZHelper.getSelectedElementIds();",
            arguments: [:],
            contentWorld: .page
        )
        guard let ids = result as? [String] else {
            throw InvalidJavaScriptResult()
        }
        return ids
    }

    @MainActor
    func replaceAllElements(
        _ elements: [ExcalidrawElement],
        options: ReplaceAllElementsOptions = .init()
    ) async throws {
        guard !self.webView.isLoading else { return }
        let elementsJSON = try encodeJSON(elements)
        let optionsJSON = try encodeJSON(options)
        _ = try await callOwnedCanvasMutation(
            "window.excalidrawZHelper.replaceAllElements(\(elementsJSON), \(optionsJSON));",
            reason: "replaceAllElements"
        )
    }

    @MainActor
    func replaceAllElements(
        rawElementsJSON elementsJSON: String,
        options: ReplaceAllElementsOptions = .init()
    ) async throws {
        guard !self.webView.isLoading else { return }
        let optionsJSON = try encodeJSON(options)
        _ = try await callOwnedCanvasMutation(
            """
            const elements = JSON.parse(elementsJSON);
            const options = JSON.parse(optionsJSON);
            window.excalidrawZHelper.replaceAllElements(elements, options);
            """,
            arguments: [
                "elementsJSON": elementsJSON,
                "optionsJSON": optionsJSON
            ],
            reason: "replaceAllElementsRaw"
        )
    }

    @MainActor
    func createElements(
        _ elements: JSONValue,
        options: CreateElementsOptions = .init()
    ) async throws -> [JSONValue] {
        guard !self.webView.isLoading else {
            throw InvalidJavaScriptResult()
        }
        let elementsJSON = try encodeJSON(elements)
        let optionsJSON = try encodeJSON(options)
        let result = try await webView.callAsyncJavaScript(
            makeJavaScriptHelperCall(
                "window.excalidrawZHelper.createElements(\(elementsJSON), \(optionsJSON))"
            ),
            arguments: [:],
            contentWorld: .page
        )
        return try decodeJavaScriptHelperResult(result, as: [JSONValue].self)
    }

    @MainActor
    func addElements(_ elements: [ExcalidrawElement]) async throws {
        guard !self.webView.isLoading, !elements.isEmpty else { return }
        let elementsJSON = try encodeJSON(elements)
        _ = try await callOwnedCanvasMutation(
            "window.excalidrawZHelper.addElements(\(elementsJSON));",
            reason: "addElements"
        )
    }

    @MainActor
    func updateElements(_ operations: [UpdateElementOperation]) async throws {
        guard !self.webView.isLoading, !operations.isEmpty else { return }
        let operationsJSON = try encodeJSON(operations)
        _ = try await callOwnedCanvasMutation(
            "window.excalidrawZHelper.updateElements(\(operationsJSON));",
            reason: "updateElements"
        )
    }

    @MainActor
    func removeElements(ids: [String]) async throws {
        guard !self.webView.isLoading, !ids.isEmpty else { return }
        let idsJSON = try encodeJSON(ids)
        _ = try await callOwnedCanvasMutation(
            "window.excalidrawZHelper.removeElements(\(idsJSON));",
            reason: "removeElements"
        )
    }
}
