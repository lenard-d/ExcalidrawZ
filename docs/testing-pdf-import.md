# PDF import UI tests

The shared `PDFInsertSheet-IsolatedUI` scheme selects only
`ExcalidrawZUITests/PDFInsertSheetUITests`. It leaves the existing schemes unchanged.
The suite has twelve cases: the ten migrated cases and compact native-sheet
Cancel and successful Insert cases. The app fixture compiles only in Debug iOS
simulator builds. No private scheme or test-plan generator is needed.

## Prepare the checkout and isolated configuration

The app needs the ignored `ExcalidrawZ/Resources/excalidraw-latest` directory,
including its complete web build. A fresh checkout does not contain it. Build
the public [ExcalidrawZ core](https://github.com/chocoford/excalidraw/tree/91a3edf6a618da14fb5c04b0e3568b1cbb5991aa)
at the pinned revision below. Use Git, npm and Node.js 22. The core declares Node.js
18 or later; the prepared validation resources used Node.js 22 and Yarn 1.22.22.

Run this block from the ExcalidrawZ checkout root. It prepares a separate temporary
source directory and copies the whole build to the app's exact resource path.
It stops if that destination already exists; inspect and retain an existing
prepared build instead of replacing it.

```sh
(
  set -eu
  PDF_UI_CHECKOUT="$PWD"
  PDF_UI_WEB_DEST="$PDF_UI_CHECKOUT/ExcalidrawZ/Resources/excalidraw-latest"
  test -f "$PDF_UI_CHECKOUT/ExcalidrawZ.xcodeproj/project.pbxproj"
  test ! -e "$PDF_UI_WEB_DEST"
  PDF_UI_WEB_WORK=$(mktemp -d "${TMPDIR:-/tmp}/excalidrawz-pdf-resources.XXXXXX")
  git clone --branch ExcalidrawZ-core \
    https://github.com/chocoford/excalidraw.git "$PDF_UI_WEB_WORK/core"
  git -C "$PDF_UI_WEB_WORK/core" checkout --detach \
    91a3edf6a618da14fb5c04b0e3568b1cbb5991aa
  npm install --prefix "$PDF_UI_WEB_WORK/tools" --no-audit --no-fund yarn@1.22.22
  export PATH="$PDF_UI_WEB_WORK/tools/node_modules/.bin:$PATH"
  cd "$PDF_UI_WEB_WORK/core"
  HUSKY=0 yarn install --frozen-lockfile --non-interactive
  yarn workspace excalidraw-app build:app:docker
  yarn workspace excalidraw-app build:version
  test -f excalidraw-app/build/index.html
  test -f excalidraw-app/build/version.json
  ditto excalidraw-app/build "$PDF_UI_WEB_DEST"
  git -C "$PDF_UI_CHECKOUT" check-ignore \
    ExcalidrawZ/Resources/excalidraw-latest/index.html
)
```

The Docker-named build script runs Vite locally with Sentry disabled. It does not
require Docker. Preserve the core's `yarn.lock` and the app's `Package.resolved`.
Keep the generated resources and tool installation out of Git. This resource
procedure was used for the prepared validation build; the PDF test fixture
itself uses only an in-memory synthetic PDF.

Create the minimal local `Config/Secrets.plist` described in the
[development guide](../README.md#development-guide) only if it is absent. Use only
the placeholder `COLLAB_URL=https://example.com`, without provider credentials,
for these tests. Do not copy an existing private Secrets file.

Use an isolated validation checkout with configured runtime cloud identifiers
and build-time CloudKit disabling. Until those changes are part of main, the
source prerequisites are [configured cloud identifiers](https://github.com/lenard-d/ExcalidrawZ/pull/3)
and [the build-time CloudKit gate](https://github.com/lenard-d/ExcalidrawZ/pull/10).
This PDF test branch does not include them. Its launch argument
`-DisableCloudSync YES` alone is not a substitute for startup isolation.

Prepare an external simulator identity xcconfig and local Info/entitlement
copies. Keep their paths, identifiers, signing values and secrets out of Git.
The external configuration must supply:

| Setting or artifact | Required local value |
|---|---|
| `PRODUCT_BUNDLE_IDENTIFIER` | Distinct test identifiers for the app and test targets, separate from installed apps. Preserve the app-prefix relationship for any embedded extension. |
| App display name | A distinct test name. |
| `INFOPLIST_FILE` | Local app Info copy, preserving document types. Set `ExcalidrawZCloudKitEnabled` to a typed Boolean false and `ExcalidrawZICloudContainerIdentifier` to your test container. Remove provider callback/query schemes. |
| App Group | A separate test group, or remove the app's group Info key and group entitlement together to select standard defaults. |
| `CODE_SIGN_ENTITLEMENTS` | Local simulator entitlements. Do not retain production cloud, group or shared Keychain access. For the local drawing variant, the custom app entitlement dictionary can be empty. |
| Simulator signing | Use local simulator signing settings. No development team or provisioning changes are needed for an ad hoc simulator build. |
| UI test host | `TEST_TARGET_NAME = ExcalidrawZ` for the UI-test target. The project currently has a differently capitalized host name. |

Create an external wrapper xcconfig with the following test-only settings. Replace
the include path with your audited local identity configuration:

```xcconfig
#include "/absolute/path/to/isolated-simulator-identity.xcconfig"
PDF_UI_HOST_ExcalidrawZUITests = ExcalidrawZ
TEST_TARGET_NAME = $(PDF_UI_HOST_$(TARGET_NAME:c99extidentifier):default=$(inherited))
EXCALIDRAWZ_ISOLATED_UI_TESTS = 1
```

The scheme reads the last setting into the **test runner's** environment.
Without it, setup fails rather than skipping the suite. The value is an explicit
opt-in, not an identity audit. The tests separately set the app's PDF fixture
launch environment. Do not enable the fixture in a physical or release build.

Use a dedicated iPad simulator with no Apple Account or real drawings. A
12.9-inch iPad in portrait gives the fixed 1024-by-768 and 768-by-1024 viewports
enough room. An existing audited synthetic simulator can be reused. Preserve its
data; do not erase it or reset its defaults.

## Build, audit, then run

Set these variables to your local paths and audited simulator UUID. Use a new
output directory for each build. Run only after obtaining the shared native
build/test queue.

```sh
PDF_UI_SIMULATOR_ID='YOUR_AUDITED_IPAD_SIMULATOR_UUID'
PDF_UI_XCCONFIG='/absolute/path/to/pdf-ui-wrapper.xcconfig'
PDF_UI_DERIVED_DATA='/absolute/path/to/new/pdf-ui/DerivedData'
PDF_UI_RESULT='/absolute/path/to/new/pdf-ui/Results/PDF-Import'

xcodebuild -project ExcalidrawZ.xcodeproj \
  -scheme PDFInsertSheet-IsolatedUI \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$PDF_UI_SIMULATOR_ID" \
  -derivedDataPath "$PDF_UI_DERIVED_DATA" \
  -xcconfig "$PDF_UI_XCCONFIG" \
  -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO \
  build-for-testing
```

Before any app or test launch, inspect the actual built app and runner:
their bundle IDs, display name, resolved Info keys, signed entitlements,
Keychain identity and simulator storage must match the isolated configuration.
Check any embedded extension too. The iOS local drawing variant must not embed
the macOS Quick Look extension. A different app bundle ID alone is not a full
audit. Do not run a Mac app or app-hosted Mac tests.

Find the generated `.xctestrun` under
`$PDF_UI_DERIVED_DATA/Build/Products` and set its exact path:

```sh
PDF_UI_XCTESTRUN='/absolute/path/to/generated/PDFInsertSheet-IsolatedUI_iphonesimulator.xctestrun'
plutil -p "$PDF_UI_XCTESTRUN"
```

Inspect the PDF UI target entry. Its runner `EnvironmentVariables` must contain
`EXCALIDRAWZ_ISOLATED_UI_TESTS = 1`, its host must be the audited test app,
and its selected tests must be `PDFInsertSheetUITests`. Other UI classes must
not be selected. Xcode can store this entry at the top level in format 1 or in
`TestConfigurations[].TestTargets[]` in format 2. A shell environment value or a
late build setting does not change an already saved runner file. If its values
are wrong, correct the local configuration and rebuild before running.

After these audits, run all twelve cases serially on the same simulator:

```sh
xcodebuild test-without-building \
  -xctestrun "$PDF_UI_XCTESTRUN" \
  -destination "platform=iOS Simulator,id=$PDF_UI_SIMULATOR_ID" \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ExcalidrawZUITests/PDFInsertSheetUITests \
  -resultBundlePath "$PDF_UI_RESULT"
```

The explicit class filter also excludes the template launch tests. Keep the
build and test logs and result bundle. Check that twelve PDF cases ran; report
failures rather than replacing assertions, excluding cases or adding skips.

## What the tests prove

The tests tap the production sheet's named controls. Insert checks compare the
source and received PDF SHA-256 digest, four-page count, exact options and
callback count. Both regular and compact native sheets check actual dismissal
after Insert or Cancel. Cancel must produce no callback data or options.

Compact native cases constrain the real sheet content to 320 by 768 points and
inject the compact environment. They do not prove the operating system selected
that size class. The fixture does not test normal file selection, insertion into
a drawing, live rotation, Split View transitions or physical iPad behavior.
Hittable buttons do not prove that every caption is readable.
