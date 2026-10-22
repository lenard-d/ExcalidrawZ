//
//  ExcalidrawCore+UserSettings.swift
//  ExcalidrawZ
//
//  Created by Claude on 2026/01/04.
//

import Foundation
import WebKit

extension ExcalidrawCore {
    /// Apply the global default drawing settings stored in `AppPreference` to the
    /// current canvas. The Preferences inspector pushes global → canvas via the
    /// struct-overload directly; this no-arg version is kept as a convenience.
    @MainActor
    func applyUserSettings() async throws {
        guard let appPreference = self.parent?.appPreference else { return }
        try await applyUserSettings(appPreference.customDrawingSettings)
    }

    /// Push an explicit `UserDrawingSettings` struct to the current canvas.
    /// Fill missing fields from global preferences, then UI defaults, because the
    /// web receiver resets omitted fields. Explicit values, including null, are kept.
    @MainActor
    func applyUserSettings(_ settings: UserDrawingSettings) async throws {
        let effectiveSettings = settings
            .filling(defaults: parent?.appPreference.customDrawingSettings ?? .uiDefaults)
            .filling(defaults: .uiDefaults)
        guard let jsonString = effectiveSettings.toJSONString() else {
            logger.error("Failed to convert settings to JSON string")
            return
        }

        _ = try await self.webView.callAsyncJavaScript(
            "window.excalidrawZHelper?.applyUserSettings(\(jsonString));",
            arguments: [:],
            contentWorld: .page
        )
        self.logger.debug("User settings applied successfully")
    }
    
    /// Fetch current drawing settings from Excalidraw
    /// Returns the current user drawing settings from the web view
    /// Reads the canvas's drawing prefs from the JS helper. Returns an empty struct
    /// when localStorage doesn't yet have an `excalidraw-state` entry (fresh install
    /// / never-used domain) — the JS side returns `null` in that case.
    @MainActor
    func fetchCurrentUserSettings() async throws -> UserDrawingSettings {
        let result = try await self.webView.callAsyncJavaScript(
            "return window.excalidrawZHelper?.getUserSettings();",
            arguments: [:],
            contentWorld: .page
        )
        guard let settingsDict = result as? [String: Any] else {
            return UserDrawingSettings()
        }
        return UserDrawingSettings.from(dict: settingsDict)
    }
}

enum UserSettingsError: LocalizedError {
    case invalidResponse
    
    var errorDescription: String? {
        switch self {
            case .invalidResponse:
                return "Invalid response when fetching user settings"
        }
    }
}
