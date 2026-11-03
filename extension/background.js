// CosmoGrav extension: background worker.
// Talks only to the CosmoGrav app on this computer (Chrome "native messaging"). No servers, no analytics.
import { HOST, QUALITIES, QUALITY_IDS, getSettings, isNewer, isWebLink } from "./lib/shared.js";
import { collectMedia } from "./lib/collect.js";
import "./lib/originals.js";

const VERSION = chrome.runtime.getManifest().version;
const HOVER_SCRIPT_ID = "cosmograv-hover";

// ---------- Talking to the app ----------

async function ask(message) {
  try {
    const reply = await chrome.runtime.sendNativeMessage(HOST, message);
    if (reply && typeof reply === "object") return reply;
    return { ok: false, error: "CosmoGrav didn't answer." };
  } catch (e) {
    return { ok: false, notConnected: true, error: String(e && e.message || e) };
  }
}

/** Version handshake. The app ships the matching extension, so when the app updates, this extension follows. */
async function hello() {
  const reply = await ask({ type: "hello", extension: VERSION });
  const state = {
    checked: Date.now(),
    connected: !!reply.ok,
    app: reply.app || null,
    bundled: reply.bundledExtension || null,
    folder: reply.extensionFolder || null,
    running: !!reply.running,
    status: reply.status || null,
    error: reply.ok ? null : reply.error,
  };
  await chrome.storage.session.set({ app: state });
  if (reply.ok && reply.bundledExtension && isNewer(reply.bundledExtension, VERSION)) {
    // The app has already copied the newer extension into the folder Chrome loads it from,
    // so a reload picks it up. Only try once per version, in case it was loaded from somewhere else.
    const { reloadedFor } = await chrome.storage.local.get("reloadedFor");
    if (reloadedFor !== reply.bundledExtension) {
      await chrome.storage.local.set({ reloadedFor: reply.bundledExtension });
      setTimeout(() => chrome.runtime.reload(), 300);
    }
  }
  updateBadge(state.status);
  return state;
}

function updateBadge(status) {
  const busy = status ? (status.active || 0) + (status.waiting || 0) : 0;
  chrome.action.setBadgeBackgroundColor({ color: "#b3753d" }).catch(() => {});
  chrome.action.setBadgeText({ text: busy > 0 ? String(busy) : "" }).catch(() => {});
  // While something downloads, refresh the badge every minute; otherwise once an hour.
  chrome.alarms.create("hello", { periodInMinutes: busy > 0 ? 1 : 60 });
}

/**
 * Sends links to CosmoGrav.
 * opts: quality, start, from, to (seconds, trims one video), mode ("queue" or "import"), name, focus.
 */
async function send(items, opts = {}, tab) {
  const settings = await getSettings();
  const clean = [];
  const seen = new Set();
  for (const it of items || []) {
    const url = typeof it === "string" ? it : it && it.url;
    if (!isWebLink(url) || seen.has(url)) continue;
    seen.add(url);
    clean.push({ url, title: typeof it === "object" && it.title ? String(it.title).slice(0, 300) : undefined });
    if (clean.length >= 1000) break;
  }
  if (!clean.length) return { ok: false, error: "There's no web link to send here." };
  const quality = QUALITY_IDS.includes(opts.quality) ? opts.quality : settings.quality;
  const message = {
    type: "add",
    items: clean,
    quality,
    start: opts.start ?? settings.autoStart,
    focus: opts.focus ?? (settings.focusApp || opts.mode === "import"),
    mode: opts.mode === "import" ? "import" : "queue",
    name: opts.name ? String(opts.name).slice(0, 120) : undefined,
  };
  if (clean.length === 1) {
    if (Number.isFinite(opts.from) && opts.from >= 0) message.from = Math.round(opts.from * 10) / 10;
    if (Number.isFinite(opts.to) && opts.to > (message.from || 0) + 0.5) message.to = Math.round(opts.to * 10) / 10;
  }
  const reply = await ask(message);
  if (reply.ok) {
    updateBadge(reply.status);
    const label = QUALITIES.find((q) => q.id === quality)?.short || "";
    const what = clean.length === 1 ? "Sent to CosmoGrav" : `${clean.length} links sent to CosmoGrav`;
    return { ok: true, message: message.mode === "import" ? `${clean.length} links opened in CosmoGrav's Import window` : `${what} · ${label}` };
  }
  if (reply.notConnected) {
    // CosmoGrav 1.7 or newer is needed. If it is installed but this browser isn't set up yet,
    // its web link still works for one video (Chrome asks "Open CosmoGrav?" the first time).
    if (clean.length === 1 && tab && tab.id >= 0) {
      const q = new URLSearchParams({ url: clean[0].url, quality });
      chrome.tabs.update(tab.id, { url: `cosmograv://add?${q}` }).catch(() => {});
      return { ok: true, message: "Opening CosmoGrav… If nothing happens, open CosmoGrav once and try again." };
    }
    return { ok: false, notConnected: true, error: "CosmoGrav isn't connected. Open the CosmoGrav app once (version 1.7 or newer), then try again." };
  }
  return { ok: false, error: reply.error || "CosmoGrav couldn't take that link." };
}

