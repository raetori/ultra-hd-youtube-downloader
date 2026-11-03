// YouTube: a CosmoGrav button under every video, a hover button on thumbnails,
// clip in/out marks, frame grabs, best thumbnail and whole playlists.
(() => {
  const CG = globalThis.CosmoGrav;
  if (!CG || globalThis.__cosmogravYouTube) return;
  globalThis.__cosmogravYouTube = true;

  let settings = { youtubeButton: true, youtubeThumbs: true };
  CG.getSettings().then((s) => { settings = { ...settings, ...s }; tick(); });
  try { chrome.storage.onChanged.addListener((c, a) => { if (a === "local" && c.settings) { settings = { ...settings, ...c.settings.newValue }; tick(); } }); } catch {}

  const fmt = (t) => { t = Math.max(0, Math.floor(t || 0)); const h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = t % 60; return (h ? `${h}:${String(m).padStart(2, "0")}` : `${m}`) + `:${String(s).padStart(2, "0")}`; };

  function videoId(url = location.href) {
    try {
      const u = new URL(url, location.href);
      if (u.pathname === "/watch") return u.searchParams.get("v");
      const m = u.pathname.match(/^\/(shorts|live|embed)\/([\w-]{6,})/);
      if (m) return m[2];
      if (u.hostname === "youtu.be") return u.pathname.slice(1);
    } catch {}
    return null;
  }
  const listId = () => new URL(location.href).searchParams.get("list");
  const player = () => document.querySelector("#movie_player video.html5-main-video, #movie_player video, ytd-reel-video-renderer[is-active] video, #shorts-player video, video");
  const watchUrl = (id) => `https://www.youtube.com/watch?v=${id}`;
  const pageTitle = () => (document.querySelector("ytd-watch-metadata h1, h1.ytd-watch-metadata, #title h1")?.textContent || document.title.replace(/ - YouTube$/, "")).trim();

  // ---------- Clip marks (per video) ----------
  const clip = { id: null, from: null, to: null };
  function clipFor(id) { if (clip.id !== id) { clip.id = id; clip.from = null; clip.to = null; } return clip; }

  async function bestThumbnail(id) {
    const max = `https://i.ytimg.com/vi/${id}/maxresdefault.jpg`;
    // Videos without a max-size thumbnail return a small grey placeholder, so check before sending.
    const ok = await new Promise((res) => { const i = new Image(); i.onload = () => res(i.naturalWidth > 120); i.onerror = () => res(false); i.src = max; });
    return ok ? max : `https://i.ytimg.com/vi/${id}/hqdefault.jpg`;
  }

  function watchMenu(anchor) {
    const id = videoId();
    if (!id) return;
    const v = player();
    const c = clipFor(id);
    const now = v ? v.currentTime : 0;
    const url = watchUrl(id), title = pageTitle();
    const entries = [
      { heading: "Download with CosmoGrav" },
      ...CG.qualityEntries((q) => CG.send([{ url, title }], { quality: q })),
      "-",
      { heading: c.from != null || c.to != null ? `Clip · ${fmt(c.from || 0)} – ${c.to != null ? fmt(c.to) : "end"}` : "Clip" },
      { label: "Mark clip start here", hint: fmt(now), action: () => { c.from = now; if (c.to != null && c.to <= c.from) c.to = null; CG.toast(`Clip starts at ${fmt(now)}. Now mark the end, or send it.`); refreshChip(); } },
      { label: "Mark clip end here", hint: fmt(now), action: () => { c.to = now; if (c.from != null && c.from >= c.to) c.from = null; CG.toast(`Clip ends at ${fmt(now)}.`); refreshChip(); } },
      { label: "Download the clip", hint: c.from != null || c.to != null ? `${fmt(c.from || 0)} – ${c.to != null ? fmt(c.to) : "end"}` : "mark it first", disabled: c.from == null && c.to == null,
        action: () => { CG.send([{ url, title }], { from: c.from ?? 0, to: c.to ?? undefined }); } },
      { label: "Last 30 seconds up to here", hint: `${fmt(Math.max(0, now - 30))} – ${fmt(now)}`, action: () => CG.send([{ url, title }], { from: Math.max(0, now - 30), to: now }) },
      { label: "Clear the clip marks", disabled: c.from == null && c.to == null, action: () => { c.from = c.to = null; refreshChip(); } },
      "-",
      { label: "Save this frame", hint: v && v.videoHeight ? `${v.videoWidth}×${v.videoHeight} PNG` : "PNG", action: () => v && CG.saveFrame(v, title) },
      { label: "Download the thumbnail", hint: "largest size", action: async () => CG.send([{ url: await bestThumbnail(id), title: `${title} thumbnail` }]) },
      { label: "Copy link at this moment", hint: fmt(now), action: () => CG.copy(`https://youtu.be/${id}?t=${Math.floor(now)}`, `Link at ${fmt(now)} copied`) },
    ];
    const list = listId();
    if (list && !/^(RD|LL|WL)/.test(list)) {
      entries.push("-", { label: "Download the whole playlist", hint: "one row per video", action: () => CG.send([{ url: `https://www.youtube.com/playlist?list=${list}`, title: "Playlist" }]) });
    }
    CG.menu(anchor, entries);
  }

  // ---------- Button under the video ----------
  function makeWatchButton() {
    const wrap = document.createElement("div");
    wrap.className = "cosmograv-yt";
    wrap.innerHTML = `<button type="button" class="cosmograv-yt-main" title="Download with CosmoGrav (Premiere-ready MP4)">${CG.MARK}<span>CosmoGrav</span><span class="cosmograv-yt-chip" hidden></span></button><button type="button" class="cosmograv-yt-more" title="Quality, clip, frame, thumbnail" aria-label="More CosmoGrav choices"><svg viewBox="0 0 10 6" aria-hidden="true"><path d="M1 1l4 4 4-4" fill="none" stroke="currentColor" stroke-width="1.5"/></svg></button>`;
    wrap.firstChild.addEventListener("click", (e) => {
      e.preventDefault(); e.stopPropagation();
      const id = videoId();
      if (!id) return;
      const c = clipFor(id);
      // With clip marks set, the main button downloads just the clip.
      if (c.from != null || c.to != null) CG.send([{ url: watchUrl(id), title: pageTitle() }], { from: c.from ?? 0, to: c.to ?? undefined });
      else CG.send([{ url: watchUrl(id), title: pageTitle() }]);
    });
    wrap.lastChild.addEventListener("click", (e) => { e.preventDefault(); e.stopPropagation(); watchMenu(wrap); });
    return wrap;
  }

  function refreshChip() {
    const chip = document.querySelector(".cosmograv-yt .cosmograv-yt-chip");
    if (!chip) return;
    const c = clipFor(videoId());
    const on = c.from != null || c.to != null;
    chip.hidden = !on;
    chip.textContent = on ? `${fmt(c.from || 0)}–${c.to != null ? fmt(c.to) : "end"}` : "";
  }

  function placeWatchButton() {
    const existing = document.querySelector(".cosmograv-yt");
    if (!settings.youtubeButton || location.pathname !== "/watch") { existing?.remove(); return; }
    const bar = document.querySelector("ytd-watch-metadata #top-level-buttons-computed")
      || document.querySelector("ytd-watch-metadata #actions-inner #menu")
      || document.querySelector("ytd-watch-metadata #actions");
    if (!bar) return;
    if (existing && bar.contains(existing)) { refreshChip(); return; }
    existing?.remove();
    bar.prepend(makeWatchButton());
    refreshChip();
  }

  // ---------- Playlist pages ----------
  function placePlaylistButton() {
    const existing = document.querySelector(".cosmograv-yt-playlist");
    const list = listId();
    if (!settings.youtubeButton || location.pathname !== "/playlist" || !list) { existing?.remove(); return; }
    if (existing) { existing.dataset.list = list; return; }
    const b = document.createElement("button");
    b.type = "button";
    b.className = "cosmograv-yt-playlist";
    b.dataset.list = list;
    b.innerHTML = `${CG.MARK}<span>Download this playlist</span>`;
    b.addEventListener("click", (e) => {
      e.preventDefault();
      CG.menu(b, [{ heading: "Whole playlist with CosmoGrav" }, ...CG.qualityEntries((q) => CG.send([{ url: `https://www.youtube.com/playlist?list=${b.dataset.list}`, title: document.title }], { quality: q }))]);
    });
    document.documentElement.appendChild(b);
  }

  // ---------- Hover button on thumbnails (and the Shorts player) ----------
  const float = CG.floatingButton();
  const THUMB = 'a#thumbnail, a.yt-lockup-view-model-wiz__content-image, a.yt-lockup-view-model__content-image, a.reel-item-endpoint, a.shortsLockupViewModelHostEndpoint, ytm-shorts-lockup-view-model a, a.ytd-playlist-video-renderer, a[href*="/watch?v="], a[href^="/shorts/"]';

  function thumbTarget(a) {
    const id = videoId(a.href);
    if (!id) return null;
    const r = a.getBoundingClientRect();
    if (r.width < 120 || r.height < 60 || !a.querySelector("img, yt-image, yt-thumbnail-view-model")) return null;
    const url = a.href.includes("/shorts/") ? `https://www.youtube.com/shorts/${id}` : watchUrl(id);
    const card = a.closest("ytd-rich-item-renderer, ytd-video-renderer, ytd-compact-video-renderer, ytd-grid-video-renderer, yt-lockup-view-model, ytd-playlist-video-renderer, ytm-shorts-lockup-view-model, ytd-reel-item-renderer");
    const title = () => (card?.querySelector("#video-title, h3, .yt-lockup-metadata-view-model-wiz__title, .yt-lockup-metadata-view-model__title, .shortsLockupViewModelHostMetadataTitle")?.textContent || a.getAttribute("title") || "").trim() || undefined;
    return {
      el: a,
      rect: () => a.getBoundingClientRect(),
      primary: () => CG.send([{ url, title: title() }]),
      menu: () => [
        { heading: "Download with CosmoGrav" },
        ...CG.qualityEntries((q) => CG.send([{ url, title: title() }], { quality: q })),
        "-",
        { label: "Download the thumbnail", hint: "largest size", action: async () => CG.send([{ url: await bestThumbnail(id), title: `${title() || id} thumbnail` }]) },
        { label: "Copy link", action: () => CG.copy(url, "Link copied") },
      ],
    };
  }

  function shortsTarget(v) {
    const id = videoId();
    if (!id || !location.pathname.startsWith("/shorts/")) return null;
    const url = `https://www.youtube.com/shorts/${id}`;
    return {
      el: v,
      rect: () => v.getBoundingClientRect(),
      primary: () => CG.send([{ url, title: document.title.replace(/ - YouTube$/, "") }]),
      menu: () => [
        { heading: "This Short" },
        ...CG.qualityEntries((q) => CG.send([{ url, title: document.title.replace(/ - YouTube$/, "") }], { quality: q })),
        "-",
        { label: "Save this frame", hint: "PNG", action: () => CG.saveFrame(v, document.title) },
      ],
    };
  }

  let last = 0;
  addEventListener("pointermove", (e) => {
    if (!settings.youtubeThumbs || e.pointerType === "touch") return;
    const now = performance.now();
    if (now - last < 110) return;
    last = now;
    if (float.el.contains(e.target)) return;
    let t = null;
    const a = e.target.closest && e.target.closest(THUMB);
    if (a && !a.closest("#movie_player")) t = thumbTarget(a);
    if (!t && location.pathname.startsWith("/shorts/")) {
      const v = document.elementsFromPoint(e.clientX, e.clientY).find((el) => el.tagName === "VIDEO");
      if (v) t = shortsTarget(v);
    }
    if (t) { if (!float.current || float.current.el !== t.el) float.place(t); else float.place(float.current); }
    else if (float.current) float.schedule();
  }, { passive: true, capture: true });

  // ---------- Keep up with YouTube's page changes ----------
  let pending = false;
  function tick() {
    if (pending) return;
    pending = true;
    // YouTube changes its page all the time; checking a few times a second is plenty.
    setTimeout(() => {
      pending = false;
      if (!CG.alive()) { document.querySelectorAll(".cosmograv-yt, .cosmograv-yt-playlist, .cosmograv-float").forEach((n) => n.remove()); obs.disconnect(); return; }
      placeWatchButton();
      placePlaylistButton();
    }, 300);
  }
  const obs = new MutationObserver(tick);
  obs.observe(document.documentElement, { childList: true, subtree: true });
  addEventListener("yt-navigate-finish", tick);
  tick();
})();
