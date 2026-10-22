//
//  ExcalidrawToolbar+Layout.swift
//  ExcalidrawZ
//
//  Created by OpenAI on 2026/06/12.
//

import SwiftUI

enum ExcalidrawToolbarToolSizeClass {
    case dense
    case compact
    case regular
    case expanded
}

private struct ExcalidrawToolbarWidthBreakpoints {
    let denseUpperBound: CGFloat
    let compactUpperBound: CGFloat
    let regularUpperBound: CGFloat

    func sizeClass(for width: CGFloat) -> ExcalidrawToolbarToolSizeClass {
        switch width {
            case ..<denseUpperBound:
                return .dense
            case ..<compactUpperBound:
                return .compact
            case ..<regularUpperBound:
                return .regular
            default:
                return .expanded
        }
    }
}

private enum ExcalidrawToolbarLayoutBreakpoints {
    static let collaborationExtraWidth: CGFloat = 90

#if os(iOS)
    static let compactBottomToolbarWidth: CGFloat = 820

    static let iOSDefault = ExcalidrawToolbarWidthBreakpoints(
        denseUpperBound: 1000,
        compactUpperBound: 1110,
        regularUpperBound: 1400
    )
    static let iOSWithSidebar = ExcalidrawToolbarWidthBreakpoints(
        denseUpperBound: 1150,
        compactUpperBound: 1330,
        regularUpperBound: 1800
    )
    static let iOSWithInspector = ExcalidrawToolbarWidthBreakpoints(
        denseUpperBound: 1000,
        compactUpperBound: 1110,
        regularUpperBound: 1400
    )
    static let iOSWithSidebarAndInspector = ExcalidrawToolbarWidthBreakpoints(
        denseUpperBound: 1150,
        compactUpperBound: 1330,
        regularUpperBound: 1800
    )
#elseif os(macOS)
    static let macOSDefault = ExcalidrawToolbarWidthBreakpoints(
        denseUpperBound: 1170,
        compactUpperBound: 1330,
        regularUpperBound: 1510
    )
    static let macOSWithSidebar = ExcalidrawToolbarWidthBreakpoints(
        denseUpperBound: 1330,
        compactUpperBound: 1480,
        regularUpperBound: 1680
    )
    static let macOSWithInspector = ExcalidrawToolbarWidthBreakpoints(
        denseUpperBound: 1510,
        compactUpperBound: 1680,
        regularUpperBound: 1860
    )
    static let macOSWithSidebarAndInspector = ExcalidrawToolbarWidthBreakpoints(
        denseUpperBound: 1660,
        compactUpperBound: 1830,
        regularUpperBound: 1980
    )
#endif
}

enum ExcalidrawToolbarLayoutPolicy {
#if os(iOS)
    static func usesNativeIPadControls(
        isPad: Bool,
        horizontalSizeClass: UserInterfaceSizeClass?,
        containerWidth: CGFloat,
        isNormalEditor: Bool = true,
        isInteractionEnabled: Bool = true
    ) -> Bool {
        isPad && isNormalEditor && isInteractionEnabled && containerWidth > 0 && !usesCompactIOSBottomToolbar(
            horizontalSizeClass: horizontalSizeClass,
            containerWidth: containerWidth
        )
    }

    static func usesCompactIOSBottomToolbar(
        horizontalSizeClass: UserInterfaceSizeClass?,
        containerWidth: CGFloat
    ) -> Bool {
        if horizontalSizeClass == .compact {
            return true
        }
        guard containerWidth > 0 else {
            return false
        }
        return containerWidth < ExcalidrawToolbarLayoutBreakpoints.compactBottomToolbarWidth
    }
#endif

    static func toolSizeClass(
        for width: CGFloat,
        isSidebarPresented: Bool,
        isInspectorPresented: Bool,
        isCollaborationFile: Bool
    ) -> ExcalidrawToolbarToolSizeClass {
        let collaborationExtraWidth = ExcalidrawToolbarLayoutBreakpoints.collaborationExtraWidth
        let effectiveWidth = isCollaborationFile ? width - collaborationExtraWidth : width

#if os(iOS)
        return iOSToolSizeClass(
            for: effectiveWidth,
            isSidebarPresented: isSidebarPresented,
            isInspectorPresented: isInspectorPresented
        )
#elseif os(macOS)
        return macOSToolSizeClass(
            for: effectiveWidth,
            isSidebarPresented: isSidebarPresented,
            isInspectorPresented: isInspectorPresented
        )
#else
        return .expanded
#endif
    }

#if os(iOS)
    private static func iOSToolSizeClass(
        for width: CGFloat,
        isSidebarPresented: Bool,
        isInspectorPresented: Bool
    ) -> ExcalidrawToolbarToolSizeClass {
        iOSBreakpoints(
            isSidebarPresented: isSidebarPresented,
            isInspectorPresented: isInspectorPresented
        )
        .sizeClass(for: width)
    }

    private static func iOSBreakpoints(
        isSidebarPresented: Bool,
        isInspectorPresented: Bool
    ) -> ExcalidrawToolbarWidthBreakpoints {
        if isSidebarPresented, isInspectorPresented {
            return ExcalidrawToolbarLayoutBreakpoints.iOSWithSidebarAndInspector
        } else if isSidebarPresented {
            return ExcalidrawToolbarLayoutBreakpoints.iOSWithSidebar
        } else if isInspectorPresented {
            return ExcalidrawToolbarLayoutBreakpoints.iOSWithInspector
        }
        return ExcalidrawToolbarLayoutBreakpoints.iOSDefault
    }
#elseif os(macOS)
    private static func macOSToolSizeClass(
        for width: CGFloat,
        isSidebarPresented: Bool,
        isInspectorPresented: Bool
    ) -> ExcalidrawToolbarToolSizeClass {
        if #available(macOS 13.0, *) {
            if isSidebarPresented, isInspectorPresented {
                return ExcalidrawToolbarLayoutBreakpoints.macOSWithSidebarAndInspector
                    .sizeClass(for: width)
            } else if isSidebarPresented {
                return ExcalidrawToolbarLayoutBreakpoints.macOSWithSidebar
                    .sizeClass(for: width)
            } else if isInspectorPresented {
                return ExcalidrawToolbarLayoutBreakpoints.macOSWithInspector
                    .sizeClass(for: width)
            }
        }

        return ExcalidrawToolbarLayoutBreakpoints.macOSDefault
            .sizeClass(for: width)
    }
#endif
}
