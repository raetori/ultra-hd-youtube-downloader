import { QUALITIES, getSettings, saveSettings } from "../lib/shared.js";

const $ = (id) => document.getElementById(id);
const VERSION = chrome.runtime.getManifest().version;
const SWITCHES = ["autoStart", "focusApp", "toast", "youtubeButton", "youtubeThumbs", "hoverEverywhere", "hoverImages"];
const ALL_SITES = { origins: ["<all_urls>"] };

if (new URLSearchParams(location.search).has("welcome")) {
  $("eyebrow").textContent = "Welcome";
  $("heading").textContent = "CosmoGrav is in your browser";
}
$("ext-version").textContent = `Extension · version ${VERSION}`;
if (!/Mac/.test(navigator.platform)) { $("k1").textContent = "Alt+Shift+G"; $("k2").textContent = "Alt+Shift+C"; }
$("shortcuts").addEventListener("click", (e) => { e.preventDefault(); chrome.tabs.create({ url: "chrome://extensions/shortcuts" }); });

async function check() {
  const chip = $("status");
  chip.lastElementChild.textContent = "Checking";
  const s = await chrome.runtime.sendMessage({ type: "hello" });
  if (s.connected) {
    chip.className = "chip chip-gold";
    chip.lastElementChild.textContent = "Connected";
    $("conn-text").textContent = s.running ? "CosmoGrav is open and ready. Links you send start in its queue." : "CosmoGrav is installed. It opens by itself when you send a link.";
    $("conn-steps").hidden = true;
    $("versions").textContent = `App ${s.app} · extension ${VERSION}`;
  } else {
    chip.className = "chip chip-danger";
    chip.lastElementChild.textContent = "Not connected";
    $("conn-text").textContent = "This browser can't reach the CosmoGrav app yet.";
    $("conn-steps").hidden = false;
    $("versions").textContent = `Extension ${VERSION}`;
  }
}
$("recheck").addEventListener("click", check);

async function init() {
  const s = await getSettings();
  const select = $("quality");
  for (const q of QUALITIES) select.append(new Option(q.label, q.id, false, q.id === s.quality));
  select.addEventListener("change", () => saveSettings({ quality: select.value }));

  const hasAll = await chrome.permissions.contains(ALL_SITES);
  for (const key of SWITCHES) {
    const box = $(key);
    box.checked = key === "hoverEverywhere" ? s.hoverEverywhere && hasAll : !!s[key];
    box.addEventListener("change", async () => {
      if (key === "hoverEverywhere" && box.checked && !(await chrome.permissions.contains(ALL_SITES))) {
        // Asked only when you turn this on. Turning it off gives the permission back.
        const ok = await chrome.permissions.request(ALL_SITES).catch(() => false);
        if (!ok) { box.checked = false; return; }
      }
      if (key === "hoverEverywhere" && !box.checked) await chrome.permissions.remove(ALL_SITES).catch(() => {});
      await saveSettings({ [key]: box.checked });
    });
  }
  check();
}
init();
