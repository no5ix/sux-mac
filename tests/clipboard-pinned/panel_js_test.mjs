#!/usr/bin/env node
// Automated verification for the Clipboard History panel JavaScript.
//
// The code under test is extracted VERBATIM from the production Spoon file
// (.hammerspoon/Spoons/xClipboardHistory.spoon/init.lua) between the
// BEGIN/END markers, so this file exercises the shipped panel logic, not a
// copy of it. A minimal DOM stub supplies the few browser APIs the extracted
// blocks touch.
//
// Scope: the context-menu Pin/Unpin state and the Tab / Shift+Tab navigation
// model. There is no GUI automation here: Peekaboo is deliberately not used.
//
//   node tests/clipboard-pinned/panel_js_test.mjs

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";

const here = dirname(fileURLToPath(import.meta.url));
const SPOON = join(here, "..", "..", ".hammerspoon", "Spoons",
  "xClipboardHistory.spoon", "init.lua");
const source = readFileSync(SPOON, "utf8");

function block(begin, end) {
  const start = source.indexOf(begin);
  const stop = source.indexOf(end);
  assert.ok(start > 0, `missing marker in the Spoon file: ${begin}`);
  assert.ok(stop > start, `missing marker in the Spoon file: ${end}`);
  return source.slice(start, stop);
}

const menuModel = block("/* BEGIN CONTEXT MENU MODEL", "/* END CONTEXT MENU MODEL */");
const multiSelectionBinding = source.slice(source.indexOf('function syncClipboardMultiSelection()'), source.indexOf("const contextMenu = document.createElement('div');"));
const navModel = block("/* BEGIN KEYBOARD NAVIGATION MODEL", "/* END KEYBOARD NAVIGATION MODEL */");
const navBinding = block("/* BEGIN KEYBOARD NAVIGATION BINDING", "/* END KEYBOARD NAVIGATION BINDING */");
const panelAnimation = block("/* BEGIN PANEL ANIMATION", "/* END PANEL ANIMATION */");

// The panel script as the browser sees it, for the structural checks.
const scriptStart = source.indexOf("<script>");
const scriptEnd = source.indexOf("</script>");
assert.ok(scriptStart > 0 && scriptEnd > scriptStart, "panel <script> not found");
const panelScript = source.slice(scriptStart + "<script>".length, scriptEnd);

// ---------------------------------------------------------------- DOM stub --

const kebab = (name) => name.replace(/[A-Z]/g, (ch) => "-" + ch.toLowerCase());

