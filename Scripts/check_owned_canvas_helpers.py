"""Run exact native helper/controller excerpts with a delayed bridge, without an app host."""

import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile

ENGINE = "ExcalidrawZ/ExcalidrawView/Engine/"
ELEMENTS = ENGINE + "ExcalidrawCore/Helpers/ExcalidrawCore+ElementHelpers.swift"
MEDIA = ENGINE + "ExcalidrawCore/Helpers/ExcalidrawCore+MediaHelpers.swift"
CONTROLLER = ENGINE + "ExcalidrawDocumentSyncController.swift"
SNAPSHOT = ENGINE + "Snapshot/ExcalidrawDocumentSnapshotCoordinator.swift"
WEB_ACTOR = ENGINE + "ExcalidrawCore/ExcalidrawWebActor.swift"
DEPENDENCIES = (
    "ExcalidrawZ/Utils/FileSyncCoordinator/DocumentLoadStateMachine.swift",
    "ExcalidrawZ/Utils/FileSyncCoordinator/OwnedCanvasMutationCoordinator.swift",
    "ExcalidrawZ/Utils/FileSyncCoordinator/CanvasSaveCoordinator.swift",
    "ExcalidrawZ/Utils/FileSyncCoordinator/ExternalCanvasReloadRequest.swift",
    ENGINE + "Snapshot/ExcalidrawDocumentProgrammaticSnapshotCommitter.swift",
)


def extract_block(source: str, marker: str) -> str:
    start = source.index(marker)
    opening = source.index("{", start)
    end = opening + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def read_source(root: Path, path: str, revision: str | None) -> str:
    if revision:
        return subprocess.check_output(["git", "show", f"{revision}:{path}"], cwd=root, text=True)
    return (root / path).read_text()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", help="Use immutable production source for red/green comparison")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    generated = (root / "Scripts/OwnedCanvasHelpersProbe.swift").read_text()
    excerpts = {
        "ELEMENTS": read_source(root, ELEMENTS, args.revision),
        "MEDIA": "extension ExcalidrawCore { @MainActor\n" + extract_block(
            read_source(root, MEDIA, args.revision), "public func loadImageToExcalidrawCanvas("
        ) + "\n}",
    }
    controller = read_source(root, CONTROLLER, args.revision)
    web_actor = read_source(root, WEB_ACTOR, args.revision)
    excerpts["IMAGE RESULT"] = "\n".join(extract_block(web_actor, marker) for marker in (
        "private func jsInt(", "private func jsDouble(", "struct LoadImageResult {"
    ))
    markers = ("func captureCanvasMutationSession()", "func isCurrentCanvasMutationSession(",
               "func performOwnedCanvasMutation(", "func currentCanvasFileForRecoveryExport()")
    excerpts["CONTROLLER"] = "\n".join(
        "@MainActor\n" + extract_block(controller, marker) for marker in markers
    ) + "\n" + extract_block(controller, "private func beginReceivedStateChanged(")
    snapshot = read_source(root, SNAPSHOT, args.revision)
    excerpts["SNAPSHOT"] = "\n".join(
        ("@MainActor\n" if marker.startswith("func performOwned") or marker.startswith("func schedule") else "")
        + extract_block(snapshot, marker)
        for marker in ("func waitForOwnedCanvasOperations()", "func performOwnedCanvasMutation(",
                       "func scheduleProgrammaticMutationCommit(", "func flushPendingDirtySnapshot(",
                       "private func commitDirtySnapshot(")
    )
    for label, block in excerpts.items():
        print(label, hashlib.sha256(block.encode()).hexdigest(), flush=True)
        generated = generated.replace("// INSERT " + label, block)
    with tempfile.TemporaryDirectory(prefix="excalidrawz-owned-helpers-") as directory:
        work = Path(directory)
        probe = work / "probe.swift"
        probe.write_text(generated)
        dependencies = []
        for path in DEPENDENCIES:
            content = read_source(root, path, args.revision)
            target = work / Path(path).name
            target.write_text(content)
            dependencies.append(str(target))
            print(path, hashlib.sha256(content.encode()).hexdigest(), flush=True)
        subprocess.run(
            ["xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(work / "cache"),
             *dependencies, str(probe), "-o", str(work / "probe")], check=True, timeout=60,
        )
        subprocess.run([str(work / "probe")], check=True, timeout=15)


if __name__ == "__main__":
    main()
