//
//  ExcalidrawToolbarToolOrder.swift
//  ExcalidrawZ
//
//  Created by Codex on 2026/06/16.
//

import SwiftUI

struct ExcalidrawToolbarToolOrder: Equatable, Hashable {
    static let storageKey = "toolbarToolOrderData"

    static let defaultTools: [ExcalidrawTool] = [
        .cursor,
        .rectangle,
        .diamond,
        .ellipse,
        .arrow,
        .line,
        .freedraw,
        .text,
        .image,
        .eraser,
        .laser,
        .lasso,
        .hand,
        .frame,
        .webEmbed,
        .magicFrame,
    ]

    private static let shortcutLabels = [
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "0",
    ]

    var tools: [ExcalidrawTool]
    private(set) var directToolCount: Int

    init(tools: [ExcalidrawTool] = Self.defaultTools, directToolCount: Int = 9) {
        self.tools = Self.normalized(tools)
        self.directToolCount = min(max(directToolCount, 1), self.tools.count)
    }

    init(storedData: Data) {
        let decoder = JSONDecoder()
        if let stored = try? decoder.decode(StoredOrder.self, from: storedData) {
            self.init(
                tools: stored.tools.compactMap(ExcalidrawTool.init(toolbarOrderID:)),
                directToolCount: stored.directToolCount
            )
            return
        }
        let ids = (try? decoder.decode([String].self, from: storedData)) ?? []
        self.init(tools: ids.compactMap(ExcalidrawTool.init(toolbarOrderID:)))
    }

    var storedData: Data {
        let stored = StoredOrder(tools: tools.map(\.toolbarOrderID), directToolCount: directToolCount)
        return (try? JSONEncoder().encode(stored)) ?? Data()
    }

    mutating func addDirectTool(_ tool: ExcalidrawTool) {
        guard let index = tools.firstIndex(of: tool), index >= directToolCount else { return }
        tools.remove(at: index)
        tools.insert(tool, at: directToolCount)
        directToolCount += 1
    }

    func pickerItems(
        for sizeClass: ExcalidrawToolbarToolSizeClass
    ) -> (primary: [ExcalidrawTool], secondary: [ExcalidrawTool]) {
        guard sizeClass != .expanded else {
            return (tools, [])
        }

        let primaryCount = Self.primaryToolCount(for: sizeClass)
        return (
            Array(tools.prefix(primaryCount)),
            Array(tools.dropFirst(primaryCount))
        )
    }

    func shortcutLabel(for tool: ExcalidrawTool, includingAlternate: Bool = false) -> String? {
        guard tool.supportsOrderedNumericShortcut,
              let index = tools.firstIndex(of: tool),
              index < Self.shortcutLabels.count * (includingAlternate ? 2 : 1) else {
            return nil
        }
        let prefix = index >= Self.shortcutLabels.count ? "⌥" : ""
        return prefix + Self.shortcutLabels[index % Self.shortcutLabels.count]
    }

    func tool(forShortcutNumber number: Int, alternate: Bool = false) -> ExcalidrawTool? {
        guard (0...9).contains(number) else { return nil }
        let index = (number == 0 ? 9 : number - 1) + (alternate ? Self.shortcutLabels.count : 0)
        guard tools.indices.contains(index) else { return nil }

        let tool = tools[index]
        guard tool.supportsOrderedNumericShortcut else { return nil }
        return tool
    }

    mutating func move(from offsets: IndexSet, to destination: Int) {
        tools.move(fromOffsets: offsets, toOffset: destination)
        tools = Self.normalized(tools)
    }

    private static func primaryToolCount(
        for sizeClass: ExcalidrawToolbarToolSizeClass
    ) -> Int {
        switch sizeClass {
            case .dense, .compact:
                6
            case .regular:
                9
            case .expanded:
                defaultTools.count
        }
    }

    private static func normalized(_ tools: [ExcalidrawTool]) -> [ExcalidrawTool] {
        var seen = Set<ExcalidrawTool>()
        var normalized: [ExcalidrawTool] = []

        for tool in tools where defaultTools.contains(tool) && !seen.contains(tool) {
            normalized.append(tool)
            seen.insert(tool)
        }

        for tool in defaultTools where !seen.contains(tool) {
            normalized.append(tool)
        }

        return normalized
    }

    private struct StoredOrder: Codable {
        let tools: [String]
        let directToolCount: Int

        init(tools: [String], directToolCount: Int) {
            self.tools = tools
            self.directToolCount = directToolCount
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tools = try container.decode([String].self, forKey: .tools)
            directToolCount = (try? container.decode(Int.self, forKey: .directToolCount)) ?? 9
        }
    }
}
