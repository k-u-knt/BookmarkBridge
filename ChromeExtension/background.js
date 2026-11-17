// BookmarkBridge extension: the Mac app's hands inside Chrome.
// It answers two commands from the app (getTree, apply) and tells the app when
// bookmarks change. All sync decisions are made by the app.

const HOST = "io.github.k_u_knt.bookmarkbridge";

let port = null;
let quietUntil = 0;       // change events before this time are our own edits
let changeTimer = null;
let queue = Promise.resolve();

function connect() {
  if (port) return;
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (e) {
    port = null;
    return;
  }
  port.onMessage.addListener((message) => {
    // One command at a time, in arrival order.
    queue = queue.then(() => handle(message));
  });
  port.onDisconnect.addListener(() => {
    void chrome.runtime.lastError;   // the app is not running; the alarm retries
    port = null;
  });
}

function send(message) {
  try {
    if (port) port.postMessage(message);
  } catch (e) {
    port = null;
  }
}

async function handle(message) {
  try {
    if (message.cmd === "getTree") {
      send({ id: message.id, ok: true, tree: await readTree() });
    } else if (message.cmd === "apply") {
      send({ id: message.id, ok: true, created: await apply(message.ops) });
    } else {
      send({ id: message.id, ok: false, error: "unknown command " + message.cmd });
    }
  } catch (e) {
    send({ id: message.id, ok: false, error: String((e && e.message) || e) });
  }
}

// The two folders that sync. Newer Chrome labels them with folderType; older
// versions use fixed IDs. With both local and account folders present, the
// account ones are what the user sees first.
function pickRoot(roots, folderType, fallbackId) {
  const typed = roots.filter((n) => n.folderType === folderType);
  if (typed.length) return typed.find((n) => n.syncing) || typed[0];
  return roots.find((n) => n.id === fallbackId);
}

function slim(node) {
  const out = { id: node.id, title: node.title };
  if (node.url) out.url = node.url;
  else out.children = (node.children || []).map(slim);
  return out;
}

// A random ID for this Chrome profile, so the app can tell if a different profile connects.
async function profileId() {
  const stored = await chrome.storage.local.get("profileId");
  if (stored.profileId) return stored.profileId;
  const id = crypto.randomUUID();
  await chrome.storage.local.set({ profileId: id });
  return id;
}

async function readTree() {
  const [root] = await chrome.bookmarks.getTree();
  const bar = pickRoot(root.children, "bookmarks-bar", "1");
  const other = pickRoot(root.children, "other", "2");
  if (!bar || !other) throw new Error("could not find Chrome's bookmark folders");
  return { bar: slim(bar), other: slim(other), profile: await profileId() };
}

async function apply(ops) {
  const created = {};
  const real = (id) => created[id] || id;
  quietUntil = Infinity;
  try {
    for (const op of ops) {
     try {
      if (op.op === "create") {
        const parentId = real(op.parentId);
        const count = (await chrome.bookmarks.getChildren(parentId)).length;
        const details = { parentId, index: Math.min(op.index, count), title: op.title };
        if (op.url !== undefined) details.url = op.url;
        created[op.tempId] = (await chrome.bookmarks.create(details)).id;
      } else if (op.op === "update") {
        const changes = { title: op.title };
        if (op.url !== undefined) changes.url = op.url;
        await chrome.bookmarks.update(real(op.id), changes);
      } else if (op.op === "move") {
        const id = real(op.id);
        const parentId = real(op.parentId);
        const [node] = await chrome.bookmarks.get(id);
        const siblings = await chrome.bookmarks.getChildren(parentId);
        const sameParent = node.parentId === parentId;
        // op.index is where the bookmark should end up. Chrome counts positions
        // before taking the bookmark out, so moving later within one folder needs +1.
        let index = Math.min(op.index, sameParent ? siblings.length - 1 : siblings.length);
        if (sameParent && node.index < index) index += 1;
        if (!(sameParent && node.index === index)) await chrome.bookmarks.move(id, { parentId, index });
      } else if (op.op === "remove") {
        try {
          await chrome.bookmarks.removeTree(real(op.id));
        } catch (e) {
          // already gone
        }
      }
     } catch (e) {
      // Name the bookmark, so the person can find and fix it in the other browser.
      const what = op.title ? `“${op.title}”` : `bookmark ${op.id}`;
      throw new Error(`could not ${op.op} ${what}: ${(e && e.message) || e}`);
     }
    }
  } finally {
    quietUntil = Date.now() + 500;
  }
  return created;
}

function changed() {
  if (Date.now() < quietUntil) return;
  clearTimeout(changeTimer);
  changeTimer = setTimeout(() => send({ event: "changed" }), 500);
}

for (const event of ["onCreated", "onRemoved", "onChanged", "onMoved", "onChildrenReordered", "onImportEnded"]) {
  chrome.bookmarks[event].addListener(changed);
}

chrome.alarms.create("reconnect", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(connect);
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
connect();
