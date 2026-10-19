#if USER_DRAWING_SETTINGS_BRIDGE_STANDALONE
import Foundation
import WebKit
import XCTest

// Compile with the production settings helper, state, model, and model enums.
// This adapter captures JavaScript without constructing the app core or WebKit.
@MainActor
final class ExcalidrawCore {
    var parent: DrawingSettingsBridgeParent?
    let webView = DrawingSettingsJavaScriptCapture()
    let logger = DrawingSettingsBridgeLogger()
}

@MainActor
final class DrawingSettingsBridgeParent {
    let appPreference = DrawingSettingsBridgePreferences()
}

@MainActor
final class DrawingSettingsBridgePreferences {
    var customDrawingSettings = UserDrawingSettings()
}

struct DrawingSettingsBridgeLogger {
    func error(_ message: String) { XCTFail(message) }
    func debug(_ message: String) {}
}

@MainActor
final class DrawingSettingsJavaScriptCapture {
    private(set) var payloads: [Data] = []
    var onCall: (() -> Void)?

    func callAsyncJavaScript(
        _ script: String,
        arguments: [String: Any],
        contentWorld: WKContentWorld
    ) async throws -> Any? {
        let prefix = "window.excalidrawZHelper?.applyUserSettings("
        guard script.hasPrefix(prefix), script.hasSuffix(");") else {
            throw CaptureError.unexpectedScript
        }
        let payload = Data(script.dropFirst(prefix.count).dropLast(2).utf8)
        _ = try JSONSerialization.jsonObject(with: payload)
        payloads.append(payload)
        onCall?()
        return nil
    }

    enum CaptureError: Error {
        case unexpectedScript
    }
}

