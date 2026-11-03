import { QUALITIES, getSettings, saveSettings } from "../lib/shared.js";

const $ = (id) => document.getElementById(id);
const KINDS = [
  { id: "all", label: "All" },
  { id: "page", label: "Video pages" },
  { id: "video", label: "Video files" },
  { id: "image", label: "Images" },
  { id: "audio", label: "Audio" },
  { id: "file", label: "Files" },
];
const id = new URLSearchParams(location.search).get("id");
let data = { page: {}, items: [] };
let filter = "all";
const picked = new Set();

function label(it) {
  if (it.title) return it.title;
  try { const u = new URL(it.url); return decodeURIComponent(u.pathname.split("/").filter(Boolean).pop() || u.hostname); } catch { return it.url; }
}

function visible() {
  const q = $("search").value.trim().toLowerCase();
  return data.items.filter((it) => (filter === "all" || it.kind === filter) && (!q || it.url.toLowerCase().includes(q) || (it.title || "").toLowerCase().includes(q)));
}

function render() {
  const items = visible();
  const list = $("list");
  if (!data.items.length) {
    list.innerHTML = '<p class="empty">No videos, images or files were found on this page. Try scrolling down first so the page loads more, then grab again.</p>';
  } else {
    list.replaceChildren(...items.map((it) => {
      const row = document.createElement("label");
      row.className = "item";
      const box = document.createElement("input");
      box.type = "checkbox";
      box.checked = picked.has(it.url);
      box.addEventListener("change", () => { box.checked ? picked.add(it.url) : picked.delete(it.url); count(); });
      const th = document.createElement("div");
      th.className = "thumb";
      if (it.kind === "image") th.style.backgroundImage = `url("${it.url.replace(/"/g, "%22")}")`;
      else th.textContent = it.kind === "page" ? "Video" : it.kind;
      const text = document.createElement("div");
      const n = document.createElement("div"); n.className = "name"; n.textContent = label(it);
      const u = document.createElement("div"); u.className = "url"; u.textContent = it.url;
      text.append(n, u);
      const chip = document.createElement("span");
      chip.className = "chip";
      chip.textContent = it.w ? `${it.w}×${it.h}` : (it.kind === "page" ? "page" : it.kind);
      row.append(box, th, text, chip);
      return row;
    }));
  }
  for (const b of $("filters").children) {
    const n = b.dataset.kind === "all" ? data.items.length : data.items.filter((i) => i.kind === b.dataset.kind).length;
    b.textContent = `${KINDS.find((k) => k.id === b.dataset.kind).label} ${n}`;
    b.setAttribute("aria-pressed", String(b.dataset.kind === filter));
    b.hidden = n === 0 && b.dataset.kind !== "all";
  }
  count();
}

function count() {
  $("count").textContent = `${picked.size} selected`;
  $("send").disabled = $("import").disabled = picked.size === 0;
}

function selection() { return data.items.filter((i) => picked.has(i.url)).map((i) => ({ url: i.url, title: i.title || undefined })); }

async function send(mode) {
  const r = await chrome.runtime.sendMessage({ type: "send", items: selection(), opts: { quality: $("quality").value, mode, name: data.page.title || "Grabbed links" } });
  $("result").textContent = r.ok ? r.message : r.error;
  $("result").style.color = r.ok ? "var(--gold)" : "var(--danger)";
}

async function init() {
  const s = await getSettings();
  for (const q of QUALITIES) $("quality").append(new Option(q.name, q.id, false, q.id === s.quality));
  $("quality").addEventListener("change", () => saveSettings({ quality: $("quality").value }));
  for (const k of KINDS) {
    const b = document.createElement("button");
    b.className = "btn btn-ghost";
    b.dataset.kind = k.id;
    b.addEventListener("click", () => { filter = k.id; render(); });
    $("filters").append(b);
  }
  const stored = id ? (await chrome.storage.session.get(`grab:${id}`))[`grab:${id}`] : null;
  if (stored) data = stored;
  document.title = `Grab media · ${data.page.title || "CosmoGrav"}`;
  $("source").textContent = data.page.title ? `From "${data.page.title}". Pick what you want, then send it to CosmoGrav. Video pages (YouTube, Vimeo, Instagram, X…) become Premiere-ready MP4s, files keep their format.` : "";
  // Videos and video pages are picked to start with; images and files are one click away.
  for (const it of data.items) if (it.kind === "page" || it.kind === "video") picked.add(it.url);
  $("search").addEventListener("input", render);
  $("all").addEventListener("click", () => { visible().forEach((i) => picked.add(i.url)); render(); });
  $("none").addEventListener("click", () => { visible().forEach((i) => picked.delete(i.url)); render(); });
  $("send").addEventListener("click", () => send("queue"));
  $("import").addEventListener("click", () => send("import"));
  render();
}
init();
