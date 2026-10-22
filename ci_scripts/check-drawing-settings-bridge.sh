#!/bin/bash
set -euo pipefail

# Run from any directory: bash ci_scripts/check-drawing-settings-bridge.sh
# This standalone package captures JavaScript. It does not launch the app or WebKit.
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/excalidrawz-settings-bridge.XXXXXX")"
trap 'rm -rf -- "$check_dir"' EXIT
mkdir -p "$check_dir/Sources"

sources=(
    "ExcalidrawZ/Models/Nullable.swift"
    "ExcalidrawZ/ExcalidrawView/components/DrawingSettingsPanel/UserDrawingSettings.swift"
    "ExcalidrawZ/Store/CanvasDrawingSettingsState.swift"
    "ExcalidrawZ/ExcalidrawView/Engine/ExcalidrawCore/Helpers/ExcalidrawCore+UserSettings.swift"
    "ExcalidrawZTests/UserDrawingSettingsBridgeTests.swift"
)
for source in "${sources[@]}"; do
    cp "$repo_dir/$source" "$check_dir/Sources/"
done

# Keep complete enum declarations from their owners, without unrelated element models.
copy_enum() {
    awk -v name="$1" '
        $0 ~ "^enum " name "[: ]" { copying = 1 }
        copying { print }
        copying && /^}/ { found = 1; exit }
        END { if (!found) exit 1 }
    ' "$repo_dir/$2" >> "$check_dir/Sources/ProductionEnums.swift"
}
printf 'import Foundation\n' > "$check_dir/Sources/ProductionEnums.swift"
copy_enum ExcalidrawFillStyle "ExcalidrawZ/Models/ExcalidrawElementBase.swift"
copy_enum ExcalidrawStrokeStyle "ExcalidrawZ/Models/ExcalidrawElementBase.swift"
copy_enum ExcalidrawStrokeSharpness "ExcalidrawZ/Models/ExcalidrawElements/ExcalidrawGenricElement.swift"
copy_enum Arrowhead "ExcalidrawZ/Models/ExcalidrawElements/ExcalidrawLinearElement.swift"

cat > "$check_dir/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DrawingSettingsBridgeChecks",
    platforms: [.macOS(.v14)],
    targets: [.testTarget(
        name: "BridgeTests",
        path: "Sources",
        swiftSettings: [.define("USER_DRAWING_SETTINGS_BRIDGE_STANDALONE")]
    )]
)
SWIFT

CLANG_MODULE_CACHE_PATH="$check_dir/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$check_dir/module-cache" \
swift test --package-path "$check_dir" --scratch-path "$check_dir/build" \
    --cache-path "$check_dir/cache" --config-path "$check_dir/config" \
    --security-path "$check_dir/security" --jobs 2 \
    -Xswiftc -module-cache-path -Xswiftc "$check_dir/module-cache"
