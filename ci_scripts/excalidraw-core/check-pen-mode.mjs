import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import vm from "node:vm";

const corePath = process.env.EXCALIDRAWZ_CORE_PATH;
assert.ok(corePath, "Set EXCALIDRAWZ_CORE_PATH to the pinned core source checkout");

async function browser({ locked = false, storedState } = {}) {
  const state = { activeTool: { type: "selection", locked } };
  const calls = { tools: [], locks: 0, messages: [], keys: [] };
  const listeners = new Map();
  const helper = {
    inPencilMode: false,
    pencilConnected: false,
    pencilInterationMode: 0,
    _api: {
      toggleLock() {
        calls.locks += 1;
        state.activeTool.locked = !state.activeTool.locked;
      },
      setActiveTool({ type }) {
        calls.tools.push(type);
        state.activeTool.type = type;
      },
    },
  };
  const context = vm.createContext({
    window: {
      excalidrawZHelper: helper,
      webkit: { messageHandlers: { excalidrawZ: {
        postMessage: (message) => calls.messages.push(message),
      } } },
    },
    localStorage: {
      getItem: () => storedState === undefined ? JSON.stringify(state) : storedState,
    },
    document: {
      addEventListener(name, listener) {
        const registered = listeners.get(name) ?? [];
        registered.push(listener);
        listeners.set(name, registered);
      },
      dispatchEvent: (event) => calls.keys.push({ type: event.type, code: event.code }),
      querySelector: () => null,
    },
    KeyboardEvent: class {
      constructor(type, options) {
        Object.assign(this, options, { type });
      }
    },
    setTimeout: () => 0,
    console: { info() {}, error() {} },
  });
  const modules = new Map();
  function moduleAt(filename) {
    if (!modules.has(filename)) {
      modules.set(filename, new vm.SourceTextModule(readFileSync(filename, "utf8"), {
        context, identifier: filename,
      }));
    }
    return modules.get(filename);
  }
  const directory = path.resolve(corePath, "excalidraw-app/excalidrawZ");
  const interaction = moduleAt(path.join(directory, "interaction.js"));
  await interaction.link((specifier, importing) => {
    assert.ok(specifier.startsWith("./"), "This probe only loads the helper's local source modules");
    return moduleAt(path.resolve(path.dirname(importing.identifier), `${specifier}.js`));
  });
  await interaction.evaluate();
  return {
    interaction: interaction.namespace,
    actions: moduleAt(path.join(directory, "actions.js")).namespace,
    helper, state, calls,
    dispatch(name, event) {
      for (const listener of listeners.get(name) ?? []) {
        listener(event);
      }
    },
  };
}

for (const locked of [false, true]) {
  for (const enabled of [false, true]) {
    test(`Pen mode ${enabled} preserves tool lock ${locked}`, async () => {
      const page = await browser({ locked });
      page.interaction.togglePenMode(enabled);
      assert.equal(page.helper.inPencilMode, enabled);
      assert.equal(page.state.activeTool.locked, locked);
      assert.equal(page.calls.locks, 0);
      assert.deepEqual(page.calls.tools, []);
    });
  }
}

for (const storedState of [null, "invalid JSON", "{}", '{"activeTool":null}']) {
  test(`Pen mode does not depend on stored drawing state: ${storedState}`, async () => {
    const page = await browser({ storedState });
    page.interaction.togglePenMode(true);
    page.interaction.togglePenMode(false);
    assert.equal(page.helper.inPencilMode, false);
    assert.equal(page.calls.locks, 0);
  });
}

test("First Pencil input keeps tool lock while selecting freedraw and notifying native", async () => {
  const page = await browser();
  page.dispatch("pointerdown", { pointerType: "pen" });
  assert.equal(page.helper.inPencilMode, true);
  assert.equal(page.helper.pencilConnected, true);
  assert.equal(page.state.activeTool.locked, false);
  assert.equal(page.calls.locks, 0);
  assert.deepEqual(page.calls.tools, ["freedraw"]);
  assert.deepEqual(page.calls.messages.map((message) => message.event), ["didPenDown"]);

  page.dispatch("pointerdown", { pointerType: "touch" });
  assert.deepEqual(page.calls.tools, ["freedraw", "selection"]);
  assert.equal(page.state.activeTool.locked, false);
});

test("Explicit tool-lock commands still toggle lock independently of Pen mode", async () => {
  const page = await browser();
  page.interaction.togglePenMode(true);
  page.actions.toggleToolbarAction("q");
  assert.equal(page.state.activeTool.locked, true);
  page.interaction.togglePenMode(false);
  assert.equal(page.state.activeTool.locked, true);
  page.actions.toggleToolbarAction("Q");
  assert.equal(page.state.activeTool.locked, false);
  assert.equal(page.calls.locks, 2);
});

test("Pencil connection and finger-move policy retain their own behavior", async () => {
  const page = await browser({ locked: true });
  page.interaction.connectPencil(true);
  page.interaction.togglePenMode(true);
  page.interaction.setPointerInputPolicy({ oneFingerAction: "move" });
  page.dispatch("pointerdown", { pointerType: "touch" });
  page.dispatch("pointerup", { pointerType: "touch" });
  assert.deepEqual(page.calls.keys, [
    { type: "keydown", code: "Space" }, { type: "keyup", code: "Space" },
  ]);
  page.interaction.setPointerInputPolicy({ oneFingerAction: "none" });
  page.dispatch("pointerdown", { pointerType: "touch" });
  assert.deepEqual(page.calls.keys, [
    { type: "keydown", code: "Space" }, { type: "keyup", code: "Space" },
  ]);
  assert.deepEqual(page.calls.tools, []);
  assert.equal(page.state.activeTool.locked, true);
  page.interaction.connectPencil(false);
  assert.equal(page.helper.pencilConnected, false);
});
