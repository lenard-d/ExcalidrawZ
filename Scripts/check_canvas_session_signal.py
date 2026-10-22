"""Compile exact controller method excerpts; this does not launch the app."""

import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile

CONTROLLER = "ExcalidrawZ/ExcalidrawView/Engine/ExcalidrawDocumentSyncController.swift"
STATE = "ExcalidrawZ/Utils/FileSyncCoordinator/DocumentLoadStateMachine.swift"
METHODS = (
    "private func beginCanvasFileLoad(",
    "private func commitLoadedFile(",
    "private func finishCanvasFileLoad(",
    "func resetFileLoadState()",
)


def extract_block(source: str, marker: str) -> str:
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return source[start:end]


def read_source(root: Path, revision: str | None) -> str:
    if revision:
        return subprocess.check_output(
            ["git", "show", f"{revision}:{CONTROLLER}"], cwd=root, text=True
        )
    return (root / CONTROLLER).read_text()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", help="Compare an older controller without changing Git")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    source = read_source(root, args.revision)
    blocks = [extract_block(source, marker) for marker in METHODS]
    publisher = "private let canvasMutationSessionChangeSubject = PassthroughSubject<Void, Never>()\n"
    if "var canvasMutationSessionChanges:" in source:
        assert publisher.strip() in source
        publisher += extract_block(source, "var canvasMutationSessionChanges:")
    else:
        # The old controller has no broadcast. Supply only the observation port.
        publisher += "var canvasMutationSessionChanges: AnyPublisher<Void, Never> { canvasMutationSessionChangeSubject.eraseToAnyPublisher() }"
    template = (root / "Scripts/CanvasSessionSignalProbe.swift").read_text()
    generated = template.replace("// INSERT PUBLISHER", publisher).replace(
        "// INSERT METHODS", "\n".join(blocks)
    )
    with tempfile.TemporaryDirectory(prefix="excalidrawz-session-signal-") as directory:
        work = Path(directory)
        probe = work / "main.swift"
        probe.write_text(generated)
        for marker, block in zip(METHODS, blocks):
            print(marker, hashlib.sha256(block.encode()).hexdigest(), flush=True)
        print("Controller SHA256:", hashlib.sha256(source.encode()).hexdigest(), flush=True)
        print("State SHA256:", hashlib.sha256((root / STATE).read_bytes()).hexdigest(), flush=True)
        subprocess.run(
            ["xcrun", "swiftc", "-module-cache-path", str(work / "module-cache"),
             str(root / STATE), str(probe), "-o", str(work / "probe")],
            check=True, timeout=60,
        )
        subprocess.run([str(work / "probe")], check=True, timeout=10)


if __name__ == "__main__":
    main()
