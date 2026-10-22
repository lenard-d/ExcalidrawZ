#if os(iOS)
import UIKit
import WebKit
import XCTest
@testable import ExcalidrawZ

@MainActor
final class ToolbarKeyboardCommandTests: XCTestCase {
    func testNumberCommandsSelectTheConfiguredOrderAfterReload() throws {
        var order = ExcalidrawToolbarToolOrder()
        order.move(from: IndexSet(integer: 3), to: 6)
        let restored = ExcalidrawToolbarToolOrder(storedData: order.storedData)
        var selectedTools: [ExcalidrawTool] = []
        let webView = makeWebView { key in
            if let tool = ExcalidrawCore.orderedToolbarTool(for: key, in: restored) {
                selectedTools.append(tool)
            }
        }

        for input in ["6", "4", "0"] {
            let command = try numberCommand(input, in: webView)
            webView.perform(command.action, with: command)
        }

        XCTAssertEqual(selectedTools, [.ellipse, .arrow, .eraser])
    }

    func testAlternateCommandsUseSecondBankAfterReorderAndReload() throws {
        var order = ExcalidrawToolbarToolOrder(directToolCount: 6)
        order.move(from: IndexSet(integer: 3), to: 11)
        let restored = ExcalidrawToolbarToolOrder(storedData: order.storedData)
        var selectedTools: [ExcalidrawTool] = []
        var alternateDispatchCount = 0
        let webView = makeWebView { key in
            if case .alternateNumber = key { alternateDispatchCount += 1 }
            if let tool = ExcalidrawCore.orderedToolbarTool(for: key, in: restored) {
                selectedTools.append(tool)
            }
        }

        for input in ["1", "2", "6", "0"] {
            let command = try numberCommand(input, alternate: true, in: webView)
            webView.perform(command.action, with: command)
        }
        let plain = try numberCommand("0", in: webView)
        webView.perform(plain.action, with: plain)

        XCTAssertEqual(alternateDispatchCount, 4, "Option+0 is dispatched but has no twentieth tool")
        XCTAssertEqual(selectedTools, [.ellipse, .lasso, .magicFrame, .laser])
        XCTAssertEqual(webView.keyCommands?.filter { $0.action == plain.action }.count, 20)
    }

    func testCachedCommandCannotChangeToolsDuringTextEntry() throws {
        for alternate in [false, true] {
            var dispatchCount = 0
            let webView = makeWebView { _ in dispatchCount += 1 }
            let command = try numberCommand("4", alternate: alternate, in: webView)

            webView.shouldHandleInput = false

            XCTAssertFalse(webView.canPerformAction(try XCTUnwrap(command.action), withSender: command))
            XCTAssertFalse(webView.keyCommands?.contains { $0.action == command.action } ?? false)
            webView.perform(command.action, with: command)
            XCTAssertEqual(dispatchCount, 0)

            webView.shouldHandleInput = true
            webView.perform(command.action, with: command)
            XCTAssertEqual(dispatchCount, 1)
        }
    }

    func testCachedCommandCannotChangeToolsWhenCanvasIsInactive() throws {
        for alternate in [false, true] {
            var dispatchCount = 0
            let webView = makeWebView { _ in dispatchCount += 1 }
            let command = try numberCommand("4", alternate: alternate, in: webView)

            webView.nativeInteractionEnabled = false

            XCTAssertFalse(webView.canPerformAction(try XCTUnwrap(command.action), withSender: command))
            webView.perform(command.action, with: command)
            XCTAssertEqual(dispatchCount, 0)
        }
    }

    func testModifiedAndInvalidCommandsDoNotChangeTools() throws {
        var dispatchCount = 0
        let webView = makeWebView { _ in dispatchCount += 1 }
        let command = try numberCommand("4", in: webView)
        let action = try XCTUnwrap(command.action)

        for modifiers: UIKeyModifierFlags in [
            .command, .control, .shift,
            [.alternate, .command], [.alternate, .control], [.alternate, .shift],
        ] {
            let modified = UIKeyCommand(input: "4", modifierFlags: modifiers, action: action)
            webView.perform(modified.action, with: modified)
        }
        for modifiers: UIKeyModifierFlags in [[], .alternate] {
            for input in ["", "11", "x"] {
                let invalid = UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
                webView.perform(invalid.action, with: invalid)
            }
        }

        XCTAssertEqual(dispatchCount, 0)
        XCTAssertFalse(command.wantsPriorityOverSystemBehavior)
    }

    private func numberCommand(
        _ input: String, alternate: Bool = false, in webView: ExcalidrawWebView
    ) throws -> UIKeyCommand {
        let modifiers: UIKeyModifierFlags = alternate ? .alternate : []
        return try XCTUnwrap(webView.keyCommands?.first { $0.input == input && $0.modifierFlags == modifiers })
    }

    private func makeWebView(
        handler: @escaping (ExcalidrawWebView.ToolbarActionKey) -> Void
    ) -> ExcalidrawWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return ExcalidrawWebView(frame: .zero, configuration: configuration, toolbarActionHandler: handler)
    }
}
#endif
