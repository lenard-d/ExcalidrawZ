"""Test exact install/capture/notification excerpts without launching the app."""

import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile

CONTROLLER = "ExcalidrawZ/ExcalidrawView/Engine/ExcalidrawDocumentSyncController.swift"
FILE_STATE = "ExcalidrawZ/Store/FileState+ExternalSave.swift"
DEPENDENCIES = (
    "ExcalidrawZ/Utils/FileSyncCoordinator/DocumentLoadStateMachine.swift",
    "ExcalidrawZ/Utils/FileSyncCoordinator/OwnedCanvasMutationCoordinator.swift",
    "ExcalidrawZ/Utils/FileSyncCoordinator/CanvasSaveCoordinator.swift",
)
METHODS = ("func captureCanvasMutationSession()", "func isCurrentCanvasMutationSession(",
           "func externalSaveSessionDidChange()")


def extract_block(source: str, marker: str) -> str:
    start = source.index(marker)
    opening = source.index("{", start)
    end = opening + 1
    depth = 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return source[start:end]


def read_source(root: Path, path: str, revision: str | None) -> str:
    if revision:
        return subprocess.check_output(["git", "show", f"{revision}:{path}"], cwd=root, text=True)
    return (root / path).read_text()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", help="Test old production source without changing Git")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    controller = read_source(root, CONTROLLER, args.revision)
    state = read_source(root, FILE_STATE, args.revision)
    install = "@MainActor\n" + extract_block(state, "func installExternalSaveSession(")
    methods = ["@MainActor\n" + extract_block(controller, marker)
               for marker in METHODS if marker in controller]
    publisher = "private let canvasMutationSessionChangeSubject = PassthroughSubject<Void, Never>()\n"
    assert publisher.strip() in controller
    publisher += extract_block(controller, "var canvasMutationSessionChanges:")
    template = (root / "Scripts/ExternalSaveSessionSignalProbe.swift").read_text()
    generated = template.replace("// INSERT INSTALL", install).replace(
        "// INSERT PUBLISHER", publisher
    ).replace("// INSERT CONTROLLER METHODS", "\n".join(methods))
    for label, block in [("install", install), ("controller", controller), ("fileState", state),
                         *zip(METHODS, methods)]:
        print(label, hashlib.sha256(block.encode()).hexdigest(), flush=True)
    with tempfile.TemporaryDirectory(prefix="excalidrawz-save-session-signal-") as directory:
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
        subprocess.run([str(work / "probe")], check=True, timeout=10)


if __name__ == "__main__":
    main()
