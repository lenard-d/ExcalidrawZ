import XCTest
@testable import ExcalidrawZ
#if os(macOS)
import AppKit
#endif

final class ToolbarNativeEyeDropperMessageTests: XCTestCase {
    func testWebCancellationMessagesDecodeWithTheirRequestIdentity() throws {
        // These are the three cancellation paths emitted by the public web core.
        let fixtures = [
            """
            {"event":"cancelNativeEyeDropper","data":{"requestId":"45b5bb2b-efe6-433a-95d2-f7c0bfe59ea2","reason":"unmounted"}}
            """,
            """
            {"event":"cancelNativeEyeDropper","data":{"requestId":"6b5408e5-c1c2-475c-8a4a-4993c9a92007","reason":"superseded"}}
            """,
            """
            {"event":"cancelNativeEyeDropper","data":{"requestId":"a5fdc6f9-831a-466a-abb4-8dcc22edd695","reason":"disabled"}}
            """,
        ]
        let expected = [
            ("45b5bb2b-efe6-433a-95d2-f7c0bfe59ea2", "unmounted"),
            ("6b5408e5-c1c2-475c-8a4a-4993c9a92007", "superseded"),
            ("a5fdc6f9-831a-466a-abb4-8dcc22edd695", "disabled"),
        ]

        for (fixture, (requestId, reason)) in zip(fixtures, expected) {
            let message = try JSONDecoder().decode(ExcalidrawCore.ExcalidrawZMessage.self, from: Data(fixture.utf8))
            guard case .cancelNativeEyeDropper(let cancellation) = message else {
                return XCTFail("Cancellation must reach its own handler")
            }
            XCTAssertEqual(cancellation.data.requestId, requestId)
            XCTAssertEqual(cancellation.data.reason, reason)
        }
    }

    func testWebRequestsStillDecode() throws {
        let fixtures = [
            ("2e3b63db-ef48-4111-8096-54a9bf59d888", "elementStroke", "light"),
            ("45b5bb2b-efe6-433a-95d2-f7c0bfe59ea2", "elementStroke", "dark"),
            ("6b5408e5-c1c2-475c-8a4a-4993c9a92007", "elementBackground", "light"),
            ("a5fdc6f9-831a-466a-abb4-8dcc22edd695", "elementStroke", "light"),
        ]
        for (requestId, colorPickerType, theme) in fixtures {
            let fixture = """
            {"event":"requestNativeEyeDropper","data":{"requestId":"\(requestId)","colorPickerType":"\(colorPickerType)","theme":"\(theme)"}}
            """
            let message = try JSONDecoder().decode(ExcalidrawCore.ExcalidrawZMessage.self, from: Data(fixture.utf8))
            guard case .requestNativeEyeDropper(let request) = message else {
                return XCTFail("Request must reach its own handler")
            }
            XCTAssertEqual(request.data.requestId, requestId)
            XCTAssertEqual(request.data.colorPickerType, colorPickerType)
            XCTAssertEqual(request.data.theme, theme)
        }
    }

    func testCancellationRequiresARequestIdentity() {
        for data in ["{}", "{\"requestId\":123}"] {
            let fixture = "{\"event\":\"cancelNativeEyeDropper\",\"data\":\(data)}"
            XCTAssertThrowsError(try JSONDecoder().decode(ExcalidrawCore.ExcalidrawZMessage.self, from: Data(fixture.utf8)))
        }
    }

    func testCancellationDoesNotRequireADiagnosticReason() throws {
        let fixture = """
        {"event":"cancelNativeEyeDropper","data":{"requestId":"request-1"}}
        """
        let message = try JSONDecoder().decode(ExcalidrawCore.ExcalidrawZMessage.self, from: Data(fixture.utf8))
        guard case .cancelNativeEyeDropper(let cancellation) = message else {
            return XCTFail("Expected cancellation")
        }
        XCTAssertEqual(cancellation.data.requestId, "request-1")
        XCTAssertNil(cancellation.data.reason)
    }
}