// ---------- A small message on the page after right-click and keyboard sends ----------

function pageToast(text, ok) {
  const id = "cosmograv-toast-bg";
  document.getElementById(id)?.remove();
  const el = document.createElement("div");
  el.id = id;
  el.setAttribute("role", "status");
  el.textContent = text;
  Object.assign(el.style, {
    position: "fixed", right: "20px", bottom: "20px", zIndex: 2147483647, padding: "10px 16px",
    borderRadius: "999px", background: "#141313", color: "rgba(255,255,255,.92)",
    font: "500 12.5px/1.3 -apple-system, 'SF Pro Text', 'Segoe UI', system-ui, sans-serif",
    boxShadow: ok ? "inset 0 0 0 1px rgba(237,194,135,.35), 0 0 18px rgba(237,194,135,.25)" : "inset 0 0 0 1px rgba(245,117,102,.45)",
    opacity: "0", transform: "translateY(8px)", transition: "opacity .55s cubic-bezier(.45,0,.2,1), transform .55s cubic-bezier(.45,0,.2,1)",
    maxWidth: "380px",
  });
  document.documentElement.appendChild(el);
  requestAnimationFrame(() => { el.style.opacity = "1"; el.style.transform = "none"; });
  setTimeout(() => { el.style.opacity = "0"; setTimeout(() => el.remove(), 600); }, 3200);
}

async function toast(tab, result) {
  if (!tab || tab.id < 0) return;
  const settings = await getSettings();
  if (!settings.toast && result.ok) return;
  chrome.scripting.executeScript({ target: { tabId: tab.id }, func: pageToast, args: [result.ok ? result.message : result.error, !!result.ok] }).catch(() => {});
}

// ---------- Right-click menu ----------

const MEDIA_CONTEXTS = ["link", "video", "audio", "image", "page", "frame"];

function buildMenus() {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({ id: "cg-default", title: "Download with CosmoGrav", contexts: MEDIA_CONTEXTS });
    chrome.contextMenus.create({ id: "cg-as", title: "Download with CosmoGrav as", contexts: ["link", "video", "audio", "page", "frame"] });
    for (const q of QUALITIES) chrome.contextMenus.create({ id: `cg-q-${q.id}`, parentId: "cg-as", title: q.label, contexts: ["link", "video", "audio", "page", "frame"] });
    chrome.contextMenus.create({ id: "cg-selection", title: "Download every link in the selection", contexts: ["selection"] });
    chrome.contextMenus.create({ id: "cg-grab", title: "Grab all media on this page…", contexts: ["page", "frame"] });
  });
}

