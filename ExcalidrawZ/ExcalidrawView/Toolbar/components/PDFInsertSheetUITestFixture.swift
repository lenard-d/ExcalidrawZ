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
    private let isCompact = ProcessInfo.processInfo.environment["EXCALIDRAWZ_PDF_INSERT_LAYOUT"] == "compact"
    @State private var callbackDigest = "none"
    @State private var callbackOptions = "none"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PDFInsertSheet(pdfInfo: pdf) { data, mode, direction, itemsPerLine in
                callbackDigest = Self.digest(data)
                callbackOptions = "\(mode.rawValue),\(direction),\(itemsPerLine.map(String.init) ?? "nil")"
                throw NSError(
                    domain: "PDFInsertSheetUITestFixture", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Synthetic insert failure"]
                )
            }
            .environment(\.containerHorizontalSizeClass, isCompact ? .compact : .regular)
            .environment(\.horizontalSizeClass, isCompact ? .compact : .regular)
            .environment(\.dynamicTypeSize, .large)
            .frame(width: isCompact ? 320 : 1024, height: 768)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("pdfFixture.viewport")

            Text(Self.digest(pdf.pdfData))
                .font(.caption)
                .accessibilityIdentifier("pdfFixture.sourceDigest")
            Text(callbackDigest)
                .font(.caption)
                .accessibilityIdentifier("pdfFixture.callbackDigest")
            Text(callbackOptions)
                .font(.caption)
                .accessibilityIdentifier("pdfFixture.callbackOptions")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
