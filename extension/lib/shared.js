// Shared by the background worker, the popup and the settings page.
// Nothing here talks to the internet: the only connection is to the CosmoGrav app on this computer.

export const HOST = "com.creationofcosmos.cosmograv";

// Same names the app uses (Quality in app/Sources/CosmoGrav/Models.swift).
export const QUALITIES = [
  { id: "best", label: "Best HD MP4 (up to 4K)", name: "Best HD MP4", short: "Best HD" },
  { id: "hd1080", label: "1080p MP4 (faster)", name: "1080p MP4", short: "1080p" },
  { id: "mp3", label: "Audio only (MP3)", name: "MP3 audio", short: "MP3" },
  { id: "wav", label: "Audio only (WAV)", name: "WAV audio", short: "WAV" },
  { id: "captions", label: "Captions only (SRT)", name: "SRT captions", short: "SRT" },
  { id: "prores", label: "ProRes 422 HQ (heavy editing)", name: "ProRes 422 HQ", short: "ProRes" },
];
export const QUALITY_IDS = QUALITIES.map((q) => q.id);

export const DEFAULTS = {
  quality: "best",
  // Start downloading as soon as the link reaches CosmoGrav.
  autoStart: true,
  // Bring CosmoGrav to the front after sending (off = stay in the browser).
  focusApp: false,
  youtubeButton: true,
  youtubeThumbs: true,
  // The hover button on other sites also needs the "all sites" permission, asked for in Settings.
  hoverEverywhere: true,
  hoverImages: true,
  toast: true,
};

export async function getSettings() {
  try {
    const stored = await chrome.storage.local.get("settings");
    return { ...DEFAULTS, ...(stored.settings || {}) };
  } catch {
    return { ...DEFAULTS };
  }
}

export async function saveSettings(patch) {
  const next = { ...(await getSettings()), ...patch };
  await chrome.storage.local.set({ settings: next });
  return next;
}

/** "1.10.0" is newer than "1.9.2". */
export function isNewer(a, b) {
  const x = String(a || "0").split(".").map((n) => parseInt(n, 10) || 0);
  const y = String(b || "0").split(".").map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const l = x[i] || 0, r = y[i] || 0;
    if (l !== r) return l > r;
  }
  return false;
}

/** Only ordinary web links go to the app. */
export function isWebLink(url) {
  if (typeof url !== "string" || url.length > 4096) return false;
  try {
    const u = new URL(url);
    return (u.protocol === "https:" || u.protocol === "http:") && !!u.hostname;
  } catch {
    return false;
  }
}