final class UserDrawingSettingsBridgeTests: XCTestCase {
    @MainActor
    func testOneCanvasColorEditPreservesInheritedSettingsWithoutFillingTheMirror() async throws {
        let core = ExcalidrawCore()
        let parent = DrawingSettingsBridgeParent()
        core.parent = parent
        parent.appPreference.customDrawingSettings.currentItemStrokeWidthKey = .bold
        parent.appPreference.customDrawingSettings.currentItemBackgroundColor = "#aabbcc"
        parent.appPreference.customDrawingSettings.currentItemOpacity = 40

        let state = CanvasDrawingSettingsState()
        state.coordinator = core
        let file = Data(##"{"appState":{"currentItemStrokeColor":"#112233"}}"##.utf8)
        let noEcho = expectation(description: "Changed inbound settings must not echo")
        noEcho.isInverted = true
        core.webView.onCall = { noEcho.fulfill() }
        state.apply(UserDrawingSettings.from(fileContent: file))
        await fulfillment(of: [noEcho], timeout: 0.2)
        XCTAssertTrue(core.webView.payloads.isEmpty, "Inbound file settings must not echo")

        let sent = expectation(description: "Canvas edit reaches native settings helper")
        core.webView.onCall = { sent.fulfill() }
        state.settings.currentItemStrokeColor = "#dd3355"
        await fulfillment(of: [sent], timeout: 2)

        XCTAssertEqual(core.webView.payloads.count, 1)
        let payload = try lastSettings(core)
        XCTAssertEqual(payload.currentItemStrokeColor, "#dd3355")
        XCTAssertEqual(payload.currentItemStrokeWidthKey, .bold)
        XCTAssertEqual(payload.currentItemBackgroundColor, "#aabbcc")
        XCTAssertEqual(payload.currentItemOpacity, 40)
        XCTAssertNil(state.settings.currentItemStrokeWidthKey)
        XCTAssertNil(state.settings.currentItemBackgroundColor)
        XCTAssertNil(state.settings.currentItemOpacity)
    }

    @MainActor
    func testExplicitFileValuesWinOverGlobalSettings() async throws {
        let core = ExcalidrawCore()
        let parent = DrawingSettingsBridgeParent()
        core.parent = parent
        parent.appPreference.customDrawingSettings.currentItemStrokeColor = "#112233"
        parent.appPreference.customDrawingSettings.currentItemStrokeWidthKey = .bold
        parent.appPreference.customDrawingSettings.currentItemOpacity = 60
        parent.appPreference.customDrawingSettings.currentItemFontSize = 31
        var file = UserDrawingSettings()
        file.currentItemStrokeColor = "#abcdef"
        file.currentItemStrokeWidthKey = .thin
        file.currentItemOpacity = 0

        try await core.applyUserSettings(file)

        let payload = try lastSettings(core)
        XCTAssertEqual(payload.currentItemStrokeColor, "#abcdef")
        XCTAssertEqual(payload.currentItemStrokeWidthKey, .thin)
        XCTAssertEqual(payload.currentItemOpacity, 0)
        XCTAssertEqual(payload.currentItemFontSize, 31)
        XCTAssertEqual(payload.currentItemRoughness, 1)
    }

    @MainActor
    func testCompleteInputIsUnchanged() async throws {
        let core = ExcalidrawCore()
        let parent = DrawingSettingsBridgeParent()
        core.parent = parent
        parent.appPreference.customDrawingSettings.currentItemStrokeColor = "#000000"
        let complete = UserDrawingSettings.from(dict: [
            "currentItemStrokeWidthKey": "thin",
            "currentItemStrokeVariability": "variable",
            "currentItemStrokeColor": "#123456",
            "currentItemBackgroundColor": "#654321",
            "currentItemStrokeStyle": "dashed",
            "currentItemFillStyle": "hachure",
            "currentItemRoughness": 2.0,
            "currentItemOpacity": 35.0,
            "currentItemFontFamily": 8,
            "currentItemFontSize": 27.0,
            "currentItemTextAlign": "right",
            "currentItemRoundness": "sharp",
            "currentItemArrowType": "round",
            "currentItemStartArrowhead": NSNull(),
            "currentItemEndArrowhead": "bar",
        ])

        try await core.applyUserSettings(complete)

        let payload = try lastSettings(core)
        XCTAssertEqual(payload, complete)
        let data = try XCTUnwrap(core.webView.payloads.last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json.count, 15)
        XCTAssertTrue(json["currentItemStartArrowhead"] is NSNull)
    }

    @MainActor
    func testMissingParentUsesUIDefaultsAndKeepsExplicitInput() async throws {
        let core = ExcalidrawCore()
        var input = UserDrawingSettings()
        input.currentItemStrokeColor = "#778899"

        try await core.applyUserSettings(input)

        let payload = try lastSettings(core)
        XCTAssertEqual(payload.currentItemStrokeColor, "#778899")
        XCTAssertEqual(payload.currentItemStrokeWidthKey, .medium)
        XCTAssertEqual(payload.currentItemBackgroundColor, "transparent")
        XCTAssertEqual(payload.currentItemFontFamily, .handDrawn)
        XCTAssertEqual(payload.currentItemOpacity, 100)
        XCTAssertEqual(payload.currentItemEndArrowhead, .value(.arrow))
    }

    @MainActor
    func testNullableValuesRemainExplicitAndAbsentValuesInherit() async throws {
        let core = ExcalidrawCore()
        let parent = DrawingSettingsBridgeParent()
        core.parent = parent
        parent.appPreference.customDrawingSettings.currentItemStartArrowhead = .value(.arrow)
        parent.appPreference.customDrawingSettings.currentItemEndArrowhead = .value(.circle)
        var input = UserDrawingSettings()
        input.currentItemStartArrowhead = .null

        try await core.applyUserSettings(input)

        let inherited = try lastSettings(core)
        XCTAssertEqual(inherited.currentItemStartArrowhead, .null)
        XCTAssertEqual(inherited.currentItemEndArrowhead, .value(.circle))
        let data = try XCTUnwrap(core.webView.payloads.last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(json["currentItemStartArrowhead"] is NSNull)
        XCTAssertEqual(json["currentItemEndArrowhead"] as? String, "circle")

        input.currentItemEndArrowhead = .value(.bar)
        try await core.applyUserSettings(input)
        let explicit = try lastSettings(core)
        XCTAssertEqual(explicit.currentItemEndArrowhead, .value(.bar))
    }

    @MainActor
    func testEachSendUsesCurrentGlobalSettingsWithoutCaching() async throws {
        let core = ExcalidrawCore()
        let parent = DrawingSettingsBridgeParent()
        core.parent = parent
        parent.appPreference.customDrawingSettings.currentItemStrokeWidthKey = .bold
        try await core.applyUserSettings(UserDrawingSettings())
        let first = try lastSettings(core)
        XCTAssertEqual(first.currentItemStrokeWidthKey, .bold)

        parent.appPreference.customDrawingSettings.currentItemStrokeWidthKey = .thin
        try await core.applyUserSettings(UserDrawingSettings())
        let second = try lastSettings(core)
        XCTAssertEqual(second.currentItemStrokeWidthKey, .thin)
    }

    @MainActor
    func testGlobalConvenienceMethodAlsoFillsMissingDefaults() async throws {
        let core = ExcalidrawCore()
        let parent = DrawingSettingsBridgeParent()
        core.parent = parent
        parent.appPreference.customDrawingSettings.currentItemStrokeColor = "#445566"

        try await core.applyUserSettings()

        let payload = try lastSettings(core)
        XCTAssertEqual(payload.currentItemStrokeColor, "#445566")
        XCTAssertEqual(payload.currentItemStrokeWidthKey, .medium)
        XCTAssertEqual(payload.currentItemOpacity, 100)
    }

    @MainActor
    private func lastSettings(_ core: ExcalidrawCore) throws -> UserDrawingSettings {
        let data = try XCTUnwrap(core.webView.payloads.last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return UserDrawingSettings.from(dict: json)
    }
}
#endif
