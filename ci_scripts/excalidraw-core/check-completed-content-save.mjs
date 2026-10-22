import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import vm from "node:vm";

const core = process.env.EXCALIDRAWZ_CORE_PATH;
assert.ok(core, "Set EXCALIDRAWZ_CORE_PATH to the read-only pinned core checkout");
const directory = path.dirname(fileURLToPath(import.meta.url));
const relative = "excalidraw-app/excalidrawZ/index.js";
const pinned = "91a3edf6a618da14fb5c04b0e3568b1cbb5991aa";
const original = execFileSync("git", ["-C", core, "show", `${pinned}:${relative}`], { encoding: "utf8" });
const temporary = mkdtempSync(path.join(os.tmpdir(), "excalidrawz-completion-check-"));
let source;
try {
  mkdirSync(path.join(temporary, path.dirname(relative)), { recursive: true });
  writeFileSync(path.join(temporary, relative), original);
  execFileSync("git", ["apply", "--check", path.join(directory, "0005-coalesce-completed-content-save.patch")], { cwd: temporary });
  execFileSync("git", ["apply", path.join(directory, "0005-coalesce-completed-content-save.patch")], { cwd: temporary });
  source = readFileSync(path.join(temporary, relative), "utf8");
} finally {
  rmSync(temporary, { recursive: true, force: true });
}

// Load the complete patched watcher, real throttle and real native-message adapter.
// Other imported features are inert; no Excalidraw renderer or native saver runs here.
async function editor() {
  let now = 10000;
  let timerID = 0;
  const timers = new Map();
  const messages = [];
  let rejectMessage = false;
  let localViewer = false;
  let changes;
  let elements = [];
  let state = { cursorButton: "up", newElement: null };
  const window = {
    addEventListener() {},
    webkit: { messageHandlers: { excalidrawZ: {
      postMessage(message) {
        if (rejectMessage) throw new Error("Synthetic bridge failure");
        messages.push(structuredClone(message));
      },
    } } },
  };
  const context = vm.createContext({
    window, document: { addEventListener() {} },
    Date: class extends Date { static now() { return now; } },
    performance: { now: () => now },
    setTimeout(callback, delay) {
      const id = ++timerID;
      timers.set(id, { callback, at: now + delay });
      return id;
    },
    clearTimeout(id) { timers.delete(id); },
    console: { info() {}, warn() {}, error() {} },
  });
  const real = new Map();
  const module = new vm.SourceTextModule(source, { context, identifier: relative });
  await module.link((specifier) => {
    if (["./_helpers", "./message"].includes(specifier)) {
      if (!real.has(specifier)) {
        const dependency = execFileSync("git", ["-C", core, "show", `${pinned}:excalidraw-app/excalidrawZ/${specifier.slice(2)}.js`], { encoding: "utf8" });
        real.set(specifier, new vm.SourceTextModule(dependency, { context }));
      }
      return real.get(specifier);
    }
    const match = [...source.matchAll(/import\s*\{([^}]+)\}\s*from\s*"([^"]+)"/g)].find((match) => match[2] === specifier);
    const names = match ? match[1].split(",").map((name) => name.trim()).filter(Boolean) : [];
    return new vm.SyntheticModule(names, function () {
      for (const name of names) this.setExport(name, name === "isLocalViewer" ? () => localViewer : () => {});
    }, { context });
  });
  await module.evaluate();
  const helper = window.excalidrawZHelper;
  helper.currentFileId = "synthetic-owner";
  helper._api = {
    onChange(callback) { changes = callback; },
    getSceneElementsIncludingDeleted: () => elements,
    getAppState: () => state,
  };
  helper.startWatchExcalidrawState();
  return {
    helper,
    messages: () => messages.map((message) => message.data.data),
    emit(nextElements, updates = {}) {
      elements = nextElements;
      state = { ...state, ...updates };
      changes(elements, state);
    },
    advance(duration) {
      const target = now + duration;
      let remainingCallbacks = 10000;
      while (true) {
        const due = [...timers].filter(([, timer]) => timer.at <= target).sort((a, b) => a[1].at - b[1].at || a[0] - b[0])[0];
        if (!due) break;
        assert.ok(remainingCallbacks-- > 0, "Timer drain must make bounded progress");
        timers.delete(due[0]);
        now = due[1].at;
        due[1].callback();
      }
      now = target;
    },
    rejectBridge(value) { rejectMessage = value; },
    setLocalViewer(value) { localViewer = value; },
  };
}

