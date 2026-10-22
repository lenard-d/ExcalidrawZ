import CoreGraphics
import Foundation
import ImageIO

/// Appends one rendered page at a time without keeping page images or plaintext files on disk.
final class PageModePDFWriter {
    private let output = NSMutableData()
    private let context: CGContext
    private var pageCount = 0
    private var finished = false

    init() throws {
        guard let consumer = CGDataConsumer(data: output),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw PageModeError.invalidExport
        }
        self.context = context
    }

    func append(png: Data, page: PageModePage) throws {
        guard !finished,
              page.width.isFinite, page.height.isFinite,
              page.width > 0, page.height > 0,
              page.width <= 20_000, page.height <= 20_000,
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PageModeError.invalidExport
        }
        var bounds = CGRect(x: 0, y: 0, width: page.width, height: page.height)
        let mediaBox = NSData(bytes: &bounds, length: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox as String: mediaBox] as CFDictionary)
        context.draw(image, in: bounds)
        context.endPDFPage()
        pageCount += 1
    }

    func finish() throws -> Data {
        guard !finished, pageCount > 0 else { throw PageModeError.invalidExport }
        context.closePDF()
        finished = true
        return output as Data
    }

    deinit {
        if !finished { context.closePDF() }
    }
}
