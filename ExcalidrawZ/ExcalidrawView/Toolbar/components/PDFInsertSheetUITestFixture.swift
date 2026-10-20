#if DEBUG && os(iOS) && targetEnvironment(simulator)
import ChocofordUI
import CryptoKit
import PDFKit
import SwiftUI
import UIKit

/// Hosts the real dialog with an in-memory PDF and observes its insert callback.
@MainActor
struct PDFInsertSheetUITestFixture: View {
    private let pdf = Self.syntheticPDF()
    private let scenario = Scenario(rawValue: ProcessInfo.processInfo.environment["EXCALIDRAWZ_PDF_INSERT_LAYOUT"] ?? "") ?? .wide
    @State private var callbackDigest = "none"
    @State private var callbackOptions = "none"
    @State private var callbackCount = 0
    @State private var pendingInsert: CheckedContinuation<Void, Error>?
    @State private var isPresented = true
    @State private var didDismiss = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if scenario.presentsSheet {
                Color.clear
                    .frame(width: scenario.size.width, height: scenario.size.height)
                    .sheet(isPresented: $isPresented, onDismiss: { didDismiss = true }) {
                        dialog
                    }
            } else {
                dialog
                    .frame(width: scenario.size.width, height: scenario.size.height)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("pdfFixture.viewport")
            }

            Text(Self.digest(pdf.pdfData))
                .font(.caption)
                .accessibilityIdentifier("pdfFixture.sourceDigest")
            Text("\(PDFDocument(data: pdf.pdfData)?.pageCount ?? 0)")
                .font(.caption)
                .accessibilityIdentifier("pdfFixture.sourcePageCount")
            Text(callbackDigest)
                .font(.caption)
                .accessibilityIdentifier("pdfFixture.callbackDigest")
            Text(callbackOptions)
                .font(.caption)
                .accessibilityIdentifier("pdfFixture.callbackOptions")
            Text("\(callbackCount)")
                .font(.caption)
                .accessibilityIdentifier("pdfFixture.callbackCount")
            Text(didDismiss ? "dismissed" : "presented")
                .font(.caption)
                .accessibilityIdentifier("pdfFixture.presentation")
            if scenario == .retry {
                Button("Fail pending insert") {
                    let continuation = pendingInsert
                    pendingInsert = nil
                    continuation?.resume(throwing: InsertFailure.expected)
                }
                .disabled(pendingInsert == nil)
                .accessibilityIdentifier("pdfFixture.failPendingInsert")
            }
            Spacer(minLength: 0)
        }
        // Keep the fixed viewport inside the window's safe area. At its top edge,
        // NavigationStack extends into the status bar and enlarges the viewport.
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var dialog: some View {
        PDFInsertSheet(pdfInfo: scenario == .empty ? nil : pdf) { data, mode, direction, itemsPerLine in
            callbackDigest = Self.digest(data)
            callbackOptions = "\(mode.rawValue),\(direction),\(itemsPerLine.map(String.init) ?? "nil")"
            callbackCount += 1
            if scenario == .retry {
                try await withCheckedThrowingContinuation { pendingInsert = $0 }
            } else if scenario != .success {
                throw InsertFailure.expected
            }
        }
        .environment(\.containerHorizontalSizeClass, scenario.isCompact ? .compact : .regular)
        .environment(\.horizontalSizeClass, scenario.isCompact ? .compact : .regular)
        .environment(\.dynamicTypeSize, scenario.usesAccessibilityText ? .accessibility5 : .large)
    }

    private enum InsertFailure: LocalizedError {
        case expected
        var errorDescription: String? { "Synthetic insert failure" }
    }

    private enum Scenario: String {
        case wide, tall, compact, accessibility, narrowAccessibility, shortRegular, cancel, success, empty, retry

        var size: CGSize {
            switch self {
            case .tall: CGSize(width: 768, height: 1024)
            case .shortRegular: CGSize(width: 1024, height: 320)
            default: CGSize(width: isCompact ? 320 : 1024, height: 768)
            }
        }

        var isCompact: Bool {
            self == .compact || self == .narrowAccessibility || self == .retry
        }

        var usesAccessibilityText: Bool {
            self == .accessibility || self == .narrowAccessibility
        }

        var presentsSheet: Bool { self == .cancel || self == .success }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func syntheticPDF() -> PDFDropInfo {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        let data = renderer.pdfData { context in
            for page in 1...4 {
                context.beginPage()
                ("PDF layout test page \(page)" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: nil)
            }
        }
        return PDFDropInfo(pdfData: data, fileName: "Layout test.pdf", sceneX: 0, sceneY: 0)
    }
}
#endif
