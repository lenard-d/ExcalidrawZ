"""Exercise the actual app-state saver with a held viewport preparation and real save admission."""

import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ENGINE = "ExcalidrawZ/ExcalidrawView/Engine/"
SAVER = ENGINE + "Snapshot/ExcalidrawDocumentAppStateSnapshotSaver.swift"
BRIDGE = ENGINE + "ExcalidrawCore/Helpers/ExcalidrawCore+JavaScriptBridge.swift"
DEPENDENCIES = (
    SAVER,
    ENGINE + "Snapshot/ExcalidrawDocumentAppStatePersistence.swift",
    "ExcalidrawZ/Utils/FileSyncCoordinator/CanvasSaveCoordinator.swift",
    "ExcalidrawZ/Utils/FileSyncCoordinator/OwnedCanvasMutationCoordinator.swift",
    "ExcalidrawZ/Utils/FileSyncCoordinator/ExternalFileSaveCoordinator.swift",
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


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", help="Read immutable source instead of working files")
    args = parser.parse_args()

    def read(path: str) -> str:
        if args.revision:
            return subprocess.check_output(["git", "show", f"{args.revision}:{path}"], cwd=ROOT, text=True)
        return (ROOT / path).read_text()

    json_value = extract_block(read(BRIDGE), "enum JSONValue:")
    template = Path(__file__).with_name("AppStateCancellationProbe.swift").read_text()
    generated = template.replace("// INSERT JSON VALUE", json_value)
    print("JSONValue", hashlib.sha256(json_value.encode()).hexdigest(), flush=True)
    with tempfile.TemporaryDirectory(prefix="excalidrawz-app-state-cancellation-") as directory:
        work = Path(directory)
        probe = work / "probe.swift"
        probe.write_text(generated)
        sources = []
        for path in DEPENDENCIES:
            content = read(path)
            target = work / Path(path).name
            target.write_text(content)
            sources.append(str(target))
            print(path, hashlib.sha256(content.encode()).hexdigest(), flush=True)
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(work / "cache"),
                        *sources, str(probe), "-o", str(work / "probe")], check=True, timeout=60)
        subprocess.run([str(work / "probe")], check=True, timeout=20)


if __name__ == "__main__":
    main()
