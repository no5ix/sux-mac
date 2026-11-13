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
    `${menuModel}\n${multiSelectionBinding}\nreturn { CONTEXT_MENU_ITEMS, contextMenuSpec, buildContextMenu, applyContextMenuTarget, openContextMenu, findContextRow, handleContextMenuClick, syncClipboardMultiSelection };`)(
    document, window, rows, selectedClipboardUids);
  api.selectedClipboardUids = selectedClipboardUids;
  api.setRows = (cards) => { state.cards = cards; };
  return api;
}


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
});


test("context menu layout: divider separates ordinary actions from paste actions", () => {
  const m = menu.buildContextMenu(new El("div"));
  const slots = m.children.map(node => node.getAttribute("data-context-slot"));
  assert.deepEqual(slots, [
    "preview", "copy", "pin", "divider", "pasteAll",
    "select", "pasteSelected", "pasteSelectedOrder", "pastePath",
  ]);
  const divider = m.querySelector('[data-context-slot="divider"]');
  assert.equal(divider.getAttribute("role"), "separator");
  assert.ok(divider.style.cssText.includes("height:1px"));
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
    modelSource.includes("bridge('pasteAllFromPaths', rowIndex, '')"),
    "Paste from Current to First image variant must dispatch its range action");
  assert.ok(source.includes('elseif body.action == "copyPath"') &&
    source.includes("copyOrPasteImagePathEntry(tonumber(body.index), false)"),
    "Lua must handle Copy Path and write the resolved path to the pasteboard");

  const engineStart = source.indexOf("local function pasteAllRowsStep");
  const engineEnd = source.indexOf("\\nfunction pasteAllWithDelimiterRecursionVersion", engineStart);
  const engine = source.slice(engineStart, engineEnd);
  assert.ok(engine.includes("local function pasteAllRowsStep(position, direction, pathMode)"));
  assert.ok(!/pasteAllRowsStep\\(position \\+ direction, direction\\)/.test(engine),
    "no recursive batch step may drop pathMode");
  assert.ok(engine.includes("pasteAllRowsStep(position + direction, direction, pathMode)"),
    "every next-item callback keeps pathMode");
  const recursiveSteps = engine.match(/pasteAllRowsStep\\(position \\+ direction, direction, pathMode\\)/g) || [];
  assert.ok(recursiveSteps.length >= 4,
    "pathMode must flow through each retry and delayed next-item callback");

  const rangeStart = source.indexOf("function pasteSomeWithDelimiterFromStartRow(startRow, pathMode)");
  const rangeEnd = source.indexOf("\\npasteSelectedClipboardItems = function", rangeStart);
  const range = source.slice(rangeStart, rangeEnd);
  assert.ok(range.includes("pasteAllRowsStep(1, 1, pathMode == true)"),
    "range image-path paste must start the engine in path mode");
  assert.ok(source.includes('pasteSelectedClipboardItems(body.query, "chronological", true)'));
  assert.ok(source.includes('pasteSelectedClipboardItems(body.query, "selection", true)'));
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


test("context menu divider separates ordinary actions from Select", () => {
  const m = menu.buildContextMenu(new El("div"));
  const slots = m.children.map(node => node.getAttribute("data-context-slot"));
  const firstDivider = slots.indexOf("divider");
  const selectIndex = slots.indexOf("select");
  assert.ok(firstDivider >= 0 && firstDivider < selectIndex,
    "the first divider is immediately above the Select action");
  assert.equal(slots.filter(slot => slot === "divider").length, 3,
    "the menu keeps separate ordinary, selection, and image-section separators");

  const textTarget = card(0, "select-divider-text", false, "text");
  menu.applyContextMenuTarget(m, textTarget, false, false);
  const dividers = m.querySelectorAll('[data-context-slot="divider"]');
  assert.equal(dividers[0].style.display, "block", "ordinary/selection divider remains visible");
  assert.equal(dividers[1].style.display, "block", "selection/image divider remains visible above Select group");
  assert.equal(dividers[2].style.display, "none", "hidden image section has no trailing divider");
});

// ------------------------------------------------------------------- tests --

const results = [];
function test(name, body) {
  try {
    body();
    results.push(["PASS", name]);
  } catch (error) {
    results.push(["FAIL", `${name} :: ${error && error.message ? error.message : error}`]);
  }
}

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

// ------------------------------------------------------------------ report --

let failed = 0;
for (const [status, name] of results) {
  console.log(`${status} ${name}`);
  if (status === "FAIL") failed += 1;
}
console.log(`${results.length - failed} passed, ${failed} failed (${results.length} JavaScript scenarios)`);
console.log("Peekaboo was not used: no GUI automation is performed by this file.");
process.exit(failed === 0 ? 0 : 1);
