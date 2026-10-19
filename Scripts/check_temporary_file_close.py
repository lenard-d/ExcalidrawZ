"""Test the exact temporary close action with an isolated transition adapter."""

import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile

SOURCE = "ExcalidrawZ/Sidebar/Temporary/TemporaryFileMenu.swift"


def close_method(source: str) -> str:
    start = source.index("    @MainActor\n", source.index("enum TemporaryFileActions"))
    opening = source.index("{", source.index("static func close(", start))
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
            ["git", "show", f"{revision}:{SOURCE}"], cwd=root, text=True
        )
    return (root / SOURCE).read_text()


def prepare_package(root: Path, work: Path, method: str) -> None:
    (work / "Package.swift").write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "TemporaryCloseProbe", platforms: [.macOS(.v13)], targets: [
    .target(name: "ExcalidrawZ"),
    .testTarget(name: "ExcalidrawZTests", dependencies: ["ExcalidrawZ"])
])
''')
    sources = work / "Sources/ExcalidrawZ"
    sources.mkdir(parents=True)
    template = (root / "Scripts/TemporaryFileCloseScaffold.swift").read_text()
    (sources / "TemporaryClose.swift").write_text(template.replace("// INSERT CLOSE", method))
    tests = work / "Tests/ExcalidrawZTests"
    tests.mkdir(parents=True)
    shutil.copyfile(root / "Scripts/TemporaryFileCloseTests.swift", tests / "TemporaryFileCloseTests.swift")
    shutil.copyfile(root / "ExcalidrawZTests/SaveTestWait.swift", tests / "SaveTestWait.swift")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", help="Test an older action without changing Git")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    source = read_source(root, args.revision)
    method = close_method(source)
    print("Source SHA256:", hashlib.sha256(source.encode()).hexdigest(), flush=True)
    print("Exact close method SHA256:", hashlib.sha256(method.encode()).hexdigest(), flush=True)
    with tempfile.TemporaryDirectory(prefix="excalidrawz-temporary-close-") as directory:
        work = Path(directory)
        prepare_package(root, work, method)
        subprocess.run(
            ["swift", "test", "--package-path", str(work), "--scratch-path", str(work / "build"),
             "--cache-path", str(work / "cache"), "--config-path", str(work / "config"),
             "--security-path", str(work / "security"), "--jobs", "2"],
            check=True, timeout=120,
        )


if __name__ == "__main__":
    main()
