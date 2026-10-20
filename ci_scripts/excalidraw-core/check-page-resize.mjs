import assert from "node:assert/strict";
import {
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

assert.ok(
  process.env.EXCALIDRAWZ_CORE_PATH,
  "Set EXCALIDRAWZ_CORE_PATH to the prepared pinned core source"
);
const source = realpathSync(process.env.EXCALIDRAWZ_CORE_PATH);
const output = realpathSync(
  mkdtempSync(path.join(os.tmpdir(), "excalidrawz-page-resize-"))
);
const sourceURL = (relative) => JSON.stringify(path.join(source, relative));
const project = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../.."
);
const sceneSource = readFileSync(
  path.join(
    project,
    "ExcalidrawZ/ExcalidrawView/PageMode/PageModeSceneScript.swift"
  ),
  "utf8"
);
const sceneBody = sceneSource.match(/#"""([\s\S]*?)"""/)?.[1];
assert.ok(sceneBody, "The actual Pages scene command must be available");

try {
  symlinkSync(
    path.join(source, "node_modules"),
    path.join(output, "node_modules"),
    "dir"
  );
  writeFileSync(
    path.join(output, "resize.test.tsx"),
    `
import React from "react";
import { arrayToMap } from "@excalidraw/common";
import { getTransformHandles } from "@excalidraw/element";
import { Excalidraw } from ${sourceURL("packages/excalidraw/index.tsx")};
import { API } from ${sourceURL("packages/excalidraw/tests/helpers/api.ts")};
import { UI, Keyboard, Pointer } from ${sourceURL(
      "packages/excalidraw/tests/helpers/ui.ts"
    )};
import { act, render, unmountComponent, waitFor } from ${sourceURL(
      "packages/excalidraw/tests/test-utils.ts"
    )};
import { createElements } from ${sourceURL(
      "excalidraw-app/excalidrawZ/creators.js"
    )};
import { addElements } from ${sourceURL(
      "excalidraw-app/excalidrawZ/elements.js"
    )};
import { restoreElements } from ${sourceURL(
      "packages/excalidraw/data/restore.ts"
    )};
import { serializeAsJSON } from ${sourceURL(
      "packages/excalidraw/data/json.ts"
    )};
import { exportScene } from ${sourceURL("packages/excalidraw/scene/export.ts")};

const { h } = window;
const command = new Function("window", "expectedFileID", "commandJSON", ${JSON.stringify(
      sceneBody
    )});
beforeEach(async () => {
  await render(<Excalidraw handleKeyboardGlobally={true} />);
  API.setAppState({ width: 1200, height: 1200 });
  window.excalidrawZHelper = { currentFileId: "synthetic", createElements, addElements,
    _api: { getSceneElementsIncludingDeleted: () => h.elements,
      getAppState: () => h.state, getFiles: () => ({}), updateScene: API.updateScene,
      mutateElement: (element, updates) => h.app.scene.mutateElement(element, updates, { informMutation: false, isDragging: false }) } };
});
afterEach(() => { unmountComponent(); delete window.excalidrawZHelper; });
function run(value) {
  let result;
  act(() => { result = JSON.parse(command(window, "synthetic", JSON.stringify(value))); });
  return result;
}
function createPage(layout = "grid") {
  const id = run({ action: "add", title: "Notes", width: 300, height: 400, layout }).openedPageID;
  return h.elements.find(element => element.id === id);
}
function current(id) { return h.elements.find(element => element.id === id); }
function guides(page, elements = h.elements) {
  return elements.filter(element => !element.isDeleted && element.type === "line" && element.frameId === page.id && element.customData?.excalidrawZPageGuide?.version === 1);
}
function assertPaper(page, elements = h.elements) {
  const lines = guides(page, elements);
  expect(lines.length).toBeGreaterThan(0);
  for (const line of lines) {
    expect(line.frameId).toBe(page.id);
    if (line.width > 0) {
      expect(line.x).toBeCloseTo(page.x);
      expect(line.width).toBeCloseTo(page.width);
      expect(line.points).toEqual([[0, 0], [page.width, 0]]);
      expect(line.y).toBeGreaterThan(page.y);
      expect(line.y).toBeLessThan(page.y + page.height);
    } else {
      expect(line.y).toBeCloseTo(page.y);
      expect(line.height).toBeCloseTo(page.height);
      expect(line.points).toEqual([[0, 0], [0, page.height]]);
      expect(line.x).toBeGreaterThan(page.x);
      expect(line.x).toBeLessThan(page.x + page.width);
    }
  }
  const horizontal = lines.filter(line => line.width > 0).sort((a,b) => a.y-b.y);
  const vertical = lines.filter(line => line.height > 0).sort((a,b) => a.x-b.x);
  // Paper must reach the far end, including pages with a previously stale background.
  expect(horizontal.at(-1).y).toBeGreaterThan(page.y + page.height * 0.9);
  if (vertical.length) expect(vertical.at(-1).x).toBeGreaterThan(page.x + page.width * 0.9);
}
const geometry = element => ({ x: element.x, y: element.y, width: element.width, height: element.height, points: element.points });

test.each(["grid", "ruled"])("native proportional corner resize scales %s paper and preserves ink", layout => {
  const page = createPage(layout);
  const ink = API.createElement({ type: "diamond", x: 30, y: 40, width: 80, height: 60, frameId: page.id });
  API.updateScene({ elements: [...h.elements.slice(0, -1), ink, page] });
  const before = geometry(ink);
  const ids = guides(page).map(line => line.id);
  UI.resize(page, "se", [100, 100]);
  expect(page.width / page.height).toBeCloseTo(0.75);
  expect(page.width).toBeGreaterThan(300);
  assertPaper(page);
  expect(guides(page).map(line => line.id)).toEqual(ids);
  expect(geometry(current(ink.id))).toEqual(before);
});

test("native Shift corner is free, edge is free, Shift edge is proportional", () => {
  const page = createPage();
  UI.resize(page, "se", [100, 100], { shift: true });
  expect(page.width).toBeCloseTo(400);
  expect(page.height).toBeCloseTo(500);
  UI.resize(page, "e", [80, 0]);
  expect(page.width).toBeCloseTo(480);
  expect(page.height).toBeCloseTo(500);
  UI.resize(page, "e", [96, 0], { shift: true });
  expect(page.width / page.height).toBeCloseTo(480 / 500);
  assertPaper(page);
});

test("touch uses the existing page edge handle and performs free resize", () => {
  const page = createPage();
  API.setAppState({ selectedElementIds: { [page.id]: true } });
  const handles = getTransformHandles(page, h.state.zoom, arrayToMap(h.elements), "touch");
  for (const direction of ["n", "s", "e", "w"]) expect(handles[direction]).toBeDefined();
  expect(handles.rotation).toBeUndefined();
  const edge = handles.e;
  const touch = new Pointer("touch");
  act(() => { touch.downAt(edge[0] + edge[2]/2, edge[1] + edge[3]/2); touch.move(100, 0); touch.up(); });
  expect(page.width).toBeCloseTo(400);
  expect(page.height).toBeCloseTo(400);
  assertPaper(page);
});

test.each([undefined, { excalidrawZPage: { version: 2 } }])("ordinary and unknown frame behavior remains unchanged", customData => {
  const frame = API.createElement({ type: "frame", x: 0, y: 0, width: 300, height: 400, customData });
  API.updateScene({ elements: [frame] });
  const handles = getTransformHandles(frame, h.state.zoom, arrayToMap(h.elements), "touch");
  expect(handles.e).toBeUndefined();
  UI.resize(frame, "se", [100, 100]);
  expect(frame.width).toBeCloseTo(400);
  expect(frame.height).toBeCloseTo(500);
});

test("native resize repairs an old partial background and does not touch other pages", () => {
  const page = createPage();
  API.updateElement(page, { width: 600, height: 800 });
  const other = createPage("ruled");
  const otherBefore = h.elements.filter(element => element.id === other.id || element.frameId === other.id).map(element => JSON.stringify(element));
  UI.resize(page, "se", [60, 80]);
  assertPaper(current(page.id));
  expect(h.elements.filter(element => element.id === other.id || element.frameId === other.id).map(element => JSON.stringify(element))).toEqual(otherBefore);
});

test("shrinking keeps all ink data and does not resize edited or unknown guide lines", () => {
  const page = createPage();
  const lines = guides(page);
  API.updateElement(lines[0], { locked: false });
  API.updateElement(lines[1], { customData: { excalidrawZPageGuide: { version: 2 } } });
  const ink = API.createElement({ type: "diamond", x: 230, y: 330, width: 50, height: 50, frameId: page.id });
  API.updateScene({ elements: [...h.elements.slice(0, -1), ink, page] });
  const before = [lines[0], lines[1], ink].map(element => [element.id, geometry(element)]);
  UI.resize(page, "se", [-100, -100], { shift: true });
  expect(page.width).toBeCloseTo(200);
  expect(page.height).toBeCloseTo(300);
  for (const [id, value] of before) {
    expect(current(id).isDeleted).toBe(false);
    expect(geometry(current(id))).toEqual(value);
  }
});

test("a native resize is one undo step including paper and redo restores both", async () => {
  const page = createPage();
  const before = h.elements.map(element => [element.id, geometry(element)]);
  UI.resize(page, "se", [100, 100]);
  const after = h.elements.map(element => [element.id, geometry(element)]);
  Keyboard.undo();
  await waitFor(() => expect(h.elements.filter(element => !element.isDeleted).map(element => [element.id, geometry(element)])).toEqual(before));
  Keyboard.redo();
  await waitFor(() => expect(h.elements.filter(element => !element.isDeleted).map(element => [element.id, geometry(element)])).toEqual(after));
});

test("native duplicated paper resizes independently, survives serialization and exports with ink", async () => {
  const page = createPage();
  const ink = API.createElement({ type: "diamond", x: 30, y: 40, width: 80, height: 60, frameId: page.id, strokeColor: "#ff0000" });
  API.updateScene({ elements: [...h.elements.slice(0, -1), ink, page] });
  API.setAppState({ selectedElementIds: { [page.id]: true } });
  Keyboard.withModifierKeys({ ctrl: true }, () => Keyboard.keyPress("d"));
  const copy = h.elements.find(element => !element.isDeleted && element.type === "frame" && element.id !== page.id);
  expect(copy).toBeDefined();
  const original = h.elements.filter(element => element.id === page.id || element.frameId === page.id).map(element => JSON.stringify(element));
  UI.resize(copy, "se", [100, 100], { shift: true });
  assertPaper(copy);
  expect(h.elements.filter(element => element.id === page.id || element.frameId === page.id).map(element => JSON.stringify(element))).toEqual(original);
  const json = serializeAsJSON(h.elements, h.state, {}, "local");
  const restored = restoreElements(JSON.parse(json).elements, null, { repairBindings: true });
  const restoredPage = restored.find(element => element.id === copy.id);
  assertPaper(restoredPage, restored);
  expect(restoredPage.customData.excalidrawZPage.layout).toBe("grid");
  const svg = await exportScene({ type: "svg", data: { elements: restored, files: {} },
    config: { exportingFrame: restoredPage, environment: { loadFonts: async () => {} } } });
  expect(svg.getAttribute("width")).toBe(String(restoredPage.width));
  expect(svg.getAttribute("height")).toBe(String(restoredPage.height));
  expect(svg.outerHTML).toContain("#b8c5d6");
  expect(svg.outerHTML).toContain("#ff0000");
});
`
  );
  const config = path.join(output, "vitest.config.mjs");
  writeFileSync(
    config,
    `import base from ${sourceURL("vitest.config.mts")};
export default { ...base, root: ${JSON.stringify(
      output
    )}, cacheDir: ${JSON.stringify(path.join(output, "cache"))},
  test: { ...base.test, setupFiles: [${sourceURL(
    "setupTests.ts"
  )}], include: ["resize.test.tsx"], maxWorkers: 1, minWorkers: 1 } };`
  );
  const result = spawnSync(
    process.execPath,
    [
      path.join(source, "node_modules/vitest/vitest.mjs"),
      "run",
      "--config",
      config,
    ],
    { cwd: source, stdio: "inherit", timeout: 90000 }
  );
  if (result.error) throw result.error;
  process.exitCode = result.status ?? 1;
} finally {
  rmSync(output, { recursive: true, force: true });
}
