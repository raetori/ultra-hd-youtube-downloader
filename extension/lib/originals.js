// Lifehack: turn a site's small preview image link into the full-size original.
// Plain script so it works as a content script and as an import in the background worker.
(() => {
  function original(src) {
    let u;
    try { u = new URL(src); } catch { return src; }
    const h = u.hostname;
    // X / Twitter: ?name=small → ?name=orig
    if (h === "pbs.twimg.com" && u.pathname.startsWith("/media/")) {
      u.searchParams.set("name", "orig");
      return u.toString();
    }
    // Pinterest: /236x/ /474x/ /736x/ → /originals/
    if (h === "i.pinimg.com") {
      u.pathname = u.pathname.replace(/^\/(\d+x|\d+x\d+(_[A-Z]+)?)\//, "/originals/");
      return u.toString();
    }
    // YouTube thumbnails: any size → maxresdefault (the page falls back if a video has none)
    if (/(^|\.)ytimg\.com$/.test(h) && /\/vi(_webp)?\/[^/]+\//.test(u.pathname)) {
      const m = u.pathname.match(/\/vi(?:_webp)?\/([^/]+)\//);
      if (m) return `https://i.ytimg.com/vi/${m[1]}/maxresdefault.jpg`;
    }
    // Reddit previews → the original upload
    if (h === "preview.redd.it") return `https://i.redd.it${u.pathname}`;
    // Wikipedia / Wikimedia thumbnails → original file
    if (h === "upload.wikimedia.org" && u.pathname.includes("/thumb/")) {
      const parts = u.pathname.split("/");
      const i = parts.indexOf("thumb");
      if (i >= 0 && parts.length - i >= 5) {
        parts.splice(i, 1);
        parts.pop();
        u.pathname = parts.join("/");
        return u.toString();
      }
    }
    // Unsplash and imgix-style resizers: drop the size limits
    if (h === "images.unsplash.com") {
      ["w", "h", "q", "fit", "crop", "auto", "ixlib", "fm"].forEach((k) => u.searchParams.delete(k));
      return u.toString();
    }
    // WordPress: photo-300x200.jpg → photo.jpg (only on wp-content uploads)
    if (u.pathname.includes("/wp-content/uploads/")) {
      u.pathname = u.pathname.replace(/-\d{2,5}x\d{2,5}(\.(jpe?g|png|webp|gif))$/i, "$1");
      return u.toString();
    }
    return src;
  }
  globalThis.CosmoOriginals = { original };
})();