#if os(macOS)
@MainActor
final class ToolbarNativeEyeDropperCoordinatorTests: XCTestCase {
    func testCancellationDropsLateSampleWithoutEchoingACompletion() async {
        let sampleStarted = expectation(description: "Sample started")
        var finishSample: CheckedContinuation<NSColor?, Never>?
        var completions: [ExcalidrawCore.NativeEyeDropperCompletion] = []
        let coordinator = ExcalidrawNativeEyeDropperCoordinator(sampleColor: {
            await withCheckedContinuation { continuation in
                finishSample = continuation
                sampleStarted.fulfill()
            }
        }, onComplete: { completions.append($0) })
        let task = Task { await coordinator.request(request("cancelled")) }
        await fulfillment(of: [sampleStarted], timeout: 2)

        coordinator.cancel(requestId: "cancelled")
        finishSample?.resume(returning: .red)
        await task.value

        XCTAssertTrue(completions.isEmpty)
    }

    func testStaleCancellationDoesNotCancelTheCurrentRequest() async {
        let sampleStarted = expectation(description: "Sample started")
        var finishSample: CheckedContinuation<NSColor?, Never>?
        var completions: [ExcalidrawCore.NativeEyeDropperCompletion] = []
        let coordinator = ExcalidrawNativeEyeDropperCoordinator(sampleColor: {
            await withCheckedContinuation { continuation in
                finishSample = continuation
                sampleStarted.fulfill()
            }
        }, onComplete: { completions.append($0) })
        let task = Task { await coordinator.request(request("current")) }
        await fulfillment(of: [sampleStarted], timeout: 2)

        coordinator.cancel(requestId: "older")
        finishSample?.resume(returning: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        await task.value

        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first?.requestId, "current")
        XCTAssertEqual(completions.first?.color, "#00FF00")
        XCTAssertNil(completions.first?.cancelled)
    }

    func testLateCancelledSampleCannotCompleteANewerRequest() async {
        let firstStarted = expectation(description: "First sample started")
        let secondStarted = expectation(description: "Second sample started")
        var samples: [CheckedContinuation<NSColor?, Never>] = []
        var completions: [ExcalidrawCore.NativeEyeDropperCompletion] = []
        let coordinator = ExcalidrawNativeEyeDropperCoordinator(sampleColor: {
            await withCheckedContinuation { continuation in
                samples.append(continuation)
                (samples.count == 1 ? firstStarted : secondStarted).fulfill()
            }
        }, onComplete: { completions.append($0) })
        let first = Task { await coordinator.request(request("first")) }
        await fulfillment(of: [firstStarted], timeout: 2)
        coordinator.cancel(requestId: "first")
        let second = Task { await coordinator.request(request("second")) }
        await fulfillment(of: [secondStarted], timeout: 2)

        samples[0].resume(returning: .red)
        await first.value
        coordinator.cancel(requestId: "first")
        XCTAssertTrue(completions.isEmpty)
        samples[1].resume(returning: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        await second.value

        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first?.requestId, "second")
        XCTAssertEqual(completions.first?.color, "#0000FF")
    }

