// Runs inside the page (chrome.scripting.executeScript) when you ask to grab its media.
// It only reads links already on the page and returns them to the extension; nothing is sent anywhere.
export function collectMedia() {
  const EXT = {
    video: ["mp4", "mov", "m4v", "webm", "mkv", "avi", "wmv", "flv", "mpg", "mpeg", "mxf", "m3u8"],
    audio: ["mp3", "wav", "m4a", "aac", "flac", "ogg", "opus", "aif", "aiff"],
    image: ["jpg", "jpeg", "png", "gif", "webp", "avif", "tif", "tiff", "heic", "bmp"],
    file: ["zip", "rar", "7z", "tar", "gz", "pdf", "dmg", "pkg", "exe", "msi", "iso", "psd", "ai", "aep", "prproj",
      "mogrt", "cube", "lut", "otf", "ttf", "woff2", "srt", "vtt", "blend", "fbx", "obj", "c4d", "epub", "docx", "xlsx", "pptx", "csv"],
  };
  const PAGES = [
    /youtube\.com\/(watch\?|shorts\/|playlist\?|live\/)/, /youtu\.be\//, /vimeo\.com\/(\d+|channels\/[^/]+\/\d+)/,
    /tiktok\.com\/@[^/]+\/video\//, /instagram\.com\/(p|reel|reels|tv)\//, /(twitter|x)\.com\/[^/]+\/status\//,
    /facebook\.com\/(.+\/videos\/|reel\/|watch)/, /fb\.watch\//, /clips\.twitch\.tv\//, /twitch\.tv\/videos\//,
    /soundcloud\.com\/[^/]+\/[^/?]+/, /dailymotion\.com\/video\//, /reddit\.com\/r\/[^/]+\/comments\//,
    /bilibili\.com\/video\//, /streamable\.com\/[a-z0-9]+/, /loom\.com\/share\//, /rumble\.com\/v/,
  ];
  const CLOUD = [/drive\.google\.com\/(file|uc|open)/, /docs\.google\.com\/.+\/d\//, /dropbox\.com\/(s|scl|sh)\//, /1drv\.ms\//, /onedrive\.live\.com\//, /sharepoint\.com\//, /wetransfer\.com\/downloads/, /we\.tl\//];

  const out = new Map();
  const abs = (u) => { try { return new URL(u, location.href).href; } catch { return null; } };
  const extOf = (u) => { try { const p = new URL(u).pathname.toLowerCase(); const m = p.match(/\.([a-z0-9]{1,6})$/); return m ? m[1] : ""; } catch { return ""; } };
  const kindOf = (u) => {
    const e = extOf(u);
    for (const k of Object.keys(EXT)) if (EXT[k].includes(e)) return k;
    if (PAGES.some((r) => r.test(u))) return "page";
    if (CLOUD.some((r) => r.test(u))) return "file";
    return null;
  };
  const add = (u, kind, title, extra) => {
    u = abs(u);
    if (!u || !/^https?:/.test(u) || u.length > 4096) return;
    if (kind === "image" && globalThis.CosmoOriginals) u = globalThis.CosmoOriginals.original(u);
    const key = u.replace(/#.*$/, "");
    if (out.has(key)) return;
    out.set(key, { url: key, kind, title: (title || "").trim().replace(/\s+/g, " ").slice(0, 200), ...(extra || {}) });
  };

  for (const a of document.querySelectorAll("a[href]")) {
    const href = abs(a.getAttribute("href"));
    if (!href) continue;
    const kind = kindOf(href);
    if (kind) add(href, kind, a.getAttribute("title") || a.textContent || a.getAttribute("aria-label"));
    if (out.size > 1500) break;
  }
  for (const v of document.querySelectorAll("video, audio")) {
    const kind = v.tagName === "VIDEO" ? "video" : "audio";
    const srcs = [v.currentSrc, v.src, ...[...v.querySelectorAll("source")].map((s) => s.src)];
    for (const s of srcs) if (s && /^https?:/.test(s)) add(s, kind, document.title);
  }
  for (const img of document.images) {
    const w = img.naturalWidth || img.width, h = img.naturalHeight || img.height;
    if (w < 200 || h < 150) continue;
    const s = img.currentSrc || img.src;
    if (s && /^https?:/.test(s)) add(s, "image", img.alt || img.title, { w, h });
  }
  for (const m of document.querySelectorAll('meta[property="og:video"], meta[property="og:video:url"], meta[property="og:video:secure_url"]')) {
    if (m.content) add(m.content, "video", document.title);
  }
  for (const m of document.querySelectorAll('meta[property="og:image"]')) if (m.content) add(m.content, "image", "Page cover image");

  return { page: { url: location.href, title: document.title }, items: [...out.values()].slice(0, 1000) };
}
