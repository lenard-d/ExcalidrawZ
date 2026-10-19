import Foundation

/// A fixed export snapshot keeps page order and drawing content from the same revision.
struct PageModeExportSnapshot {
    let pages: [PageModePage]
    let sceneJSON: String

    init(json: String) throws {
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pageObjects = object["pages"],
              let scene = object["scene"] as? [String: Any],
              let elements = scene["elements"] as? [[String: Any]],
              scene["files"] is [String: Any] else {
            throw PageModeError.invalidExport
        }
        pages = try JSONDecoder().decode(
            [PageModePage].self,
            from: JSONSerialization.data(withJSONObject: pageObjects)
        )
        guard !pages.isEmpty, Set(pages.map(\.id)).count == pages.count,
              pages.allSatisfy({ page in
                  page.width.isFinite && page.height.isFinite &&
                  page.width > 0 && page.height > 0 &&
                  page.width <= 20_000 && page.height <= 20_000 &&
                  elements.contains { $0["id"] as? String == page.id && $0["type"] as? String == "frame" }
              }),
              let encodedScene = String(
                  data: try JSONSerialization.data(withJSONObject: scene),
                  encoding: .utf8
              ) else {
            throw PageModeError.invalidExport
        }
        sceneJSON = encodedScene
    }

    static let renderScript = #"""
    const helper = window.excalidrawZHelper;
    if (!helper?._api || helper.currentFileId !== expectedFileID) {
        throw new Error("documentChanged");
    }
    const scene = JSON.parse(sceneJSON);
    const frame = scene.elements.find(element => element.id === pageID && element.type === "frame");
    if (!frame) throw new Error("pageMissing");
    if (![frame.width, frame.height].every(value => Number.isFinite(value) && value > 0)) {
        throw new Error("invalidExport");
    }
    // Bound raster memory for pages resized on the canvas. Normal A4 stays at 2x.
    const exportScale = Math.min(2, 4096 / frame.width, 4096 / frame.height,
        Math.sqrt(16_000_000 / (frame.width * frame.height)));
    const result = await helper.exportElementsToBlob(scene.elements, scene.files, {
        exportingFrame: frame,
        mimeType: "image/png",
        exportScale,
        withBackground: true,
        exportWithDarkMode: false,
        viewBackgroundColor: scene.appState.viewBackgroundColor || "#ffffff",
    });
    return result.blobData;
    """#
}
