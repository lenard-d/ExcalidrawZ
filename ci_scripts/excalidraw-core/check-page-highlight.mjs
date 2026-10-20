import assert from "node:assert/strict";
import {
  mkdtempSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const corePath = process.env.EXCALIDRAWZ_CORE_PATH;
assert.ok(
  corePath,
  "Set EXCALIDRAWZ_CORE_PATH to the prepared pinned core source checkout"
);
const source = realpathSync(corePath);
const output = realpathSync(
  mkdtempSync(path.join(os.tmpdir(), "excalidrawz-page-highlight-"))
);
const sourceURL = (relative) => JSON.stringify(path.join(source, relative));

try {
  symlinkSync(
    path.join(source, "node_modules"),
    path.join(output, "node_modules"),
    "dir"
  );
  writeFileSync(
    path.join(output, "highlight.test.tsx"),
    `
import React from "react";
import { vi } from "vitest";
import { newFrameElement } from "@excalidraw/element";
import { Excalidraw } from ${sourceURL("packages/excalidraw/index.tsx")};
import { API } from ${sourceURL("packages/excalidraw/tests/helpers/api.ts")};
import { GlobalTestState, render, unmountComponent, waitFor } from ${sourceURL(
      "packages/excalidraw/tests/test-utils.ts"
    )};

beforeEach(async () => { await render(<Excalidraw />); });
afterEach(() => { unmountComponent(); vi.restoreAllMocks(); });

const pageTag = { excalidrawZPage: { version: 1, order: 0, layout: "blank" } };
const cases = [
  { name: "tagged page freedraw", customData: pageTag, tool: "freedraw", blue: false },
  { name: "tagged page shape", customData: pageTag, tool: "diamond", blue: false },
  { name: "ordinary frame writing", customData: {}, tool: "freedraw", blue: true },
  { name: "tagged page selection/drop", customData: pageTag, tool: "selection", blue: true },
  { name: "unknown page version", customData: { excalidrawZPage: { version: 2 } }, tool: "freedraw", blue: true },
] as const;

test.each(cases)("$name uses the correct interactive border", async ({ customData, tool, blue }) => {
  const frame = newFrameElement({ x: 0, y: 0, width: 300, height: 200, customData });
  API.updateScene({ elements: [frame] });
  const context = GlobalTestState.interactiveCanvas.getContext("2d");
  if (!context) throw new Error("Interactive canvas context is unavailable");
  const strokes: string[] = [];
  const clear = vi.spyOn(context, "clearRect");
  const record = () => { strokes.push(String(context.strokeStyle).replaceAll(" ", "").toLowerCase()); };
  vi.spyOn(context, "stroke").mockImplementation(record);
  vi.spyOn(context, "strokeRect").mockImplementation(record);
  API.setAppState({
    activeTool: { type: tool, locked: false, lastActiveTool: null, fromSelection: false },
    frameToHighlight: frame,
  });
  await waitFor(() => expect(clear).toHaveBeenCalled());
  expect(strokes.some(color => color.includes("#0076ff") || color.includes("0,118,255"))).toBe(blue);
});
`
  );
  const config = path.join(output, "vitest.config.mjs");
  writeFileSync(
    config,
    `
import base from ${sourceURL("vitest.config.mts")};
export default { ...base, root: ${JSON.stringify(
      output
    )}, cacheDir: ${JSON.stringify(path.join(output, "cache"))},
  test: { ...base.test, setupFiles: [${JSON.stringify(
    path.join(source, "setupTests.ts")
  )}],
    include: ["highlight.test.tsx"], maxWorkers: 1, minWorkers: 1 } };
`
  );
  const result = spawnSync(
    process.execPath,
    [
      path.join(source, "node_modules/vitest/vitest.mjs"),
      "run",
      "--config",
      config,
    ],
    {
      cwd: source,
      stdio: "inherit",
      timeout: 60000,
    }
  );
  if (result.error) throw result.error;
  process.exitCode = result.status ?? 1;
} finally {
  rmSync(output, { recursive: true, force: true });
}