    func testReplacementCancelsOldPromiseAndIgnoresItsLateSample() async {
        let firstStarted = expectation(description: "First sample started")
        let secondStarted = expectation(description: "Second sample started")
        var samples: [CheckedContinuation<NSColor?, Never>] = []
        var completions: [ExcalidrawCore.NativeEyeDropperCompletion] = []
        let coordinator = ExcalidrawNativeEyeDropperCoordinator(sampleColor: {
            await withCheckedContinuation { continuation in
                samples.append(continuation)
                (samples.count == 1 ? firstStarted : secondStarted).fulfill()
            }
        }, onComplete: { completions.append($0) })
        let first = Task { await coordinator.request(request("first")) }
        await fulfillment(of: [firstStarted], timeout: 2)
        let second = Task { await coordinator.request(request("second")) }
        await fulfillment(of: [secondStarted], timeout: 2)

        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first?.requestId, "first")
        XCTAssertEqual(completions.first?.cancelled, true)
        samples[0].resume(returning: .red)
        await first.value
        XCTAssertEqual(completions.count, 1)
        samples[1].resume(returning: nil)
        await second.value
        XCTAssertEqual(completions.map(\.requestId), ["first", "second"])
        XCTAssertEqual(completions.last?.cancelled, true)
    }

    func testCancellationWhileReplacementCompletionIsSuspendedPreventsSampling() async {
        let firstStarted = expectation(description: "First sample started")
        let cancellationStarted = expectation(description: "Old cancellation is being sent")
        var finishSample: CheckedContinuation<NSColor?, Never>?
        var finishCancellation: CheckedContinuation<Void, Never>?
        var sampleCount = 0
        var completions: [ExcalidrawCore.NativeEyeDropperCompletion] = []
        let coordinator = ExcalidrawNativeEyeDropperCoordinator(sampleColor: {
            sampleCount += 1
            guard sampleCount == 1 else { return .red }
            return await withCheckedContinuation { continuation in
                finishSample = continuation
                firstStarted.fulfill()
            }
        }, onComplete: { completion in
            completions.append(completion)
            if completion.requestId == "first" {
                await withCheckedContinuation { continuation in
                    finishCancellation = continuation
                    cancellationStarted.fulfill()
                }
            }
        })
        let first = Task { await coordinator.request(request("first")) }
        await fulfillment(of: [firstStarted], timeout: 2)
        let second = Task { await coordinator.request(request("second")) }
        await fulfillment(of: [cancellationStarted], timeout: 2)

        coordinator.cancel(requestId: "second")
        finishCancellation?.resume()
        await second.value
        finishSample?.resume(returning: .red)
        await first.value

        XCTAssertEqual(sampleCount, 1)
        XCTAssertEqual(completions.map(\.requestId), ["first"])
    }

    func testSuspendedReplacementCannotTakeOverANewerRequest() async {
        let firstStarted = expectation(description: "First sample started")
        let thirdStarted = expectation(description: "Newest sample started")
        let cancellationStarted = expectation(description: "Old cancellation is being sent")
        var samples: [CheckedContinuation<NSColor?, Never>] = []
        var finishCancellation: CheckedContinuation<Void, Never>?
        var sampleCount = 0
        var completions: [ExcalidrawCore.NativeEyeDropperCompletion] = []
        let coordinator = ExcalidrawNativeEyeDropperCoordinator(sampleColor: {
            sampleCount += 1
            guard sampleCount <= 2 else { return .red }
            return await withCheckedContinuation { continuation in
                samples.append(continuation)
                (sampleCount == 1 ? firstStarted : thirdStarted).fulfill()
            }
        }, onComplete: { completion in
            completions.append(completion)
            if completion.requestId == "first" {
                await withCheckedContinuation { continuation in
                    finishCancellation = continuation
                    cancellationStarted.fulfill()
                }
            }
        })
        let first = Task { await coordinator.request(request("first")) }
        await fulfillment(of: [firstStarted], timeout: 2)
        let second = Task { await coordinator.request(request("second")) }
        await fulfillment(of: [cancellationStarted], timeout: 2)
        let third = Task { await coordinator.request(request("third")) }
        await fulfillment(of: [thirdStarted], timeout: 2)

        finishCancellation?.resume()
        await second.value
        samples[0].resume(returning: .red)
        await first.value
        samples[1].resume(returning: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        await third.value

        XCTAssertEqual(sampleCount, 2)
        XCTAssertEqual(completions.map(\.requestId), ["first", "second", "third"])
        XCTAssertEqual(completions.last?.color, "#0000FF")
    }

    private func request(_ id: String) -> ExcalidrawCore.NativeEyeDropperRequest {
        .init(requestId: id, colorPickerType: "elementStroke", theme: "light")
    }
}
#endif
