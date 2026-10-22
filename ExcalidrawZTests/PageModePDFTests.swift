import CoreGraphics
import ImageIO
import XCTest
@testable import ExcalidrawZ

final class PageModePDFTests: XCTestCase {
    func testPDFHasOrderedPortraitAndLandscapeMediaBoxes() throws {
        let writer = try PageModePDFWriter()
        let png = try image()
        try writer.append(png: png, page: page("portrait", width: 595, height: 842))
        try writer.append(png: png, page: page("landscape", width: 842, height: 595))
        let output = try writer.finish()
        let provider = try XCTUnwrap(CGDataProvider(data: output as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        XCTAssertEqual(document.numberOfPages, 2)
        XCTAssertEqual(document.page(at: 1)?.getBoxRect(.mediaBox).size, CGSize(width: 595, height: 842))
        XCTAssertEqual(document.page(at: 2)?.getBoxRect(.mediaBox).size, CGSize(width: 842, height: 595))
        let rendered = try XCTUnwrap(CGContext(data: nil, width: 10, height: 20, bitsPerComponent: 8, bytesPerRow: 40, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        rendered.scaleBy(x: 10 / 595, y: 20 / 842)
        rendered.drawPDFPage(try XCTUnwrap(document.page(at: 1)))
        let pixels = try XCTUnwrap(rendered.data).assumingMemoryBound(to: UInt8.self)
        // The source image's upper half stays red and its lower half stays blue.
        XCTAssertGreaterThan(pixels[40 * 2], pixels[40 * 2 + 2])
        XCTAssertGreaterThan(pixels[40 * 17 + 2], pixels[40 * 17])
        XCTAssertThrowsError(try writer.append(png: png, page: page("late", width: 595, height: 842)))
    }

    func testBadImageAndEmptyOutputFail() throws {
        let writer = try PageModePDFWriter()
        XCTAssertThrowsError(try writer.append(png: Data("invalid".utf8), page: page("bad", width: 595, height: 842)))
        XCTAssertThrowsError(try writer.finish())
    }

    func testSnapshotRejectsMissingFramesAndDuplicatePages() throws {
        let descriptor: [String: Any] = ["id": "page", "title": "Page", "width": 595, "height": 842, "locked": false]
        func snapshot(pages: [[String: Any]], elements: [[String: Any]]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["pages": pages, "scene": ["elements": elements, "files": [:]]]), as: UTF8.self)
        }
        XCTAssertThrowsError(try PageModeExportSnapshot(json: snapshot(pages: [descriptor], elements: [])))
        XCTAssertThrowsError(try PageModeExportSnapshot(json: snapshot(pages: [descriptor, descriptor], elements: [["id": "page", "type": "frame"]])))
    }

    static func image() throws -> Data {
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 0, 255, 255]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: 1, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func image() throws -> Data { try Self.image() }

    private func page(_ id: String, width: Double, height: Double) -> PageModePage {
        .init(id: id, title: id, width: width, height: height, locked: false)
    }
}
