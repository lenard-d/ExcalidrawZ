# Local core patches

Use the public `chocoford/excalidraw` repository at
`91a3edf6a618da14fb5c04b0e3568b1cbb5991aa`. Keep its lockfile unchanged.
Apply the tracked patches to a clean checkout before building the native app's
ignored web resources. Patch 0001 makes Pen input mode independent of tool lock.
Patch 0002 removes writing-target feedback only for tagged pages. Patch 0003
removes web controls supplied by the full-width native iPad bar and preserves
the Style panel state. Patch 0004 adds native proportional corner resizing and
free edge resizing for tagged pages, and reflows their paper guides.
Patch 0005 adds a coalesced finalized-content hint to the existing watcher.
It requests the native scheduler and does not save from a pointer event.
It waits for 1000ms of quiet after a finalized scene update. Ordinary web
notifications keep their 1s throttle, and active-input full snapshots keep
their 5s interval. A separated burst can add one trailing snapshot and write.
This is not a hard durable-save deadline. Instrumented simulator baselines
measured about 0.55s per 10000-element snapshot and 1.1s for its final save and
element-readback path. Candidate timing and input cost still need native checks.

From that core checkout, with Node.js 22 and Yarn 1.22.22 available:

```sh
for patch in "$NATIVE_CHECKOUT"/ci_scripts/excalidraw-core/000*.patch; do
  git apply --check "$patch" && git apply "$patch" || exit 1
done
HUSKY=0 yarn install --frozen-lockfile --non-interactive
EXCALIDRAWZ_CORE_PATH="$PWD" node --experimental-vm-modules --test \
  "$NATIVE_CHECKOUT/ci_scripts/excalidraw-core/check-pen-mode.mjs" \
  "$NATIVE_CHECKOUT/ci_scripts/excalidraw-core/check-native-ipad-controls.mjs"
EXCALIDRAWZ_CORE_PATH="$PWD" node --experimental-vm-modules --test \
  "$NATIVE_CHECKOUT/ci_scripts/excalidraw-core/check-completed-content-save.mjs"
EXCALIDRAWZ_CORE_PATH="$PWD" node \
  "$NATIVE_CHECKOUT/ci_scripts/excalidraw-core/check-page-highlight.mjs"
EXCALIDRAWZ_CORE_PATH="$PWD" node \
  "$NATIVE_CHECKOUT/ci_scripts/excalidraw-core/check-page-resize.mjs"
yarn workspace excalidraw-app build:app:docker
yarn workspace excalidraw-app build:version
```

Copy the whole `excalidraw-app/build` directory to
`ExcalidrawZ/Resources/excalidraw-latest` in an isolated native build checkout.
Do not replace an existing prepared resource directory without retaining its
source and hashes. Record SHA-256 hashes for every generated file and compare
them with the files in the signed app. Generated assets stay outside Git.
Keep one composed build procedure for later patches.

The completion check applies patch 0005 to a temporary copy of the pinned
watcher. It runs the full watcher with its real throttle and message adapter.
Other feature imports are inert. It does not run the renderer, WebKit or a
native saver. The prepared core and generated resources stay unchanged.
