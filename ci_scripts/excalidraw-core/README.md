# Local core patches

Use the public `chocoford/excalidraw` repository at
`91a3edf6a618da14fb5c04b0e3568b1cbb5991aa`. Keep its lockfile unchanged.
Apply the tracked patches to a clean checkout before building the native app's
ignored web resources. Patch 0001 makes Pen input mode independent of tool lock.
Patch 0002 removes writing-target feedback only for tagged pages. Patch 0003
removes web controls supplied by the full-width native iPad bar and preserves
the Style panel state.

From that core checkout, with Node.js 22 and Yarn 1.22.22 available:

```sh
for patch in "$NATIVE_CHECKOUT"/ci_scripts/excalidraw-core/000*.patch; do
  git apply --check "$patch" && git apply "$patch" || exit 1
done
HUSKY=0 yarn install --frozen-lockfile --non-interactive
EXCALIDRAWZ_CORE_PATH="$PWD" node --experimental-vm-modules --test \
  "$NATIVE_CHECKOUT/ci_scripts/excalidraw-core/check-pen-mode.mjs" \
  "$NATIVE_CHECKOUT/ci_scripts/excalidraw-core/check-native-ipad-controls.mjs"
EXCALIDRAWZ_CORE_PATH="$PWD" node \
  "$NATIVE_CHECKOUT/ci_scripts/excalidraw-core/check-page-highlight.mjs"
yarn workspace excalidraw-app build:app:docker
yarn workspace excalidraw-app build:version
```

Copy the whole `excalidraw-app/build` directory to
`ExcalidrawZ/Resources/excalidraw-latest` in an isolated native build checkout.
Do not replace an existing prepared resource directory without retaining its
source and hashes. Record SHA-256 hashes for every generated file and compare
them with the files in the signed app. Generated assets stay outside Git.
Keep one composed build procedure for later patches.
