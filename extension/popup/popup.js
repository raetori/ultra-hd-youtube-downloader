import { QUALITIES, getSettings, saveSettings, isNewer, isWebLink } from "../lib/shared.js";

const $ = (id) => document.getElementById(id);
const VERSION = chrome.runtime.getManifest().version;
let tab = null;

function setResult(text, ok) {
  const r = $("result");
  r.textContent = text || "";
  r.className = `small result ${text ? (ok ? "ok" : "bad") : ""}`;
}

function showState(state) {
  const chip = $("status");
  if (state.connected) {
    chip.className = "chip chip-gold";
    chip.lastElementChild.textContent = `Connected · ${state.app}`;
    $("offline").hidden = true;
  } else {
    chip.className = "chip chip-danger";
    chip.lastElementChild.textContent = "Not connected";
    $("offline").hidden = false;
  }
  // The app ships the extension that matches it, so the two stay on the same version.
  if (state.connected && state.app && isNewer(VERSION, state.app)) {
    $("update").hidden = false;
    $("update-text").textContent = `This extension is ${VERSION}, the app is ${state.app}. Open CosmoGrav and click Update now so every feature works.`;
  }
  renderQueue(state.status);
}

function renderQueue(status) {
  const list = $("items");
  const items = (status && status.items) || [];
  $("queue").hidden = !items.length;
  if (!items.length) return;
  const parts = [];
  if (status.active) parts.push(`${status.active} downloading`);
  if (status.waiting) parts.push(`${status.waiting} waiting`);
  if (status.done) parts.push(`${status.done} done`);
  $("counts").textContent = parts.join(" · ");
  list.replaceChildren(...items.slice(0, 6).map((it) => {
    const li = document.createElement("li");
    li.className = it.state;
    const t = document.createElement("div"); t.className = "t"; t.textContent = it.title || "Link";
    const d = document.createElement("div"); d.className = "d"; d.textContent = it.detail || it.state;
    li.append(t, d);
    if (it.state === "downloading" || it.state === "converting") {
      const bar = document.createElement("div"); bar.className = "orbbar";
      const fill = document.createElement("i"); fill.style.setProperty("--p", Math.max(0, Math.min(1, it.progress || 0)));
      bar.append(fill); li.append(bar);
    }
    return li;
  }));
}

async function init() {
  const settings = await getSettings();
  const select = $("quality");
  for (const q of QUALITIES) select.append(new Option(q.name, q.id, false, q.id === settings.quality));
  select.addEventListener("change", () => saveSettings({ quality: select.value }));

  [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const usable = tab && isWebLink(tab.url || "");
  $("page-title").textContent = usable ? (tab.title || tab.url) : "Open a web page with a video, image or file.";
  $("send").disabled = !usable;
  $("grab").disabled = !usable;

  const cached = (await chrome.storage.session.get("app")).app;
  if (cached) showState(cached);
  showState(await chrome.runtime.sendMessage({ type: "hello" }));

  $("send").addEventListener("click", async () => {
    $("send").disabled = true;
    const r = await chrome.runtime.sendMessage({ type: "send", items: [{ url: tab.url, title: tab.title }], opts: { quality: select.value }, tab });
    setResult(r.ok ? r.message : r.error, r.ok);
    $("send").disabled = false;
    poll();
  });

  $("grab").addEventListener("click", async () => {
    await chrome.runtime.sendMessage({ type: "grab", tab });
    window.close();
  });

  $("tabs").addEventListener("click", async () => {
    // Reading other tabs' addresses needs one extra permission, asked for only now.
    const granted = await chrome.permissions.request({ permissions: ["tabs"] }).catch(() => false);
    if (!granted) return setResult("Chrome needs your OK to read your open tabs' addresses.", false);
    const tabs = await chrome.tabs.query({ currentWindow: true });
    const links = tabs.filter((t) => isWebLink(t.url || "")).map((t) => ({ url: t.url, title: t.title }));
    if (!links.length) return setResult("No web pages are open in this window.", false);
    const r = await chrome.runtime.sendMessage({ type: "send", items: links, opts: { quality: select.value, mode: "import", name: "Open tabs" } });
    setResult(r.ok ? r.message : r.error, r.ok);
  });

  $("open-app").addEventListener("click", () => chrome.runtime.sendMessage({ type: "open", what: "app" }));
  $("open-folder").addEventListener("click", () => chrome.runtime.sendMessage({ type: "open", what: "folder" }));
  $("settings").addEventListener("click", () => chrome.runtime.openOptionsPage());
  $("how").addEventListener("click", (e) => { e.preventDefault(); chrome.runtime.openOptionsPage(); });

  setInterval(poll, 1500);
}

let polling = false;
async function poll() {
  if (polling) return;
  polling = true;
  try {
    const r = await chrome.runtime.sendMessage({ type: "status" });
    if (r && r.ok) renderQueue(r.status);
  } finally {
    polling = false;
  }
}

init();
