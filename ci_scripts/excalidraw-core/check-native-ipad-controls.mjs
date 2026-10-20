import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { createRequire } from "node:module";
import path from "node:path";
import test from "node:test";

const corePath = process.env.EXCALIDRAWZ_CORE_PATH;
assert.ok(corePath, "Set EXCALIDRAWZ_CORE_PATH to the patched pinned core checkout");
const requireCore = createRequire(path.resolve(corePath, "package.json"));
const sass = requireCore("sass");
const { JSDOM } = requireCore("jsdom");
const postcss = requireCore("postcss");

// Compile the actual app stylesheet, then apply its native-control rules in a
// small DOM. This checks CSS visibility and scope, not WebKit layout or input.
const compiled = sass.compile(path.join(corePath, "excalidraw-app/index.scss"), {
  logger: { warn() {}, debug() {} },
}).css;
const nativeRules = [];
postcss.parse(compiled).walkRules((rule) => {
  if (rule.selector.includes("html.excalidrawz-native-ipad-controls")) {
    nativeRules.push(rule.toString());
  }
});
assert.ok(nativeRules.length, "The app stylesheet must include the native iPad controls patch");

function editor() {
  return new JSDOM(`<!doctype html><html><head><style>
    .zoom-actions, .undo-redo-buttons, .ToolIcon__penMode,
    .selected-shape-actions, .page-context { display: flex; }
    ${nativeRules.join("\n")}
    </style></head><body><div class="excalidraw">
    <div class="App-menu_top__left">
      <section class="selected-shape-actions"><button>Stroke color</button></section>
      <button class="ToolIcon__penMode">Pen mode</button>
    </div>
    <div class="layer-ui__wrapper__footer-left">
      <div class="zoom-actions"><button>Zoom in</button></div>
      <div class="undo-redo-buttons"><button>Undo</button></div>
      <button class="page-context">Page action</button>
    </div>
    <div class="dialog"><div class="zoom-actions">Dialog zoom</div></div>
    </div></body></html>`, { url: "https://excalidraw.invalid" });
}

function display(page, selector) {
  const element = page.window.document.querySelector(selector);
  assert.ok(element, `Missing probe control: ${selector}`);
  return page.window.getComputedStyle(element).display;
}

test("Native iPad flag hides only the replaced canvas controls and restores them when removed", () => {
  const page = editor();
  const replaced = [
    ".layer-ui__wrapper__footer-left .zoom-actions",
    ".layer-ui__wrapper__footer-left .undo-redo-buttons",
    ".App-menu_top__left > .ToolIcon__penMode",
  ];
  for (const selector of replaced) assert.equal(display(page, selector), "flex");
  page.window.document.documentElement.classList.add("excalidrawz-native-ipad-controls");
  for (const selector of replaced) assert.equal(display(page, selector), "none");
  for (const selector of [".selected-shape-actions", ".page-context", ".dialog .zoom-actions"]) {
    assert.equal(display(page, selector), "flex", `Keep ${selector} accessible`);
  }
  page.window.document.documentElement.classList.remove("excalidrawz-native-ipad-controls");
  for (const selector of replaced) assert.equal(display(page, selector), "flex");
  page.window.close();
});

test("The flag is local to one editor document", () => {
  const nativeIPad = editor();
  const otherEditor = editor();
  nativeIPad.window.document.documentElement.classList.add("excalidrawz-native-ipad-controls");
  assert.equal(display(nativeIPad, ".undo-redo-buttons"), "none");
  assert.equal(display(otherEditor, ".undo-redo-buttons"), "flex");
  nativeIPad.window.close();
  otherEditor.window.close();
});

// Load the complete production helper and its real local imports.
async function styleHelper(page) {
  const helper = { shouldHideActionsMenu: false };
  const context = vm.createContext({
    window: { excalidrawZHelper: helper },
    document: page.window.document,
    localStorage: page.window.localStorage,
    KeyboardEvent: page.window.KeyboardEvent,
    setTimeout,
    console,
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
  const interaction = moduleAt(path.resolve(corePath, "excalidraw-app/excalidrawZ/interaction.js"));
  await interaction.link((specifier, importing) => {
    assert.ok(specifier.startsWith("./"), "Only helper-local imports are expected");
    return moduleAt(path.resolve(path.dirname(importing.identifier), specifier + ".js"));
  });
  await interaction.evaluate();
  return { helper, toggle: interaction.namespace.toggleActionsMenu };
}

test("Style stores requests without a panel and applies explicit requests to a mounted panel", async () => {
  const page = editor();
  const panel = page.window.document.querySelector(".selected-shape-actions");
  panel.remove();
  const { helper, toggle } = await styleHelper(page);
  toggle(false);
  assert.equal(helper.shouldHideActionsMenu, true, "Later selection must receive the requested hidden state");
  page.window.document.querySelector(".App-menu_top__left").append(panel);
  toggle(false);
  assert.ok(panel.classList.contains("transition-left"));
  assert.equal(helper.shouldHideActionsMenu, true);
  toggle(true);
  assert.equal(panel.classList.contains("transition-left"), false);
  assert.equal(helper.shouldHideActionsMenu, false);
  page.window.close();
});

test("Repeated Style requests preserve the requested visibility", async () => {
  const page = editor();
  const panel = page.window.document.querySelector(".selected-shape-actions");
  const { helper, toggle } = await styleHelper(page);
  for (const presented of [false, false, true, true, false, false]) {
    toggle(presented);
    assert.equal(panel.classList.contains("transition-left"), !presented);
    assert.equal(helper.shouldHideActionsMenu, !presented);
  }
  page.window.close();
});