const element = (version) => ({ id: "stroke", version, versionNonce: version });
const completions = (page) => page.messages().filter((message) => message.completedContentRevision != null);

test("An already-reported final scene still emits one timing-only completion", async () => {
  const page = await editor();
  page.emit([element(1)], { cursorButton: "down", newElement: element(1) });
  page.advance(1100);
  page.emit([element(2)], { cursorButton: "up", newElement: null });
  const content = page.messages().at(-1);
  assert.equal(content.contentDirty, true);
  page.advance(999);
  assert.equal(completions(page).length, 0);
  page.advance(1);
  const completion = completions(page);
  assert.equal(completion.length, 1);
  assert.equal(completion[0].completedContentRevision, content.revision);
  assert.equal(completion[0].contentDirty, false);
  assert.equal(completion[0].appStateDirty, false);
  page.advance(10000);
  assert.equal(completions(page).length, 1);
});

test("A later finalized update restarts the exact1000ms quiet window", async () => {
  const page = await editor();
  page.emit([element(1)]);
  page.advance(500);
  page.emit([element(2)]);
  page.advance(499);
  assert.equal(completions(page).length, 0);
  page.advance(1);
  assert.equal(page.messages().filter((message) => message.contentDirty).length, 2);
  page.advance(499);
  assert.equal(completions(page).length, 0);
  page.advance(1);
  assert.equal(completions(page).length, 1);
  assert.equal(completions(page)[0].completedContentRevision, page.messages().filter((message) => message.contentDirty).at(-1).revision);
});

test("Ordinary leading and trailing delivery keep the exact1000ms cadence", async () => {
  const page = await editor();
  const active = { cursorButton: "down", newElement: element(1) };
  page.emit([element(1)], active);
  assert.equal(page.messages().length, 1);
  page.advance(100);
  page.emit([element(2)], active);
  page.advance(899);
  assert.equal(page.messages().length, 1);
  page.advance(1);
  assert.equal(page.messages().length, 2);
  page.emit([element(3)], active);
  page.advance(999);
  assert.equal(page.messages().length, 2);
  page.advance(1);
  assert.equal(page.messages().length, 3);
  assert.equal(completions(page).length, 0);
});

test("Resumed app-state-only contact immediately withdraws a posted completion once", async () => {
  const page = await editor();
  page.emit([element(1)]);
  page.advance(1000);
  assert.equal(completions(page).length, 1);
  const withdrawals = () => page.messages().filter((message) => message.contentInteractionActive && !message.contentDirty && !message.appStateDirty);
  page.emit([element(1)], { cursorButton: "down" });
  assert.equal(withdrawals().length, 1);
  assert.equal(withdrawals()[0].completedContentRevision, undefined);
  page.emit([element(1)], { cursorButton: "down" });
  assert.equal(withdrawals().length, 1);
  page.advance(1000);
  assert.equal(completions(page).length, 1);
  page.emit([element(1)], { cursorButton: "up" });
  page.advance(999);
  assert.equal(completions(page).length, 1);
  page.advance(1);
  assert.equal(completions(page).length, 2);
  assert.equal(completions(page)[1].completedContentRevision, completions(page)[0].completedContentRevision);
});

