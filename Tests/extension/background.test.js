// Runs ChromeExtension/background.js under Node against a stand-in for chrome.bookmarks
// that follows Chrome's rules: move() counts positions before taking the bookmark out,
// an index past the end is an error, and a URL without a scheme is rejected.
//
//   node Tests/extension/background.test.js
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

function makeChrome(roots) {
  const nodes = new Map();
  let nextId = 100;
  const sent = [];
  const listeners = {};
  const storage = {};
  const index = (n) => { nodes.set(n.id, n); (n.children || []).forEach((c) => { c.parentId = n.id; index(c); }); };
  const root = { id: "0", title: "", children: roots };
  index(root);
  const need = (id) => { const n = nodes.get(id); if (!n) throw new Error("Can't find bookmark for id."); return n; };
  const view = (n) => ({ id: n.id, title: n.title, url: n.url, parentId: n.parentId, index: need(n.parentId).children.indexOf(n) });
  const fire = (name) => (listeners[name] || []).forEach((f) => f());
  const event = (name) => ({ addListener: (f) => (listeners[name] = listeners[name] || []).push(f) });

  const bookmarks = {
    getTree: async () => [root],
    get: async (id) => [view(need(id))],
    getChildren: async (id) => need(id).children.map(view),
    create: async ({ parentId, index: i, title, url }) => {
      const parent = need(parentId);
      if (url !== undefined && !/^[a-z][a-z0-9+.-]*:/i.test(url)) throw new Error("Invalid URL.");
      if (i > parent.children.length) throw new Error("Index out of bounds.");
      const n = { id: String(nextId++), title, parentId };
      if (url !== undefined) n.url = url; else n.children = [];
      parent.children.splice(i === undefined ? parent.children.length : i, 0, n);
      nodes.set(n.id, n);
      fire("onCreated");
      return view(n);
    },
    update: async (id, changes) => { Object.assign(need(id), changes); fire("onChanged"); return view(need(id)); },
    move: async (id, { parentId, index: i }) => {
      const n = need(id), from = need(n.parentId), to = need(parentId);
      if (i > to.children.length) throw new Error("Index out of bounds.");
      const old = from.children.indexOf(n);
      from.children.splice(old, 1);
      // Chrome's index refers to positions before the bookmark was taken out.
      const at = from === to && old < i ? i - 1 : i;
      to.children.splice(at, 0, n);
      n.parentId = parentId;
      fire("onMoved");
      return view(n);
    },
    removeTree: async (id) => {
      const n = need(id);
      const p = need(n.parentId);
      p.children.splice(p.children.indexOf(n), 1);
      nodes.delete(id);
      fire("onRemoved");
    },
  };
  for (const e of ["onCreated", "onRemoved", "onChanged", "onMoved", "onChildrenReordered", "onImportEnded"]) bookmarks[e] = event(e);

  const chrome = {
    bookmarks,
    runtime: {
      connectNative: () => ({
        onMessage: { addListener: () => {} },
        onDisconnect: { addListener: () => {} },
        postMessage: (m) => sent.push(m),
      }),
      onStartup: event("onStartup"),
      onInstalled: event("onInstalled"),
      lastError: undefined,
    },
    alarms: { create: () => {}, onAlarm: event("onAlarm") },
    storage: { local: {
      get: async (key) => (key in storage ? { [key]: storage[key] } : {}),
      set: async (obj) => Object.assign(storage, obj),
    } },
  };
  const titles = (id) => need(id).children.map((c) => c.title);
  return { chrome, sent, titles, need };
}

function load(roots) {
  const env = makeChrome(roots);
  const context = vm.createContext({
    chrome: env.chrome, setTimeout, clearTimeout, Date, Promise, Math, Infinity, String, Error,
    crypto: require("crypto").webcrypto, console,
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, "../../ChromeExtension/background.js"), "utf8"), context);
  return { ...env, context };
}

const bm = (id, title) => ({ id, title, url: "https://" + title + ".example/" });
const standardRoots = () => [
  { id: "1", title: "Bookmarks bar", children: [bm("10", "a"), bm("11", "b"), bm("12", "c"), bm("13", "d")] },
  { id: "2", title: "Other bookmarks", children: [] },
  { id: "3", title: "Mobile bookmarks", children: [] },
];