/** The best link for what was right-clicked. */
function linkFor(info, tab) {
  if (info.mediaType === "image" && info.srcUrl && isWebLink(info.srcUrl)) return globalThis.CosmoOriginals.original(info.srcUrl);
  if (info.linkUrl && isWebLink(info.linkUrl)) return info.linkUrl;
  if ((info.mediaType === "video" || info.mediaType === "audio") && info.srcUrl && isWebLink(info.srcUrl) && !/^blob:/.test(info.srcUrl)) {
    // A plain file (.mp4) plays straight from its link; streamed players (blob:) are read from the page instead.
    if (/\.(mp4|mov|m4v|webm|mp3|m4a|wav|ogg|opus)(\?|$)/i.test(info.srcUrl)) return info.srcUrl;
  }
  return info.frameUrl && info.frameUrl !== info.pageUrl && isWebLink(info.frameUrl) ? info.frameUrl : (info.pageUrl || tab?.url);
}

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId === "cg-grab") return grab(tab);
  if (info.menuItemId === "cg-selection") {
    let links = [];
    try {
      const [res] = await chrome.scripting.executeScript({
        target: { tabId: tab.id, frameIds: [info.frameId || 0] },
        func: () => {
          const sel = getSelection();
          const found = new Set();
          for (let i = 0; i < sel.rangeCount; i++) {
            const frag = sel.getRangeAt(i).cloneContents();
            frag.querySelectorAll("a[href]").forEach((a) => found.add(new URL(a.getAttribute("href"), location.href).href));
          }
          (sel.toString().match(/https?:\/\/[^\s<>"')\]]+/g) || []).forEach((u) => found.add(u));
          return [...found];
        },
      });
      links = res?.result || [];
    } catch {
      links = (info.selectionText || "").match(/https?:\/\/[^\s<>"')\]]+/g) || [];
    }
    const result = links.length > 1 ? await send(links, { mode: "import", name: tab?.title || "Selected links" }, tab) : await send(links, {}, tab);
    return toast(tab, result);
  }
  const quality = String(info.menuItemId).startsWith("cg-q-") ? String(info.menuItemId).slice(5) : undefined;
  const url = linkFor(info, tab);
  const title = url === tab?.url ? tab?.title : undefined;
  toast(tab, await send([{ url, title }], { quality }, tab));
});

// ---------- Link grabber ----------

async function grab(tab) {
  if (!tab || tab.id < 0) return;
  let data;
  try {
    await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ["lib/originals.js"] });
    const [res] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: collectMedia });
    data = res?.result;
  } catch (e) {
    return toast(tab, { ok: false, error: "Chrome doesn't let extensions read this page." });
  }
  if (!data) return;
  const id = String(Date.now());
  await chrome.storage.session.set({ [`grab:${id}`]: data });
  chrome.tabs.create({ url: chrome.runtime.getURL(`pages/grab.html?id=${id}`), index: tab.index + 1, openerTabId: tab.id });
}

// ---------- Keyboard shortcuts ----------

chrome.commands.onCommand.addListener(async (command, tab) => {
  tab = tab || (await chrome.tabs.query({ active: true, currentWindow: true }))[0];
  if (command === "grab-page") return grab(tab);
  if (command === "send-tab" && tab) toast(tab, await send([{ url: tab.url, title: tab.title }], {}, tab));
});

// ---------- Hover button on every site (only with the optional "all sites" permission) ----------

async function syncHoverScript() {
  const settings = await getSettings();
  const granted = await chrome.permissions.contains({ origins: ["<all_urls>"] });
  const want = granted && settings.hoverEverywhere;
  const existing = await chrome.scripting.getRegisteredContentScripts({ ids: [HOVER_SCRIPT_ID] }).catch(() => []);
  if (want && !existing.length) {
    await chrome.scripting.registerContentScripts([{
      id: HOVER_SCRIPT_ID,
      matches: ["https://*/*", "http://*/*"],
      excludeMatches: ["https://www.youtube.com/*", "https://m.youtube.com/*"],
      js: ["lib/originals.js", "content/common.js", "content/hover.js"],
      css: ["content/cosmograv.css"],
      runAt: "document_idle",
      persistAcrossSessions: true,
    }]).catch(() => {});
  } else if (!want && existing.length) {
    await chrome.scripting.unregisterContentScripts({ ids: [HOVER_SCRIPT_ID] }).catch(() => {});
  }
}

chrome.permissions.onAdded.addListener(syncHoverScript);
chrome.permissions.onRemoved.addListener(syncHoverScript);
chrome.storage.onChanged.addListener((changes, area) => { if (area === "local" && changes.settings) syncHoverScript(); });

// ---------- Messages from the popup, settings page and in-page buttons ----------

chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  (async () => {
    switch (msg && msg.type) {
      case "send": return send(msg.items, msg.opts || {}, sender.tab || msg.tab);
      case "hello": return hello();
      case "status": {
        const r = await ask({ type: "status" });
        if (r.ok) updateBadge(r.status);
        return r;
      }
      case "open": return ask({ type: "open", what: msg.what === "folder" ? "folder" : "app" });
      case "grab": return grab(msg.tab);
      case "settings": return getSettings();
      default: return { ok: false };
    }
  })().then(reply, (e) => reply({ ok: false, error: String(e) }));
  return true;
});

chrome.alarms.onAlarm.addListener((a) => { if (a.name === "hello") hello(); });

chrome.runtime.onInstalled.addListener(async (details) => {
  buildMenus();
  await syncHoverScript();
  const state = await hello();
  if (details.reason === "install") chrome.tabs.create({ url: chrome.runtime.getURL("pages/settings.html?welcome=1") });
  return state;
});
chrome.runtime.onStartup.addListener(() => { hello(); syncHoverScript(); });