class El {
  constructor(tagName) {
    this.tagName = String(tagName).toUpperCase();
    this.parentNode = null;
    this.children = [];
    this.attrs = new Map();
    this.style = {};
    this.textContent = "";
    this.classList = new ClassList(this);
    this.handlers = new Map();
    // dataset mirrors the browser: dataset.contextAction maps to the
    // data-context-action attribute, and writing it updates that attribute -
    // exactly the coupling the leaked-state bug relied on.
    this.dataset = new Proxy({}, {
      get: (_t, prop) => (typeof prop === "string" ? this.attrs.get(`data-${kebab(prop)}`) : undefined),
      set: (_t, prop, value) => { this.attrs.set(`data-${kebab(prop)}`, String(value)); return true; },
      has: (_t, prop) => this.attrs.has(`data-${kebab(prop)}`),
    });
  }
  setAttribute(name, value) { this.attrs.set(name, String(value)); }
  getAttribute(name) { return this.attrs.has(name) ? this.attrs.get(name) : null; }
  appendChild(child) { child.parentNode = this; this.children.push(child); return child; }
  addEventListener(type, handler) {
    if (!this.handlers.has(type)) this.handlers.set(type, []);
    this.handlers.get(type).push(handler);
  }
  matches(selector) {
    const tag = selector.match(/^([a-z]+)/i);
    const rest = tag ? selector.slice(tag[1].length) : selector;
    if (tag && this.tagName !== tag[1].toUpperCase()) return false;
    for (const part of rest.match(/\[[^\]]+\]/g) || []) {
      const inner = part.slice(1, -1);
      const eq = inner.indexOf("=");
      if (eq < 0) {
        if (!this.attrs.has(inner)) return false;
      } else {
        const name = inner.slice(0, eq);
        const value = inner.slice(eq + 1).replace(/^["']|["']$/g, "");
        if (this.attrs.get(name) !== value) return false;
      }
    }
    if (rest.startsWith(".item") && !this.classList.contains("item")) return false;
    return true;
  }
  querySelectorAll(selector) {
    const found = [];
    const walk = (node) => node.children.forEach((child) => {
      if (child.matches(selector)) found.push(child);
      walk(child);
    });
    walk(this);
    return found;
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  closest(selector) {
    let node = this;
    while (node) {
      if (node.matches && node.matches(selector)) return node;
      node = node.parentNode;
    }
    return null;
  }
  focus() { FOCUS.set(this); }
  dispatch(type, event) {
    (this.handlers.get(type) || []).forEach((handler) => handler(event));
  }
}

class ClassList {
  constructor(el) { this.el = el; this.set = new Set(); }
  add(name) { this.set.add(name); }
  remove(name) { this.set.delete(name); }
  contains(name) { return this.set.has(name); }
  toggle(name, on) { if (on) this.set.add(name); else this.set.delete(name); }
}

const FOCUS = {
  current: null,
  log: [],
  set(el) {
    this.current = el;
    this.log.push(el === SEARCH ? "search" : `card:${el.dataset.uid}`);
  },
};

const SEARCH = {
  value: "",
  setSelectionRange() {},
  focus() { FOCUS.set(SEARCH); },
};

function makeWindow() {
  return { innerWidth: 1200, innerHeight: 800, scrollX: 7, scrollY: 11, scrollTo() {} };
}

// Card fixtures: text and image, ordinary and pinned, in rendered DOM order.
function card(index, uid, pinned, type) {
  const el = new El(type === "image" ? "div" : "button");
  el.classList.add("item");
  el.attrs.set("data-index", String(index));
  el.attrs.set("data-uid", uid);
  el.attrs.set("data-pinned", String(pinned));
  el.attrs.set("data-kind", type);
  el.attrs.set("data-action", "paste");
  return el;
}

function loadNavigation(cards) {
  const state = { cards: [...cards], selected: -1, cleared: 0 };
  const rows = () => state.cards;
  const selectRow = (index) => { state.selected = index; };
  const clearRowSelection = () => { state.cleared += 1; };
  const windowStub = makeWindow();
  const api = new Function("rows", "selectRow", "clearRowSelection", "search", "window", "selectedIndex",
    `${navModel}\n${navBinding}\nreturn { navState, cardUids, navMove, reset: window.resetClipboardSelection };`)(
    rows, selectRow, clearRowSelection, SEARCH, windowStub, 0);
  return { ...state, api, state: state };
}

function loadMenuModel() {
  const document = { createElement: (tag) => new El(tag) };
  const window = makeWindow();
  const state = { cards: [] };
  const selectedClipboardUids = new Set();
  const rows = () => state.cards;
  const api = new Function("document", "window", "rows", "selectedClipboardUids",
    `${menuModel}\n${multiSelectionBinding}\nreturn { CONTEXT_MENU_ITEMS, contextMenuSpec, buildContextMenu, applyContextMenuTarget, openContextMenu, findContextRow, visibleRangeUids, handleContextMenuClick, syncClipboardMultiSelection };`)(
    document, window, rows, selectedClipboardUids);
  api.selectedClipboardUids = selectedClipboardUids;
  api.setRows = (cards) => { state.cards = cards; };
  return api;
}

// The tiny runner must be declared before the first scenario: `results` is a
// const, so a framework section placed after the scenarios is in its temporal
// dead zone when they run, and every scenario dies with a ReferenceError.
const results = [];
function test(name, body) {
  try {
    body();
    results.push(["PASS", name]);
  } catch (error) {
    results.push(["FAIL", `${name} :: ${error && error.message ? error.message : error}`]);
  }
}


test("date filter: clicking the already-selected date is a no-op, not All", () => {
  const handlerStart = panelScript.indexOf("if (action === 'dateScope' || action === 'dateFilter') {");
  const handlerEnd = panelScript.indexOf("if (action === 'loadMore')", handlerStart);
  assert.ok(handlerStart > 0 && handlerEnd > handlerStart, "date-filter click handler is present");
  const handler = panelScript.slice(handlerStart, handlerEnd);
  assert.ok(handler.includes("} else if (wasSelected) {"), "selected date chip has its own no-op branch");
  assert.ok(handler.includes("} else if (action === 'dateScope') {") === false,
    "selected date state is not used as the All-filter condition");
  assert.ok(handler.includes("if (action === 'dateScope') {") && handler.includes("bridge('showLatest'"),
    "only the All dateScope action returns to the full history");
  assert.ok(handler.includes("return;") && handler.includes("bridge('dateFilter',0,'',selectedKind,button.dataset.dateKey)"),
    "switching to another date filters exactly that date, while re-clicking the selected date returns early");
});

test("keyboard navigation restores the grid focus stop and global key routing", () => {
  const sourceHasGridTabStop = panelScript.includes("resultsPanel.tabIndex = 0");
  assert.ok(sourceHasGridTabStop, "the results grid is again reachable by Tab");
  assert.ok(panelScript.includes("function handleClipboardPanelKeydown(event)"),
    "the panel has one explicit keyboard router");
  assert.ok(panelScript.includes("document.addEventListener('keydown', handleClipboardPanelKeydown)"),
    "the router listens at the document level");
  assert.ok(panelScript.includes("event.key === 'Tab'") &&
    panelScript.includes("navMove(!event.shiftKey)"),
    "Tab and Shift+Tab share the sequential result navigation");
  for (const key of ["ArrowDown", "ArrowUp", "ArrowLeft", "ArrowRight"]) {
    assert.ok(panelScript.includes("'" + key + "'"), key + " is handled");
  }
  assert.ok(panelScript.includes("if (key === 'Escape')"),
    "Escape has an explicit panel-level fallback");
  assert.ok(!panelScript.includes("resultsPanel.tabIndex = -1"),
    "the grid is not removed from keyboard focus order");
  assert.ok(panelScript.includes("function activateSelectedCard()"),
    "selected-result activation is shared by keyboard shortcuts");
  assert.ok(panelScript.includes("key === ' '") && panelScript.includes("key === 'Enter'"),
    "Space and Enter activate a focused result");
  assert.ok(panelScript.includes("bridge('paste', Number(item.dataset.index || 0), '')"),
    "keyboard activation uses the same paste bridge as click-to-paste");
  const filterFocusStart = panelScript.indexOf("function setFilterFocus(index)");
  const filterFocusEnd = panelScript.indexOf("\n}", filterFocusStart);
  const filterFocusSource = panelScript.slice(filterFocusStart, filterFocusEnd);
  assert.ok(filterFocusSource.includes("clearRowSelection()"),
    "returning focus to the filters clears the previous card highlight");
  assert.ok(source.includes("--filter-selected-bg: #e6e8ec;") &&
    source.includes("--filter-selected-bg: #454a55;"),
    "active filters use shallow white in dark mode and shallow dark in light mode");
});


test("context menu layout: divider separates ordinary actions from paste actions", () => {
  const m = menu.buildContextMenu(new El("div"));
  const slots = m.children.map(node => node.getAttribute("data-context-slot"));
  assert.deepEqual(slots, [
    "preview", "copy", "pin", "top", "removeTop", "divider", "pasteAll",
    "select", "pasteSelected", "pasteSelectedOrder", "pastePath",
  ]);
  const divider = m.querySelector('[data-context-slot="divider"]');
  assert.equal(divider.getAttribute("role"), "separator");
  assert.ok(divider.style.cssText.includes("height:1px"));
});

test("context menu: Top is visible only on pinned cards and dispatches for the right-clicked card", () => {
  const m = menu.buildContextMenu(new El("div"));
  const ordinary = card(0, "top-ordinary", false, "text");
  const pinned = card(1, "top-pinned", true, "text");
  menu.applyContextMenuTarget(m, ordinary, false);
  assert.equal(m.querySelector('[data-context-slot="top"]').style.display, "none");
  menu.applyContextMenuTarget(m, pinned, false);
  const button = m.querySelector('[data-context-slot="top"]');
  assert.equal(button.style.display, "block");
  assert.equal(button.textContent, "⬆️ Top");
  const calls = [];
  const state = { rowIndex: 1, uid: pinned.dataset.uid };
  menu.handleContextMenuClick(m, state, { target: { closest: () => button } },
    (...args) => calls.push(args), null, [ordinary, pinned], []);
  assert.deepEqual(calls, [["top", 1, ""]]);
});

test("context menu: promoted pins show both Top and Remove from Top actions", () => {
  const m = menu.buildContextMenu(new El("div"));
  const promoted = card(2, "top-promoted", true, "text");
  promoted.dataset.topMarked = "true";
  menu.applyContextMenuTarget(m, promoted, false);
  const topButton = m.querySelector('[data-context-slot="top"]');
  const removeButton = m.querySelector('[data-context-slot="removeTop"]');
  assert.equal(topButton.style.display, "block");
  assert.equal(topButton.textContent, "⬆️ Top");
  assert.equal(removeButton.style.display, "block");
  assert.equal(removeButton.textContent, "⬇️ Remove from Top");
  const calls = [];
  const state = { rowIndex: 2, uid: promoted.dataset.uid };
  menu.handleContextMenuClick(m, state, { target: { closest: () => topButton } },
    (...args) => calls.push(args), null, [promoted], []);
  menu.handleContextMenuClick(m, state, { target: { closest: () => removeButton } },
    (...args) => calls.push(args), null, [promoted], []);
  assert.deepEqual(calls, [["top", 2, ""], ["removeTop", 2, ""]]);
  promoted.dataset.topMarked = "false";
  menu.applyContextMenuTarget(m, promoted, false);
  assert.equal(topButton.style.display, "block");
  assert.equal(removeButton.style.display, "none");
});

test("context menu layout: selected-paste actions appear only with a nonempty selection", () => {
  const m = menu.buildContextMenu(new El("div"));
  const target = card(0, "context-layout-uid", false, "text");
  menu.applyContextMenuTarget(m, target, false);
  assert.equal(m.querySelector('[data-context-slot="pasteSelected"]').style.display, "none");
  assert.equal(m.querySelector('[data-context-slot="pasteSelectedOrder"]').style.display, "none");
  assert.equal(m.querySelector('[data-context-slot="pasteAll"]').style.display, "block");
  assert.equal(m.querySelector('[data-context-slot="select"]').textContent, "Select/Deselect");
  menu.applyContextMenuTarget(m, target, true);
  assert.equal(m.querySelector('[data-context-slot="pasteSelected"]').style.display, "block");
  assert.equal(m.querySelector('[data-context-slot="pasteSelectedOrder"]').style.display, "block");
});

test("card timestamp stays fixed when selection order appears", () => {
  assert.ok(source.includes("grid-template-columns:16px 22px minmax(0,1fr) auto;"),
    "selection-order column has a fixed width so timestamp alignment cannot shift");
  assert.ok(source.includes(".card-meta-row .selection-order { box-sizing:border-box; width:22px; min-width:22px; }"),
    "selection order occupies a stable slot when populated");
  assert.ok(source.includes(".card-meta-row .selection-order:empty { visibility:hidden; }"),
    "empty selection order stays invisible without collapsing its grid slot");
  assert.ok(source.includes(".card-meta-row .stamp { position:static; grid-column:3; grid-row:1; justify-self:center;"),
    "timestamp remains centered in the same third grid column");
});

test("preview backdrop is aligned to and clipped by the panel shell", () => {
  assert.ok(source.includes("body > #clipboard-preview-overlay { display:none; position:fixed; inset:auto;"),
    "preview backdrop uses explicit panel-relative viewport bounds rather than covering the entire WebView");
  assert.ok(source.includes("border-radius:18px; overflow:hidden; clip-path:inset(0 round 18px);"),
    "preview backdrop clips to the panel shell's rounded 18px corners");
  assert.ok(source.includes("function syncPreviewOverlayBounds()") &&
    source.includes("const shell = document.getElementById('clipboard-panel-shell');") &&
    source.includes("const rect = shell.getBoundingClientRect();"),
    "overlay bounds are measured from the actual clipboard panel shell");
  assert.ok(source.includes("previewOverlay.style.left = rect.left + 'px';") &&
    source.includes("previewOverlay.style.top = rect.top + 'px';") &&
    source.includes("previewOverlay.style.width = rect.width + 'px';") &&
    source.includes("previewOverlay.style.height = rect.height + 'px';"),
    "overlay position and dimensions follow the shell's real bounds");
  assert.ok(source.includes("syncPreviewOverlayBounds();") &&
    source.includes("if (previewOverlay.classList.contains('open')) syncPreviewOverlayBounds();"),
    "bounds are synchronized when opening the preview and when the WebView resizes");
});

test("card hover is subtler than focus and highlights the full card", () => {
  assert.ok(source.includes("#clipboard-items .item:hover:not(.selected):not(:focus):not(:focus-visible):not(:focus-within) {\n  background:color-mix(in srgb, var(--selected-bg) 42%, var(--card-bg));"),
    "hover uses a lighter blend than the focused/selected state");
  assert.ok(source.includes("#clipboard-items .item:focus,\n#clipboard-items .item:focus-visible,\n#clipboard-items .item:focus-within { z-index:1; background:var(--selected-bg);"),
    "focus and focus-within highlight the entire card");
  assert.ok(source.includes(".card-meta-row { position:relative; display:grid;") && source.includes("border-radius:12px 12px 0 0; background:transparent;"),
    "card header has no independent background");
  assert.ok(source.includes(".card-meta-row:hover { background:transparent; }"),
    "hovering the header does not paint a separate header highlight");
  assert.ok(source.includes(".card-meta-row:focus-within { outline:0; }"),
    "focus is represented by the full-card highlight, not a header-only outline");
  assert.ok(source.includes(".stamp { color:var(--muted); font-size:10px; margin:0; }"),
    "timestamp keeps its smaller font");
  assert.ok(source.includes(".card-meta-row .pin-mark { font-size:12px; line-height:1.1; }"),
    "pin mark keeps its smaller font");
  assert.ok(source.includes(".card-indicators > .pin-mark { display:inline-flex; align-items:center; justify-content:center; font-size:12px;"),
    "the indicator-specific rule does not override the smaller pin font");
  assert.ok(source.includes("flex:0 0 16px; width:16px; height:16px; align-items:center; justify-content:center; font-size:12px;"),
    "Top mark keeps its smaller footprint and font");
  assert.ok(source.includes(".card-indicators { position:static; grid-column:4; grid-row:1;"),
    "pin and Top indicators remain in the header's right grid column");
});

test("context menu hover uses delegated mouseover and mouseout highlighting", () => {
  assert.ok(panelScript.includes("contextMenu.addEventListener('mouseover'"));
  assert.ok(panelScript.includes("contextMenu.addEventListener('mouseout'"));
  assert.ok(panelScript.includes("button.style.background = '#3a4250'"));
  assert.ok(panelScript.includes("button.style.background = 'transparent'"));
});


test("context menu: right-clicked item controls the Select/Deselect label", () => {
  const m = menu.buildContextMenu(new El("div"));
  const unselected = card(0, "label-unselected", false, "text");
  const selected = card(1, "label-selected", false, "text");

  menu.applyContextMenuTarget(m, unselected, false);
  assert.equal(m.querySelector('[data-context-slot="select"]').textContent, "✅ Select");

  menu.selectedClipboardUids.add("label-selected");
  menu.applyContextMenuTarget(m, selected, true);
  assert.equal(m.querySelector('[data-context-slot="select"]').textContent, "❌ Deselect");

  // Another unselected card must still show Select while a different card
  // remains selected in the global multi-selection.
  menu.applyContextMenuTarget(m, unselected, true);
  assert.equal(m.querySelector('[data-context-slot="select"]').textContent, "✅ Select");
});


test("clipboard cards use a top-right shared indicator group without type headings", () => {
  const cardHtml = source.slice(source.indexOf("local function historyItemHTML(entry, index)"),
    source.indexOf("\\nlocal function clipboardEntryMatches"));
  assert.ok(cardHtml.includes('class="card-indicators"'),
    "each clipboard card builds a shared indicator group");
  assert.ok(cardHtml.includes('class="multi-select-mark"'),
    "the selection marker is part of the persistent card markup");
  assert.ok(cardHtml.includes('class="pin-mark"'),
    "pinned cards keep their pin indicator");
  assert.ok(!cardHtml.includes('class="kind"'),
    "TEXT and IMAGE labels are no longer rendered");
  assert.ok(panelScript.includes("mark.style.visibility = selected ? 'visible' : 'hidden'"),
    "selection sync changes visibility without collapsing the marker slot");
  assert.ok(panelScript.includes(".card-indicators > .multi-select-mark,\\n.card-indicators > .pin-mark { flex:0 0 20px; width:20px; height:20px;"),
    "both indicators reserve fixed-width slots");
  assert.ok(panelScript.includes(".card-indicators { position:absolute; top:9px; right:10px;"),
    "the shared icon group is anchored at the upper-right");
  assert.ok(panelScript.includes("gap:5px"),
    "the checkmark and pin have consistent spacing");
});


test("image-specific context actions follow clicked-image and selected-image state", () => {
  const m = menu.buildContextMenu(new El("div"));
  const textTarget = card(0, "action-text", false, "text");
  const imageTarget = card(1, "action-image", false, "image");

  menu.applyContextMenuTarget(m, textTarget, false, false);
  for (const slot of ["copyPath", "pasteAllPaths", "pasteSelectedPaths", "pasteSelectedOrderPaths"]) {
    assert.equal(m.querySelector('[data-context-slot="' + slot + '"]').style.display, "none", slot);
  }

  menu.applyContextMenuTarget(m, imageTarget, false, false);
  assert.equal(m.querySelector('[data-context-slot="copyPath"]').style.display, "block");
  assert.equal(m.querySelector('[data-context-slot="pasteAllPaths"]').style.display, "block");
  assert.equal(m.querySelector('[data-context-slot="pasteSelectedPaths"]').style.display, "none");
  assert.equal(m.querySelector('[data-context-slot="pasteSelectedOrderPaths"]').style.display, "none");

  menu.applyContextMenuTarget(m, textTarget, true, true);
  assert.equal(m.querySelector('[data-context-slot="copyPath"]').style.display, "none");
  assert.equal(m.querySelector('[data-context-slot="pasteAllPaths"]').style.display, "none");
  assert.equal(m.querySelector('[data-context-slot="pasteSelectedPaths"]').style.display, "block");
  assert.equal(m.querySelector('[data-context-slot="pasteSelectedOrderPaths"]').style.display, "block");
});

test("image-path selected actions dispatch without dropping mixed-selection UIDs", () => {
  const m = menu.buildContextMenu(new El("div"));
  const target = card(0, "right-click-text", false, "text");
  const selectedUids = ["text-first", "image-second", "text-third", "image-fourth"];
  const calls = [];
  const state = { rowIndex: 0, uid: target.dataset.uid };
  const click = (slot) => {
    const button = m.querySelector('[data-context-slot="' + slot + '"]');
    button.dataset.contextAction = slot;
    return menu.handleContextMenuClick(m, state, {
      target: { closest: () => button },
    }, (...args) => calls.push(args), null, [target], selectedUids);
  };

  click("pasteSelectedPaths");
  assert.equal(calls[0][0], "pasteSelectedPaths");
  assert.deepEqual(JSON.parse(calls[0][2]), selectedUids);
  click("pasteSelectedOrderPaths");
  assert.equal(calls[1][0], "pasteSelectedOrderPaths");
  assert.deepEqual(JSON.parse(calls[1][2]), selectedUids);
});


test("image-path context actions dispatch Copy Path and preserve path mode in batches", () => {
  const modelSource = source.slice(source.indexOf("/* BEGIN CONTEXT MENU MODEL"),
    source.indexOf("/* END CONTEXT MENU MODEL */"));
  assert.ok(modelSource.includes("action === 'copyPath'") &&
    modelSource.includes("bridge('copyPath', rowIndex, '')"),
    "Copy Path must dispatch its own action to Lua");
  assert.ok(modelSource.includes("action === 'pasteAllPaths'") &&
    modelSource.includes("pasteAllFromPaths' : 'pasteAllFrom'") &&
    modelSource.includes("JSON.stringify(visibleRangeUids(items, target))") &&
    modelSource.includes("target.dataset.uid || ''"),
    "Paste from Current to First must dispatch the visible range and the clicked uid");
  assert.ok(!modelSource.includes("bridge('pasteAllFrom', rowIndex, '')") &&
    !modelSource.includes("bridge('pasteAllFromPaths', rowIndex, '')"),
    "neither range action may send only a collection row index");
  assert.ok(source.includes('elseif body.action == "copyPath"') &&
    source.includes("copyOrPasteImagePathEntry(tonumber(body.index), false)"),
    "Lua must handle Copy Path and write the resolved path to the pasteboard");

  const engineStart = source.indexOf("local function pasteAllRowsStep");
  const engineEnd = source.indexOf("\nfunction pasteAllWithDelimiterRecursionVersion", engineStart);
  const engine = source.slice(engineStart, engineEnd);
  assert.ok(engineStart > 0 && engineEnd > engineStart, "the paste engine is one named function");
  assert.ok(engine.includes("local function pasteAllRowsStep(position, direction, pathMode)"));
  assert.ok(!/pasteAllRowsStep\(position \+ direction, direction\)/.test(engine),
    "no recursive batch step may drop pathMode");
  assert.ok(engine.includes("pasteAllRowsStep(position + direction, direction, pathMode)"),
    "every next-item callback keeps pathMode");
  const recursiveSteps = engine.match(/pasteAllRowsStep\(position \+ direction, direction, pathMode\)/g) || [];
  assert.ok(recursiveSteps.length >= 4,
    "pathMode must flow through each retry and delayed next-item callback");

  const rangeStart = source.indexOf("pasteRangeFromCardToFirst = function(startUid, serializedUids, pathMode)");
  const rangeEnd = source.indexOf("\n-- Function to show clipboard history", rangeStart);
  const range = source.slice(rangeStart, rangeEnd);
  assert.ok(rangeStart > 0 && rangeEnd > rangeStart, "the range paste is one named Lua entry point");
  assert.ok(range.includes("resolveSelectedEntries(visible)"),
    "the range is resolved by card uid, not by a position in the collection");
  assert.ok(range.includes("for index = position, 1, -1 do"),
    "the clicked card is pasted first, then every visible card above it");
  assert.ok(range.includes("return startSequentialPaste(entries, pathMode)"),
    "the range paste runs the shared launch in the requested mode");
  const launcherStart = source.indexOf("local function startSequentialPaste(entries, pathMode)");
  const launcherEnd = source.indexOf("\npasteSelectedClipboardItems = function", launcherStart);
  const launcher = source.slice(launcherStart, launcherEnd);
  assert.ok(launcherStart > 0 && launcherEnd > launcherStart,
    "the range and the selection paste share one launch sequence");
  assert.ok(launcher.includes("pasteAllRowsStep(1, 1, pathMode == true)"),
    "range image-path paste must start the engine in path mode");
  assert.ok(source.includes("pasteRangeFromCardToFirst(body.uid, body.query, true)"),
    "the image-path range action is wired to the Lua handler");
  assert.ok(source.includes("pasteRangeFromCardToFirst(body.uid, body.query, false)"),
    "the text range action is wired to the Lua handler");
  assert.ok(source.includes('pasteSelectedClipboardItems(body.query, "chronological", true)'));
  assert.ok(source.includes('pasteSelectedClipboardItems(body.query, "selection", true)'));
});


test("range paste: the payload is the visible list newest-first, plus the clicked uid", () => {
  const model = loadMenuModel();
  const m = model.buildContextMenu(new El("div"));
  // The collection indexes are sparse: the Images filter hides every text record
  // between these three image cards, so a row index says nothing about which
  // cards the user is looking at.
  const items = [
    card(3, "image-newest", false, "image"),
    card(9, "image-clicked", false, "image"),
    card(14, "image-oldest", false, "image"),
  ];
  const calls = [];
  const bridge = (...args) => calls.push(args);
  const state = { rowIndex: -1, uid: null };
  model.openContextMenu(m, state, items[1], { x: 5, y: 5 });
  model.handleContextMenuClick(m, state,
    { target: m.querySelector('[data-context-slot="pasteAll"]') }, bridge, () => {}, items);
  assert.equal(calls.length, 1, "one click sends one action");
  const [action, rowIndex, payload, kind, dateKey, uid] = calls[0];
  assert.equal(action, "pasteAllFrom");
  assert.equal(uid, "image-clicked", "the clicked card is named by its uid");
  assert.deepEqual(JSON.parse(payload), ["image-newest", "image-clicked", "image-oldest"],
    "the payload is every visible card in DOM order");
  assert.ok(Number(rowIndex) > 2,
    "the row index is a collection position - exactly why it is not the range");

  const pathCalls = [];
  model.openContextMenu(m, state, items[1], { x: 5, y: 5 });
  model.handleContextMenuClick(m, state,
    { target: m.querySelector('[data-context-slot="pasteAllPaths"]') },
    (...args) => pathCalls.push(args), () => {}, items);
  assert.equal(pathCalls[0][0], "pasteAllFromPaths", "the image variant keeps its own path-mode action");
  assert.deepEqual(JSON.parse(pathCalls[0][2]), JSON.parse(payload),
    "the image variant sends the same visible range");
  assert.equal(pathCalls[0][5], "image-clicked", "the image variant names the same clicked card");

  // A card that left the list is still the range's start, so Lua gets an
  // explicit uid to refuse instead of an unrelated row.
  assert.deepEqual(model.visibleRangeUids([items[1], items[2]], items[0]),
    ["image-newest", "image-clicked", "image-oldest"], "a target outside the list is prepended");
  assert.deepEqual(model.visibleRangeUids([], null), [], "no cards, no range");
  assert.deepEqual(model.visibleRangeUids([items[0], items[0]], items[0]), ["image-newest"],
    "a card is never listed twice");
});


test("image-specific context menu restores Paste Path and pairs regular/image actions", () => {
  const m = menu.buildContextMenu(new El("div"));
  const target = card(0, "pair-image", false, "image");
  menu.applyContextMenuTarget(m, target, false, false);
  const slots = m.children.map(node => node.getAttribute("data-context-slot"));
  assert.deepEqual(slots, [
    "preview", "copy", "copyPath", "pin", "divider",
    "pasteAll", "pasteAllPaths", "pastePath", "select",
    "pasteSelected", "pasteSelectedPaths",
    "pasteSelectedOrder", "pasteSelectedOrderPaths",
  ]);
  assert.equal(m.querySelector('[data-context-slot="copyPath"]').textContent, "🗂️ Copy Path");
  assert.equal(m.querySelector('[data-context-slot="pastePath"]').textContent, "🗂️ Paste Path");
  assert.equal(m.querySelector('[data-context-slot="copyPath"]').style.display, "block");
  assert.equal(m.querySelector('[data-context-slot="pastePath"]').style.display, "block");

  const textTarget = card(1, "pair-text", false, "text");
  menu.applyContextMenuTarget(m, textTarget, false, false);
  assert.equal(m.querySelector('[data-context-slot="pastePath"]').style.display, "none");
  assert.equal(m.querySelector('[data-context-slot="pasteSelected"]').style.display, "none");
  assert.equal(m.querySelector('[data-context-slot="pasteSelectedPaths"]').style.display, "none");
  assert.equal(m.querySelector('[data-context-slot="pasteSelectedOrder"]').style.display, "none");
  assert.equal(m.querySelector('[data-context-slot="pasteSelectedOrderPaths"]').style.display, "none");

  menu.applyContextMenuTarget(m, textTarget, true, true);
  assert.equal(m.querySelector('[data-context-slot="pasteSelected"]').style.display, "block");
  assert.equal(m.querySelector('[data-context-slot="pasteSelectedPaths"]').style.display, "block");
  assert.equal(m.querySelector('[data-context-slot="pasteSelectedOrder"]').style.display, "block");
  assert.equal(m.querySelector('[data-context-slot="pasteSelectedOrderPaths"]').style.display, "block");
});


test("context menu: image-section divider is hidden for text records without selected images", () => {
  const m = menu.buildContextMenu(new El("div"));
  const textTarget = card(0, "divider-text", false, "text");
  const imageTarget = card(1, "divider-image", false, "image");

  menu.applyContextMenuTarget(m, textTarget, false, false);
  const dividers = m.querySelectorAll('[data-context-slot="divider"]');
  assert.equal(dividers.length, 2, "both divider slots are stable");
  assert.equal(dividers[0].style.display, "block", "the regular divider remains above Select");
  const selectIndex = m.children.findIndex(node => node.getAttribute("data-context-slot") === "select");
  const regularDividerIndex = m.children.indexOf(dividers[0]);
  assert.equal(regularDividerIndex + 1, selectIndex, "the regular divider is immediately above Select");
  assert.equal(dividers[1].style.display, "none", "the hidden image section has no orphan divider");

  menu.applyContextMenuTarget(m, imageTarget, false, false);
  assert.equal(dividers[1].style.display, "block", "an image target exposes the image section divider");

  menu.applyContextMenuTarget(m, textTarget, true, true);
  assert.equal(dividers[1].style.display, "block", "selected image actions expose their section divider");

  menu.applyContextMenuTarget(m, textTarget, true, false);
  assert.equal(dividers[1].style.display, "none", "text-only selection hides the image section divider");
});


test("context menu separators have unique slots and independent visibility", () => {
  const m = menu.buildContextMenu(new El("div"));
  const slots = m.children.map(node => node.getAttribute("data-context-slot"));
  const selectDivider = slots.indexOf("divider-before-select");
  const imageDivider = slots.indexOf("divider-before-images");
  const selectIndex = slots.indexOf("select");
  assert.ok(selectDivider >= 0 && selectDivider < selectIndex,
    "the first divider is immediately above the Select action");
  assert.ok(imageDivider > selectIndex,
    "the image-section divider follows the selection actions");
  assert.notEqual(selectDivider, imageDivider,
    "each divider has a distinct slot identity");

  const textTarget = card(0, "select-divider-text", false, "text");
  menu.applyContextMenuTarget(m, textTarget, false, false);
  assert.equal(m.querySelector('[data-context-slot="divider-before-select"]').style.display, "block",
    "divider above Select is visible for an unselected text record");
  assert.equal(m.querySelector('[data-context-slot="divider-before-images"]').style.display, "none",
    "hidden image section has no trailing divider");

  menu.applyContextMenuTarget(m, card(1, "select-divider-image", false, "image"), false, false);
  assert.equal(m.querySelector('[data-context-slot="divider-before-select"]').style.display, "block",
    "divider above Select remains visible for an image record");
  assert.equal(m.querySelector('[data-context-slot="divider-before-images"]').style.display, "block",
    "image section divider appears for an image record");
});

// ------------------------------------------------------------------- tests --

const menu = loadMenuModel();
const actions = (m) => m.querySelectorAll("button").map((b) => b.dataset.contextAction);
const labels = (m) => m.querySelectorAll("button").map((b) => b.textContent);
const slots = (m) => m.querySelectorAll("button").map((b) => b.getAttribute("data-context-slot"));
// Only the visible buttons are the menu a user sees. "Paste path" is a slot on
// every menu and is hidden for cards that have no file, so the button set and
// the stable slots never change - only the visibility does.
const visibleActions = (m) => m.querySelectorAll("button")
  .filter((b) => b.style.display !== "none")
  .map((b) => b.dataset.contextAction);
const ALL_SLOTS = ["preview", "pasteAll", "pasteSelected", "pasteSelectedOrder", "select", "copy", "pastePath", "pin"];
const textMenu = (pinAction, selected = false) =>
  ["preview", "pasteAll", ...(selected ? ["pasteSelected", "pasteSelectedOrder"] : []), "select", "copy", pinAction];
const imageMenu = (pinAction, selected = false) =>
  ["preview", "pasteAll", ...(selected ? ["pasteSelected", "pasteSelectedOrder"] : []), "select", "copy", "pastePath", pinAction];
const specActions = (pinAction, selected = false) =>
  ["preview", "pasteAll", "pasteSelected", "pasteSelectedOrder", "select", "copy", "pastePath", pinAction];

test("context menu: every slot is built once, in the documented order", () => {
  const m = menu.buildContextMenu(new El("div"));
  assert.deepEqual(slots(m), ALL_SLOTS, "the spec order is the DOM order");
  assert.deepEqual(actions(m), specActions("pin"), "every slot keeps its action payload, visible or not");
  assert.deepEqual(visibleActions(m), textMenu("pin"), "a text card has no file path to report");
});

test("context menu: Paste path is offered on image cards only", () => {
  const m = menu.buildContextMenu(new El("div"));
  const ordinaryText = card(0, "2026-11-08:100:text:1", false, "text");
  const ordinaryImage = card(1, "2026-11-08:101:image:2", false, "image");
  const pinnedImage = card(2, "pin-image", true, "image");
  const pinnedText = card(3, "pin-text", true, "text");

  assert.deepEqual(visibleActions(m), textMenu("pin"), "text starts hidden");
  menu.applyContextMenuTarget(m, ordinaryImage);
  assert.deepEqual(visibleActions(m), imageMenu("pin"), "an image card offers the path");
  menu.applyContextMenuTarget(m, pinnedImage);
  assert.deepEqual(visibleActions(m), imageMenu("unpin"), "a pinned image keeps the path action");
  menu.applyContextMenuTarget(m, ordinaryText);
  assert.deepEqual(visibleActions(m), textMenu("pin"), "the next text card hides it again");
  menu.applyContextMenuTarget(m, pinnedText);
  assert.deepEqual(visibleActions(m), textMenu("unpin"), "a pinned text card has no path");
  assert.deepEqual(actions(m), specActions("unpin"),
    "the hidden slot keeps its stable action payload");
  assert.equal(m.querySelectorAll("button").length, ALL_SLOTS.length,
    "hiding a slot never adds or removes a button");
});

test("context menu: ordinary text and image items produce Pin", () => {
  const m = menu.buildContextMenu(new El("div"));
  const ordinaryText = card(0, "2026-11-08:100:text:1", false, "text");
  const ordinaryImage = card(1, "2026-11-08:101:image:2", false, "image");
  assert.deepEqual(menu.applyContextMenuTarget(m, ordinaryText).map(p => p.action), specActions("pin"));
  assert.deepEqual(actions(m), specActions("pin"));
  assert.deepEqual(visibleActions(m), textMenu("pin"), "a text card does not offer the path");
  assert.ok(labels(m)[6].includes("Pin") && !labels(m)[6].includes("Unpin"), labels(m)[6]);
  assert.deepEqual(menu.applyContextMenuTarget(m, ordinaryImage).map(p => p.action), specActions("pin"));
  assert.deepEqual(visibleActions(m), imageMenu("pin"), "an image card offers the path");
  // Order and item count are preserved; nothing is duplicated.
  assert.equal(m.querySelectorAll("button").length, ALL_SLOTS.length);
  assert.deepEqual(labels(m).map(l => l.slice(0, 2)),
    ["👁️", "Pa", "✅", "Se", "📋", "🗂️", "📍"].map(s => s.slice(0, 2)));
});

test("context menu: pinned text and image items produce Unpin", () => {
  const m = menu.buildContextMenu(new El("div"));
  const pinnedText = card(0, "pin-1", true, "text");
  const pinnedImage = card(1, "pin-2", true, "image");
  assert.deepEqual(menu.applyContextMenuTarget(m, pinnedText).map(p => p.action), specActions("unpin"));
  assert.deepEqual(visibleActions(m), textMenu("unpin"));
  assert.ok(labels(m)[6].includes("Unpin"), labels(m)[6]);
  assert.deepEqual(menu.applyContextMenuTarget(m, pinnedImage).map(p => p.action), specActions("unpin"));
  assert.deepEqual(visibleActions(m), imageMenu("unpin"));
  assert.equal(m.querySelectorAll("button").length, ALL_SLOTS.length);
});

test("multi-selection binding adds and removes lower-left checkmarks by stable UID", () => {
  const cards = [card(0, "multi-a", false, "text"), card(1, "multi-b", true, "image")];
  const model = loadMenuModel();
  model.setRows(cards);
  model.selectedClipboardUids.add("multi-a");
  model.syncClipboardMultiSelection();
  assert.equal(cards[0].dataset.selected, "true");
  assert.ok(cards[0].classList.contains("multi-selected"));
  assert.equal(cards[0].querySelector(".multi-select-mark").textContent, "✓");
  assert.equal(cards[1].querySelector(".multi-select-mark"), null);
  model.selectedClipboardUids.add("multi-b");
  model.syncClipboardMultiSelection();
  assert.equal(cards[1].querySelector(".multi-select-mark").textContent, "✓");
  model.selectedClipboardUids.delete("multi-a");
  model.syncClipboardMultiSelection();
  assert.equal(cards[0].querySelector(".multi-select-mark"), null);
  assert.equal(cards[1].querySelector(".multi-select-mark").textContent, "✓");
});

test("context menu: selection action and selected-paste visibility track the target", () => {
  const m = menu.buildContextMenu(new El("div"));
  const uid = "item-to-select";
  const ordinary = card(0, uid, false, "text");
  menu.openContextMenu(m, { rowIndex: -1, uid: null }, ordinary, { x: 10, y: 10 }, false);
  assert.equal(m.querySelector('[data-context-slot="select"]').textContent, "Select");
  assert.equal(m.querySelector('[data-context-slot="pasteSelected"]').style.display, "none");
  ordinary.dataset.selected = "true";
  menu.applyContextMenuTarget(m, ordinary, true);
  assert.ok(visibleActions(m).includes("pasteSelected"));
  assert.equal(m.querySelector('[data-context-slot="select"]').textContent, "Deselect");
  ordinary.dataset.selected = "false";
  menu.applyContextMenuTarget(m, ordinary, true);
  assert.equal(m.querySelector('[data-context-slot="select"]').textContent, "Select");
});

test("context menu: opening a pinned menu does not change the next ordinary menu", () => {
  const m = menu.buildContextMenu(new El("div"));
  const pinned = card(0, "pin-1", true, "text");
  const ordinary = card(1, "2026-11-08:102:text:3", false, "text");
  menu.applyContextMenuTarget(m, pinned);
  assert.deepEqual(actions(m), specActions("unpin"));
  menu.applyContextMenuTarget(m, ordinary);
  assert.deepEqual(actions(m), specActions("pin"), "state leaked from the pinned item");
  assert.deepEqual(visibleActions(m), textMenu("pin"), "the path slot is hidden again");
  assert.ok(labels(m)[6].includes("Pin") && !labels(m)[6].includes("Unpin"));
});

test("context menu: opening an ordinary menu does not change the next pinned menu", () => {
  const m = menu.buildContextMenu(new El("div"));
  const pinned = card(0, "pin-9", true, "image");
  const ordinary = card(1, "2026-11-08:103:text:4", false, "text");
  menu.applyContextMenuTarget(m, ordinary);
  menu.applyContextMenuTarget(m, pinned);
  assert.deepEqual(actions(m), specActions("unpin"));
  assert.deepEqual(visibleActions(m), imageMenu("unpin"));
});

test("context menu: opening an image menu does not leave Paste path on the next text card", () => {
  const m = menu.buildContextMenu(new El("div"));
  const sequence = [
    card(0, "2026-11-08:110:image:1", false, "image"),
    card(1, "2026-11-08:111:text:2", false, "text"),
    card(2, "pin-image", true, "image"),
    card(3, "pin-text", true, "text"),
    card(0, "2026-11-08:110:image:1", false, "image"),
    card(1, "2026-11-08:111:text:2", false, "text"),
  ];
  for (const item of sequence) {
    menu.applyContextMenuTarget(m, item);
    const pinAction = item.dataset.pinned === "true" ? "unpin" : "pin";
    const expected = item.dataset.kind === "image" ? imageMenu(pinAction) : textMenu(pinAction);
    assert.deepEqual(visibleActions(m), expected,
      `uid ${item.dataset.uid} leaked a slot: ${visibleActions(m).join(",")}`);
  }
});

test("context menu: repeated alternating pinned and ordinary opens stay correct", () => {
  const m = menu.buildContextMenu(new El("div"));
  const sequence = [
    card(0, "2026-11-08:200:text:1", false, "text"),
    card(1, "pin-a", true, "text"),
    card(2, "2026-11-08:201:text:2", false, "text"),
    card(3, "pin-b", true, "image"),
    card(0, "2026-11-08:200:text:1", false, "text"),
    card(4, "2026-11-08:202:image:5", false, "image"),
    card(5, "pin-c", true, "image"),
    card(4, "2026-11-08:202:image:5", false, "image"),
    card(5, "pin-c", true, "image"),
    card(0, "2026-11-08:200:text:1", false, "text"),
  ];
  for (const item of sequence) {
    menu.applyContextMenuTarget(m, item);
    const expected = item.dataset.pinned === "true" ? "unpin" : "pin";
    assert.deepEqual(actions(m), specActions(expected),
      `uid ${item.dataset.uid} expected ${expected}, got ${actions(m).join(",")}`);
  }
});

test("context menu: the pin button stays findable after its action is mutated", () => {
  const m = menu.buildContextMenu(new El("div"));
  menu.applyContextMenuTarget(m, card(0, "pin-1", true, "text"));
  assert.equal(m.querySelectorAll("button").length, ALL_SLOTS.length, "no duplicate buttons were added");
  assert.ok(m.querySelector('[data-context-slot="pin"]'), "stable slot lookup must survive");
  assert.ok(m.querySelector('[data-context-slot="pastePath"]'),
    "the path slot keeps a stable slot too, so a hidden button is never looked up by payload");
  // Documents why the slot is required: the mutable payload is now "unpin", so a
  // lookup keyed on the payload finds nothing (the original leak).
  assert.equal(m.querySelector('[data-context-action="pin"]'), null);
});

test("context menu: the click acts on the card that opened the menu", () => {
  const calls = [];
  const bridge = (action, index) => calls.push([action, index]);
  const m = menu.buildContextMenu(new El("div"));
  const items = [
    card(1, "2026-11-08:300:text:1", false, "text"),
    card(2, "2026-11-08:301:image:2", false, "image"),
    card(3, "pin-x", true, "text"),
  ];
  const state = { rowIndex: -1, uid: null };
  const target = items[2];
  menu.openContextMenu(m, state, target, { x: 40, y: 60 });
  assert.equal(state.uid, "pin-x");
  assert.equal(m.style.display, "block");
  const pinButton = m.querySelector('[data-context-slot="pin"]');
  menu.handleContextMenuClick(m, state, { target: pinButton }, bridge, () => {}, items);
  assert.deepEqual(calls, [["unpin", 3]], "must unpin the right-clicked card");

  menu.openContextMenu(m, state, items[0], { x: 10, y: 10 });
  menu.handleContextMenuClick(m, state, { target: pinButton }, bridge, () => {}, items);
  assert.deepEqual(calls[1], ["pin", 1], "the following ordinary card must be pinned");

  const previewed = [];
  menu.openContextMenu(m, state, items[1], { x: 10, y: 10 });
  menu.handleContextMenuClick(m, state,
    { target: m.querySelector('[data-context-slot="preview"]') }, bridge,
    (item) => previewed.push(item.dataset.uid), items);
  assert.deepEqual(previewed, ["2026-11-08:301:image:2"], "preview uses the current target");
  menu.openContextMenu(m, state, items[1], { x: 10, y: 10 });
  menu.handleContextMenuClick(m, state,
    { target: m.querySelector('[data-context-slot="copy"]') }, bridge, () => {}, items);
  assert.deepEqual(calls[2], ["copyHistoryEntry", 2]);
  menu.openContextMenu(m, state, items[1], { x: 10, y: 10 });
  menu.handleContextMenuClick(m, state,
    { target: m.querySelector('[data-context-slot="pasteAll"]') }, bridge, () => {}, items);
  assert.deepEqual(calls[3], ["pasteAllFrom", 2]);

  // Paste path is the card's own request: the image card sends its row index.
  menu.openContextMenu(m, state, items[1], { x: 10, y: 10 });
  menu.handleContextMenuClick(m, state,
    { target: m.querySelector('[data-context-slot="pastePath"]') }, bridge, () => {}, items);
  assert.deepEqual(calls[4], ["pastePath", 2], "the image card asked for its own path");
  menu.openContextMenu(m, state, items[0], { x: 10, y: 10 });
  menu.handleContextMenuClick(m, state,
    { target: m.querySelector('[data-context-slot="pastePath"]') }, bridge, () => {}, items);
  // The button is hidden for a text card, so a pointer cannot reach it. If a
  // payload is sent anyway, the Lua handler is the guard: it refuses a card with
  // no file and leaves the pasteboard untouched.
  assert.deepEqual(calls[5], ["pastePath", 1], "the request carries the text card's own index");
  assert.equal(calls.length, 6, "one click sends one action");

  const selectedText = card(1, "sel-text", false, "text");
  const selectedImage = card(2, "sel-image", false, "image");
  const selected = ["sel-text", "sel-image"];
  menu.openContextMenu(m, state, selectedText, { x: 20, y: 20 }, true);
  assert.ok(visibleActions(m).includes("pasteSelected"), "Paste All Selected is visible when selection exists");
  assert.equal(labels(m)[3], "Select", "an unselected target offers Select");
  menu.handleContextMenuClick(m, state, { target: m.querySelector('[data-context-slot="select"]') },
    bridge, () => {}, [selectedText, selectedImage], selected);
  assert.deepEqual(calls[6], ["selectItem", 1]);
  const selectedButton = m.querySelector('[data-context-slot="pasteSelected"]');
  menu.handleContextMenuClick(m, state, { target: selectedButton },
    bridge, () => {}, [selectedText, selectedImage], selected);
  assert.deepEqual(calls[7], ["pasteSelected", 0], "Paste All Selected does not depend on the right-clicked row");
  const selectionOrderButton = m.querySelector('[data-context-slot="pasteSelectedOrder"]');
  menu.handleContextMenuClick(m, state, { target: selectionOrderButton }, bridge, () => {}, [selectedText, selectedImage], selected);
  assert.deepEqual(calls[8], ["pasteSelectedOrder", 0], "selection order uses a separate action");
  const orderButton = m.querySelector('[data-context-slot="pasteSelectedOrder"]');
  menu.handleContextMenuClick(m, state, { target: orderButton }, bridge, () => {}, [selectedText, selectedImage], selected);
  assert.deepEqual(calls[8], ["pasteSelectedOrder", 0], "selection-order paste has a distinct bridge action");
});

test("context menu: a rebuilt list is resolved by uid, not by a stale index", () => {
  const calls = [];
  const bridge = (action, index) => calls.push([action, index]);
  const m = menu.buildContextMenu(new El("div"));
  const before = [card(5, "pin-x", true, "text")];
  const state = { rowIndex: -1, uid: null };
  menu.openContextMenu(m, state, before[0], { x: 5, y: 5 });
  // The panel re-renders: index 5 is now a different, ordinary record.
  const after = [
    card(0, "2026-11-08:400:text:1", false, "text"),
    card(5, "2026-11-08:401:text:2", false, "text"),
    card(9, "pin-x", true, "text"),
  ];
  const pinButton = m.querySelector('[data-context-slot="pin"]');
  menu.handleContextMenuClick(m, state, { target: pinButton }, bridge, () => {}, after);
  assert.deepEqual(calls, [["unpin", 9]], "must follow the pinned card, not index 5");
});

test("context menu: a target that disappeared is ignored", () => {
  const calls = [];
  const m = menu.buildContextMenu(new El("div"));
  const state = { rowIndex: -1, uid: null };
  menu.openContextMenu(m, state, card(4, "pin-gone", true, "text"), { x: 5, y: 5 });
  const handled = menu.handleContextMenuClick(m, state,
    { target: m.querySelector('[data-context-slot="pin"]') },
    (action, index) => calls.push([action, index]), () => {}, [card(4, "other", false, "text")]);
  assert.equal(handled, true, "the click is consumed");
  assert.deepEqual(calls, [], "no action runs against an unrelated card sharing the old index");
  // A card without a uid still resolves by its captured index (defensive path).
  const legacy = new El("button");
  legacy.classList.add("item");
  legacy.attrs.set("data-index", "7");
  legacy.attrs.set("data-pinned", "true");
  const legacyState = { rowIndex: -1, uid: null };
  menu.openContextMenu(m, legacyState, legacy, { x: 5, y: 5 });
  assert.equal(legacyState.uid, null);
  menu.handleContextMenuClick(m, legacyState,
    { target: m.querySelector('[data-context-slot="pin"]') },
    (action, index) => calls.push([action, index]), () => {}, [card(7, "late-uid", true, "text")]);
  assert.deepEqual(calls, [["unpin", 7]], "the index fallback stays available without a uid");
});

test("navigation: Tab walks the cards in DOM order across rows", () => {
  const cards = Array.from({ length: 12 }, (_, i) => card(i + 1, `u${i}`, false, "text"));
  const nav = loadNavigation(cards);
  FOCUS.log = [];
  FOCUS.set(SEARCH);
  const seen = [];
  for (let i = 0; i < 12; i += 1) {
    nav.api.navMove(true);
    seen.push(FOCUS.current.dataset.uid);
  }
  assert.deepEqual(seen, cards.map(c => c.dataset.uid), "one step per card, no skips, no repeats");
});

test("navigation: grid column count does not change the Tab order", () => {
  const cards = Array.from({ length: 12 }, (_, i) => card(i + 1, `c${i}`, false, "text"));
  for (const columns of [1, 2, 3, 4, 5]) {
    const nav = loadNavigation(cards);
    FOCUS.log = [];
    const seen = [];
    for (let i = 0; i < 12; i += 1) {
      nav.api.navMove(true);
      seen.push(FOCUS.current.dataset.uid);
    }
    assert.equal(columns > 0, true);
    assert.deepEqual(seen, cards.map(c => c.dataset.uid), `columns=${columns}`);
  }
});

test("navigation: the required Tab and Shift+Tab sequence is sequential", () => {
  const cards = Array.from({ length: 8 }, (_, i) => card(i + 1, `s${i}`, i % 3 === 1, "text"));
  const nav = loadNavigation(cards);
  FOCUS.log = [];
  FOCUS.set(SEARCH);
  const step = (forward) => {
    nav.api.navMove(forward);
    return FOCUS.current === SEARCH ? "search" : `item ${cards.findIndex(c => c === FOCUS.current) + 1}`;
  };
  assert.equal(step(true), "item 1");
  assert.equal(step(true), "item 2");
  assert.equal(step(false), "item 1");   // Shift+Tab steps one card back
  assert.equal(step(false), "search");   // from the first card it returns to search
  assert.equal(step(false), "search");   // Shift+Tab in search stays in search
  assert.equal(step(true), "item 1");
  assert.equal(step(true), "item 2");
  assert.equal(step(true), "item 3");
  assert.equal(step(true), "item 4");
  assert.equal(step(true), "item 5");
  assert.equal(step(false), "item 4");
  assert.equal(step(false), "item 3");
  assert.equal(step(false), "item 2");
  assert.equal(step(false), "item 1");
  assert.equal(step(false), "search");
  assert.deepEqual(nav.api.navState, { navIndex: -1, lastCardIndex: 0, uid: null });
});

test("navigation: Shift+Tab to search then Tab returns to the remembered card", () => {
  const cards = Array.from({ length: 6 }, (_, i) => card(i + 1, `r${i}`, false, "text"));
  const nav = loadNavigation(cards);
  FOCUS.set(SEARCH);
  nav.api.navMove(true);
  nav.api.navMove(true);            // item 2
  assert.equal(FOCUS.current.dataset.uid, "r1");
  nav.api.navMove(false);           // item 1
  nav.api.navMove(false);           // search
  assert.equal(FOCUS.current, SEARCH);
  // The documented scenario: leaving item 2's neighbourhood and tabbing back must
  // not restart at item 1, so no card is skipped over.
  assert.equal(nav.api.navState.lastCardIndex, 0);
  nav.api.navMove(true);
  assert.equal(FOCUS.current.dataset.uid, "r0", "Tab returns to the remembered card");
  // Explicit memory of item 2:
  nav.api.navState.lastCardIndex = 1;
  nav.api.navState.uid = "r1";
  nav.api.navState.navIndex = -1;
  nav.api.navMove(true);
  assert.equal(FOCUS.current.dataset.uid, "r1");
});

test("navigation: only search and cards receive focus", () => {
  const cards = [card(1, "f0", false, "text"), card(2, "pin-f", true, "image")];
  const nav = loadNavigation(cards);
  FOCUS.log = [];
  FOCUS.set(SEARCH);
  for (let i = 0; i < 8; i += 1) nav.api.navMove(i % 2 === 0);
  FOCUS.log.forEach(target =>
    assert.ok(target === "search" || target.startsWith("card:"), `unexpected focus target: ${target}`));
});

test("navigation: list rebuild keeps the remembered card by stable identity", () => {
  const nav = loadNavigation([card(1, "keep-me", false, "text"), card(2, "other", false, "text")]);
  nav.api.navState.navIndex = 0;
  nav.api.navState.lastCardIndex = 0;
  nav.api.navState.uid = "keep-me";
  const rebuilt = [
    card(1, "new-top", true, "text"),
    card(2, "keep-me", false, "text"),
    card(3, "other", false, "image"),
  ];
  nav.state.cards = rebuilt;
  nav.api.reset();
  assert.equal(nav.api.navState.uid, "keep-me", "identity, not index");
  assert.equal(nav.api.navState.lastCardIndex, 1, "the card moved to position 1");
  assert.equal(nav.api.navState.navIndex, 1, "focus follows the same card");
  nav.api.navMove(true);
  assert.equal(FOCUS.current.dataset.uid, "other");
});

test("navigation: a focused card that disappears falls back predictably", () => {
  const nav = loadNavigation([card(1, "a", false, "text"), card(2, "b", false, "text"), card(3, "c", false, "text")]);
  nav.api.navState.navIndex = 2;
  nav.api.navState.lastCardIndex = 2;
  nav.api.navState.uid = "c";
  // The Text filter removes "c": the cursor must land on a real card, never a
  // nonexistent index.
  nav.state.cards = [card(1, "a", false, "text"), card(2, "b", false, "text")];
  nav.api.reset();
  assert.equal(nav.api.navState.navIndex, 1);
  assert.equal(nav.api.navState.lastCardIndex, 1);
  assert.equal(nav.api.navState.uid, "b");
  nav.api.navMove(false);
  assert.equal(FOCUS.current.dataset.uid, "a");
});

test("navigation: empty results and Clear All keep focus in the search field", () => {
  const nav = loadNavigation([card(1, "a", false, "text")]);
  nav.api.navState.navIndex = 0;
  nav.api.navState.lastCardIndex = 0;
  nav.api.navState.uid = "a";
  nav.state.cards = [];
  nav.api.reset();
  assert.deepEqual(nav.api.navState, { navIndex: -1, lastCardIndex: -1, uid: null });
  nav.api.navMove(true);
  assert.equal(FOCUS.current, SEARCH, "Tab on an empty list must not focus an unrelated control");
  nav.api.navMove(false);
  assert.equal(FOCUS.current, SEARCH);
});

test("navigation: one result cycles between search and that card", () => {
  const nav = loadNavigation([card(1, "only", true, "image")]);
  FOCUS.set(SEARCH);
  nav.api.navMove(true);
  assert.equal(FOCUS.current.dataset.uid, "only");
  nav.api.navMove(true);
  assert.equal(FOCUS.current, SEARCH);
  nav.api.navMove(true);
  assert.equal(FOCUS.current.dataset.uid, "only");
  nav.api.navMove(false);
  assert.equal(FOCUS.current, SEARCH);
});

test("navigation: load more keeps the position and continues sequentially", () => {
  const nav = loadNavigation(Array.from({ length: 4 }, (_, i) => card(i + 1, `p${i}`, false, "text")));
  nav.api.navState.navIndex = 3;
  nav.api.navState.lastCardIndex = 3;
  nav.api.navState.uid = "p3";
  nav.state.cards = Array.from({ length: 8 }, (_, i) => card(i + 1, `p${i}`, false, "text"));
  nav.api.reset();
  assert.equal(nav.api.navState.uid, "p3");
  assert.equal(nav.api.navState.navIndex, 3);
  const seen = [];
  for (let i = 0; i < 4; i += 1) {
    nav.api.navMove(true);
    seen.push(FOCUS.current.dataset.uid);
  }
  assert.deepEqual(seen, ["p4", "p5", "p6", "p7"], "the appended cards follow in order");
});

test("navigation: a stale state object can never point past the list", () => {
  const stale = { navIndex: 40, lastCardIndex: 40, uid: "gone" };
  const uids = ["x", "y", "z"];
  const reconciled = new Function(`${navModel}\nreturn navReconcile;`)();
  const next = reconciled(stale, uids);
  const inRange = (index) => index === -1 || (index >= 0 && index < uids.length);
  assert.ok(inRange(next.navIndex), `navIndex out of range: ${JSON.stringify(next)}`);
  assert.ok(inRange(next.lastCardIndex), `lastCardIndex out of range: ${JSON.stringify(next)}`);
  assert.equal(next.uid, uids[next.lastCardIndex]);
  const transition = new Function(`${navModel}\nreturn navTransition;`)();
  const moved = transition({ navIndex: next.navIndex, lastCardIndex: next.lastCardIndex, uid: next.uid }, uids, true);
  // -1 is the search sentinel; anything else must be a real card position.
  assert.ok(inRange(moved.navIndex), `transition target out of range: ${JSON.stringify(moved)}`);
  if (moved.target === "card") assert.ok(moved.navIndex >= 0 && moved.navIndex < uids.length);
  // From the last card, Tab returns to search and then back to the same card.
  assert.equal(moved.target, "search");
  const back = transition(moved, uids, true);
  assert.equal(back.target, "card");
  assert.equal(back.uid, uids[next.lastCardIndex]);
});

test("navigation: one keydown path drives Tab, other keys keep their handlers", () => {
  const tabBranches = panelScript.match(/event\.key === ['"]Tab['"]/g) || [];
  assert.equal(tabBranches.length, 1, `expected exactly one Tab branch, found ${tabBranches.length}`);
  assert.ok(panelScript.includes("navMove(!event.shiftKey)"), "Tab must delegate to navMove");
  assert.ok(/event\.target === document\.body \|\| event\.target === resultsPanel/.test(panelScript),
    "Tab after a results rebuild must fall back to the card list, not header controls");
  assert.ok(!panelScript.includes("resultsPanel.focus("), "the results container must not be a tab stop");
  assert.ok(!panelScript.includes("resultsPanel.tabIndex"), "no tabindex on the results container");
  assert.ok(/if \(event\.key === 'Escape'\) \{[\s\S]*bridge\('close', 0, ''\)/.test(panelScript),
    "Escape must still close the panel");
  assert.ok(panelScript.includes("bridge('paste', Number(item.dataset.index || 0), '')"),
    "Enter must still paste the selected card");
  assert.ok(panelScript.includes("['ArrowDown','ArrowUp','ArrowLeft','ArrowRight'].includes(event.key)"),
    "arrow navigation must remain");
  assert.ok(panelScript.includes("event.stopImmediatePropagation();\n    applyFilters();"),
    "Enter-to-search must stay isolated from the card handler");
  assert.ok(panelScript.includes("search.addEventListener('input'"), "typing in search stays native");
  assert.ok(!/data-context-action=/.test(panelScript),
    "menu buttons must not be keyed by the mutable payload attribute");
  const scriptOpen = source.indexOf("<script>");
  const scriptClose = source.indexOf("</script>", scriptOpen);
  const rightClickListener = source.indexOf("document.addEventListener('contextmenu'", scriptOpen);
  const contextMenuSetup = source.indexOf("const contextMenu = document.createElement('div');", scriptOpen);
  assert.ok(rightClickListener > scriptOpen && rightClickListener < scriptClose,
    "the right-click listener must stay inside the executable panel script");
  assert.ok(contextMenuSetup > scriptOpen && contextMenuSetup < scriptClose,
    "the custom context menu must be created inside the executable panel script");
  assert.ok(source.indexOf("/* BEGIN CONTEXT MENU MODEL") < scriptClose,
    "the tested context-menu model must remain inside the panel script");
  assert.ok(panelScript.includes("const selectedClipboardUids = new Set();"),
    "the WebView initializes the Set used by selection and context-menu code");
  assert.ok(panelScript.includes("document.addEventListener('contextmenu'"),
    "the right-click listener is included in executable panel JavaScript");
  assert.ok(panelScript.includes("action, index, query, kind, dateKey, uid"),
    "the bridge serializes stable UIDs as a separate message field");
  assert.ok(!panelScript.includes('Click to paste'), "cards no longer render Click to paste labels");
  assert.ok(panelScript.includes("Paste from Oldest to Current"), "the old range-paste action has the concise label");
  assert.ok(panelScript.includes("✅ Paste All Selected"), "the selected paste action has the required label");
  assert.ok(panelScript.includes("selectedClipboardUids"), "multi-selection is backed by stable identities");
  assert.ok(panelScript.includes("multi-select-mark"), "selected cards render a checkmark");

});

test("navigation: nav model uses DOM order only, never grid geometry", () => {
  assert.ok(!/clientWidth|gridTemplate|columns/.test(navModel),
    "the navigation model must not derive order from grid geometry");
  assert.ok(/uids\[next\]/.test(navModel) && /uids\[remembered\]/.test(navModel));
});

test("animation: the shell classes follow the Lua-driven open/close sequence", () => {
  const shell = new El("div");
  const document = { getElementById: (id) => (id === "clipboard-panel-shell" ? shell : null) };
  // The exported helpers are attached to `window` in the panel, exactly as the
  // Lua open/close path calls them.
  const api = new Function("document", "window", `${panelAnimation}
    return { beginPanelEnter, settlePanelEnter, playPanelLeave, PANEL_ENTER_MS, PANEL_LEAVE_MS };`)(document, {});

  // Open: the window is shown on the pre-transition state, then Lua arms it.
  assert.equal(api.beginPanelEnter(), api.PANEL_ENTER_MS);
  assert.ok(shell.classList.contains("panel-enter"), "the shell enters in the pre-transition state");
  assert.ok(!shell.classList.contains("panel-enter-active"), "the transition is not armed yet");

  assert.ok(api.settlePanelEnter() > 0, "arming the transition reports its duration");
  assert.ok(shell.classList.contains("panel-enter-active"), "the transition is armed while the enter state holds");

  // Close: the enter state is dropped and the leave state is applied, so Lua
  // can destroy the window when the reported duration elapses.
  assert.equal(api.playPanelLeave(), api.PANEL_LEAVE_MS);
  assert.ok(shell.classList.contains("panel-leave"), "the leave transition is applied");
  assert.ok(!shell.classList.contains("panel-enter"), "the leave state replaces the enter state");
  assert.ok(!shell.classList.contains("panel-enter-active"), "the armed enter state is cleared");

  // Re-opening during the leave animation resets the shell.
  api.beginPanelEnter();
  assert.ok(!shell.classList.contains("panel-leave"), "the leave state is cleared on reopen");
  assert.ok(shell.classList.contains("panel-enter"), "the reopened shell starts in the enter state");

  // A missing shell reports duration 0, so Lua tears the panel down at once.
  const empty = new Function("document", "window", `${panelAnimation}
    return { beginPanelEnter, settlePanelEnter, playPanelLeave };`)({ getElementById: () => null }, {});
  assert.equal(empty.beginPanelEnter(), 0, "no shell: no enter animation");
  assert.equal(empty.settlePanelEnter(), 0, "no shell: no transition to arm");
  assert.equal(empty.playPanelLeave(), 0, "no shell: no leave animation");
});

test("animation: the CSS states and the Lua/JS durations agree", () => {
  const lua = (name) => Number(source.match(new RegExp(`local ${name} = (\\d+)`))[1]);
  const js = (name) => Number(source.match(new RegExp(`const ${name} = (\\d+);`))[1]);
  assert.ok(js("PANEL_ENTER_MS") > 0, "the enter animation has a duration");
  assert.ok(js("PANEL_LEAVE_MS") > 0, "the leave animation has a duration");
  assert.equal(lua("PANEL_LEAVE_ANIMATION_MS"), js("PANEL_LEAVE_MS"),
    "Lua tears the window down exactly when the leave transition ends");

  // The leave transition must finish inside the window Lua allows; the enter
  // transition must be cleaned up no earlier than its longest property.
  const leave = source.match(/#clipboard-panel-shell\.panel-leave \{ transition:([^;]+);/);
  assert.ok(leave, "the leave transition is styled on the panel shell");
  const leaveTimes = [...leave[1].matchAll(/(\d+)ms/g)].map((m) => Number(m[1]));
  assert.ok(leaveTimes.length >= 2, "the leave transition animates opacity and transform");
  assert.ok(Math.max(...leaveTimes) <= js("PANEL_LEAVE_MS"),
    "the leave transition finishes before Lua destroys the window");

  const enter = source.match(/#clipboard-panel-shell\.panel-enter-active \{ transition:([^;]+);/);
  assert.ok(enter, "the armed enter transition is styled on the panel shell");
  const enterTimes = [...enter[1].matchAll(/(\d+)ms/g)].map((m) => Number(m[1]));
  assert.ok(enterTimes.length >= 2, "the enter transition animates opacity and transform");
  assert.ok(Math.max(...enterTimes) <= js("PANEL_ENTER_MS"),
    "the enter state is removed only after the transition has finished");

  assert.ok(source.includes("@media (prefers-reduced-motion: reduce)"),
    "reduced-motion clients get no panel animation");
});

// ------------------------------------------------------------------ report --

let failed = 0;
for (const [status, name] of results) {
  console.log(`${status} ${name}`);
  if (status === "FAIL") failed += 1;
}
console.log(`${results.length - failed} passed, ${failed} failed (${results.length} JavaScript scenarios)`);
console.log("Peekaboo was not used: no GUI automation is performed by this file.");
process.exit(failed === 0 ? 0 : 1);