const tests = {
  async "move later in the same folder ends at the wanted position"() {
    const { context, titles } = load(standardRoots());
    await context.apply([{ op: "move", id: "10", parentId: "1", index: 2 }]);
    assert.deepStrictEqual(titles("1"), ["b", "c", "a", "d"]);
  },
  async "move to the very end of the same folder"() {
    const { context, titles } = load(standardRoots());
    await context.apply([{ op: "move", id: "10", parentId: "1", index: 3 }]);
    assert.deepStrictEqual(titles("1"), ["b", "c", "d", "a"]);
  },
  async "move earlier in the same folder"() {
    const { context, titles } = load(standardRoots());
    await context.apply([{ op: "move", id: "13", parentId: "1", index: 1 }]);
    assert.deepStrictEqual(titles("1"), ["a", "d", "b", "c"]);
  },
  async "move to another folder, index past the end is clamped"() {
    const { context, titles } = load(standardRoots());
    await context.apply([{ op: "move", id: "11", parentId: "2", index: 5 }]);
    assert.deepStrictEqual(titles("1"), ["a", "c", "d"]);
    assert.deepStrictEqual(titles("2"), ["b"]);
  },
  async "created folder can be used as a parent later in the batch"() {
    const { context, titles } = load(standardRoots());
    const created = await context.apply([
      { op: "create", tempId: "t1", parentId: "2", index: 0, title: "Folder" },
      { op: "create", tempId: "t2", parentId: "t1", index: 9, title: "inner", url: "https://inner.example/" },
      { op: "move", id: "10", parentId: "t1", index: 0 },
      { op: "update", id: "t2", title: "renamed" },
    ]);
    assert.deepStrictEqual(titles("2"), ["Folder"]);
    assert.deepStrictEqual(titles(created.t1), ["a", "renamed"]);
  },
  async "an empty-string URL still creates a bookmark, not a folder"() {
    const { context } = load(standardRoots());
    await assert.rejects(context.apply([{ op: "create", tempId: "t", parentId: "1", index: 0, title: "blank", url: "" }]), /blank/);
  },
  async "removing something already gone is not an error"() {
    const { context, titles } = load(standardRoots());
    await context.apply([{ op: "remove", id: "999" }, { op: "remove", id: "10" }]);
    assert.deepStrictEqual(titles("1"), ["b", "c", "d"]);
  },
  async "a rejected bookmark is named in the error"() {
    const { context } = load(standardRoots());
    await assert.rejects(
      context.apply([{ op: "create", tempId: "t", parentId: "1", index: 0, title: "Bad One", url: "no-scheme" }]),
      /Bad One.*Invalid URL/
    );
  },
  async "tree has bar, other and a stable profile id; mobile is left out"() {
    const { context } = load(standardRoots());
    const first = await context.readTree();
    const second = await context.readTree();
    assert.strictEqual(first.bar.id, "1");
    assert.strictEqual(first.other.id, "2");
    assert.strictEqual(first.bar.children.length, 4);
    assert.ok(first.profile && first.profile === second.profile);
    assert.ok(!JSON.stringify(first).includes("Mobile"));
  },
  async "with local and account folders, the syncing ones are used"() {
    const { context } = load([
      { id: "1", title: "Bookmarks bar", folderType: "bookmarks-bar", syncing: false, children: [] },
      { id: "2", title: "Other bookmarks", folderType: "other", syncing: false, children: [] },
      { id: "7", title: "Bookmarks bar", folderType: "bookmarks-bar", syncing: true, children: [] },
      { id: "8", title: "Other bookmarks", folderType: "other", syncing: true, children: [] },
    ]);
    const tree = await context.readTree();
    assert.strictEqual(tree.bar.id, "7");
    assert.strictEqual(tree.other.id, "8");
  },
  async "our own edits do not send a change event; the user's do"() {
    const { context, chrome, sent } = load(standardRoots());
    await context.apply([{ op: "update", id: "10", title: "ours" }]);
    await new Promise((r) => setTimeout(r, 1200));
    assert.strictEqual(sent.filter((m) => m.event).length, 0);
    await chrome.bookmarks.update("11", { title: "theirs" });
    await new Promise((r) => setTimeout(r, 700));
    assert.strictEqual(sent.filter((m) => m.event === "changed").length, 1);
  },
};

(async () => {
  let failed = 0;
  for (const [name, fn] of Object.entries(tests)) {
    try { await fn(); console.log("ok   " + name); }
    catch (e) { failed += 1; console.log("FAIL " + name + "\n     " + String(e.message).split("\n")[0]); }
  }
  console.log(`${Object.keys(tests).length - failed}/${Object.keys(tests).length} passed`);
  process.exit(failed ? 1 : 0);
})();