test("Continuous contact retains ordinary cadence and has no premature completion", async () => {
  const page = await editor();
  for (let version = 1; version <= 100; version++) {
    page.emit([element(version)], { cursorButton: "down", newElement: element(version) });
    page.advance(100);
  }
  assert.equal(completions(page).length, 0);
  assert.ok(page.messages().length <= 11);
  page.emit([element(101)], { cursorButton: "up", newElement: null });
  page.advance(2000);
  assert.equal(completions(page).length, 1);
  assert.equal(page.messages().filter((message) => message.contentDirty).at(-1).elementCount, 1);
});

test("Resumed input cancels the quiet request and coalesces the latest completion", async () => {
  const page = await editor();
  page.emit([element(1)]);
  page.advance(800);
  page.emit([element(2)], { cursorButton: "down", newElement: element(2) });
  page.advance(1500);
  assert.equal(completions(page).length, 0);
  page.emit([element(3)], { cursorButton: "up", newElement: null });
  page.advance(2000);
  assert.equal(completions(page).length, 1);
  assert.equal(completions(page)[0].completedContentRevision, page.messages().filter((message) => message.contentDirty).at(-1).revision);
});

for (const active of ["editingTextElement", "multiElement", "resizingElement", "isResizing", "isRotating"]) {
  test(`Completion waits for ${active} to finish`, async () => {
    const page = await editor();
    page.emit([element(1)], { [active]: true });
    page.advance(2000);
    assert.equal(completions(page).length, 0);
    page.emit([element(2)], { [active]: null });
    page.advance(2000);
    assert.equal(completions(page).length, 1);
  });
}

test("Selection and camera-only changes never request a content completion", async () => {
  const page = await editor();
  page.emit([], { scrollX: 20, selectedElementIds: {} });
  page.advance(2000);
  assert.equal(completions(page).length, 0);
});

test("Suppression and same-file reload discard the previous scene's quiet request", async () => {
  const page = await editor();
  page.emit([element(1)]);
  const end = page.helper._beginStateChangeSuppression();
  page.advance(2000);
  assert.equal(completions(page).length, 0);
  end();
  page.emit([element(1)]);
  page.advance(2000);
  assert.equal(completions(page).length, 0);
});

test("Owner change discards a queued completion", async () => {
  const page = await editor();
  page.emit([element(1)]);
  page.helper.currentFileId = "different-owner";
  page.advance(2000);
  assert.equal(completions(page).length, 0);
});

test("Entering local viewer discards a queued completion", async () => {
  const page = await editor();
  page.emit([element(1)]);
  page.setLocalViewer(true);
  page.advance(2000);
  assert.equal(completions(page).length, 0);
});

test("A rejected completion message stays pending for the next quiet update", async () => {
  const page = await editor();
  page.emit([element(1)]);
  const revision = page.messages().at(-1).revision;
  page.rejectBridge(true);
  page.advance(1000);
  assert.equal(completions(page).length, 0);
  page.rejectBridge(false);
  page.emit([element(1)], { scrollX: 10 });
  page.advance(2000);
  assert.equal(completions(page).length, 1);
  assert.equal(completions(page)[0].completedContentRevision, revision);
});

test("Hot updates scan element signatures only at the existing ordinary cadence", async () => {
  const page = await editor();
  let reads = 0;
  for (let version = 1; version <= 100; version++) {
    const next = { ...element(version), get id() { reads += 1; return "stroke"; } };
    page.emit([next], { cursorButton: "down", newElement: element(version) });
    page.advance(100);
  }
  assert.ok(reads <= 11, `Read ${reads} signatures for100 updates`);
  assert.equal(completions(page).length, 0);
});

test("A rejected initial dirty message is retried as dirty content, not just a hint", async () => {
  const page = await editor();
  page.rejectBridge(true);
  page.emit([element(1)]);
  page.advance(1000);
  assert.equal(page.messages().length, 0);
  page.rejectBridge(false);
  page.emit([element(1)]);
  page.advance(2000);
  const dirty = page.messages().find((message) => message.contentDirty);
  assert.ok(dirty);
  assert.equal(completions(page).length, 1);
  assert.equal(completions(page)[0].completedContentRevision, dirty.revision);
});
