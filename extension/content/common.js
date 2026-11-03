// Shared pieces for the in-page buttons (YouTube and the hover button on other sites).
// Everything stays on the page; clicks go to the extension, which hands the link to the CosmoGrav app.
(() => {
  if (globalThis.CosmoGrav) return;

  const MARK = '<svg viewBox="0 0 100 100" aria-hidden="true" focusable="false"><path fill="currentColor" d="M82.70,79.44A44,44 0 1 1 82.70,20.56L71.55,30.60A29,29 0 1 0 71.55,69.40Z"/><circle fill="currentColor" cx="80" cy="50" r="9.5"/></svg>';
  const QUALITIES = [
    { id: "best", label: "Best HD MP4", hint: "up to 4K" },
    { id: "hd1080", label: "1080p MP4", hint: "faster" },
    { id: "mp3", label: "Audio MP3" },
    { id: "wav", label: "Audio WAV" },
    { id: "captions", label: "Captions SRT" },
    { id: "prores", label: "ProRes 422 HQ", hint: "MOV" },
  ];

  /** False once the extension was updated or removed; old buttons then quietly go away. */
  const alive = () => { try { return !!chrome.runtime?.id; } catch { return false; } };

  let settings = null;
  async function getSettings() {
    if (settings) return settings;
    try { settings = await chrome.runtime.sendMessage({ type: "settings" }); } catch { settings = {}; }
    return settings || {};
  }
  try {
    chrome.storage.onChanged.addListener((c, area) => { if (area === "local" && c.settings) settings = { ...(settings || {}), ...c.settings.newValue }; });
  } catch {}

  async function send(items, opts) {
    if (!alive()) return toast("CosmoGrav was updated. Reload this page to use it again.", false);
    let result;
    try { result = await chrome.runtime.sendMessage({ type: "send", items, opts: opts || {} }); } catch (e) { result = { ok: false, error: "Reload this page to use CosmoGrav again." }; }
    const s = await getSettings();
    if (result && (result.ok ? s.toast !== false : true)) toast(result.ok ? result.message : result.error, !!result.ok);
    return result;
  }

  let toastTimer;
  function toast(text, ok = true) {
    let el = document.getElementById("cosmograv-toast");
    if (!el) {
      el = document.createElement("div");
      el.id = "cosmograv-toast";
      el.setAttribute("role", "status");
      document.documentElement.appendChild(el);
    }
    el.className = ok ? "cosmograv-toast" : "cosmograv-toast cosmograv-toast-bad";
    el.innerHTML = `<span class="cosmograv-toast-mark">${MARK}</span><span></span>`;
    el.lastChild.textContent = text;
    requestAnimationFrame(() => el.classList.add("cosmograv-show"));
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove("cosmograv-show"), 3400);
  }

  // ----- Menus -----
  let openMenu = null;
  function closeMenu() {
    if (openMenu) { openMenu.remove(); openMenu = null; }
    document.removeEventListener("pointerdown", outside, true);
    document.removeEventListener("keydown", escKey, true);
  }
  function outside(e) { if (openMenu && !openMenu.contains(e.target)) closeMenu(); }
  function escKey(e) { if (e.key === "Escape") closeMenu(); }

  /**
   * entries: [{label, hint, action, disabled}] or "-" for a divider, or {heading}.
   * Shown under (or above) the anchor element, kept inside the window.
   */
  function menu(anchor, entries) {
    closeMenu();
    const m = document.createElement("div");
    m.className = "cosmograv-menu";
    m.setAttribute("role", "menu");
    for (const e of entries) {
      if (e === "-") { m.appendChild(Object.assign(document.createElement("div"), { className: "cosmograv-menu-rule" })); continue; }
      if (e.heading) { const h = document.createElement("div"); h.className = "cosmograv-menu-heading"; h.textContent = e.heading; m.appendChild(h); continue; }
      const b = document.createElement("button");
      b.type = "button";
      b.className = "cosmograv-menu-item";
      b.setAttribute("role", "menuitem");
      b.disabled = !!e.disabled;
      const l = document.createElement("span"); l.textContent = e.label; b.appendChild(l);
      if (e.hint) { const h = document.createElement("span"); h.className = "cosmograv-menu-hint"; h.textContent = e.hint; b.appendChild(h); }
      b.addEventListener("click", (ev) => { ev.preventDefault(); ev.stopPropagation(); if (!e.keepOpen) closeMenu(); e.action && e.action(ev); });
      m.appendChild(b);
    }
    document.documentElement.appendChild(m);
    const r = anchor.getBoundingClientRect();
    const mw = m.offsetWidth, mh = m.offsetHeight;
    let left = Math.min(Math.max(8, r.left), innerWidth - mw - 8);
    let top = r.bottom + 6;
    if (top + mh > innerHeight - 8) top = Math.max(8, r.top - mh - 6);
    m.style.left = `${left}px`;
    m.style.top = `${top}px`;
    requestAnimationFrame(() => m.classList.add("cosmograv-show"));
    openMenu = m;
    setTimeout(() => {
      document.addEventListener("pointerdown", outside, true);
      document.addEventListener("keydown", escKey, true);
    });
    m.querySelector("button:not(:disabled)")?.focus({ preventScroll: true });
    return m;
  }

  function qualityEntries(sendWith) {
    return QUALITIES.map((q) => ({ label: q.label, hint: q.hint, action: () => sendWith(q.id) }));
  }

  // ----- Floating hover button -----
  /**
   * One small orb button that follows whatever media the pointer is over.
   * target() returns {rect, primary(), menu()} for the element under the pointer, or null.
   */
  function floatingButton() {
    const wrap = document.createElement("div");
    wrap.className = "cosmograv-float";
    wrap.innerHTML = `<button type="button" class="cosmograv-float-main" title="Download with CosmoGrav" aria-label="Download with CosmoGrav">${MARK}<span>CosmoGrav</span></button><button type="button" class="cosmograv-float-more" title="More choices" aria-label="More choices"><svg viewBox="0 0 10 6" aria-hidden="true"><path d="M1 1l4 4 4-4" fill="none" stroke="currentColor" stroke-width="1.5"/></svg></button>`;
    let current = null, hideTimer = null;
    const main = wrap.firstChild, more = wrap.lastChild;
    const stop = (e) => { e.preventDefault(); e.stopPropagation(); };
    for (const b of [main, more]) {
      b.addEventListener("pointerdown", (e) => e.stopPropagation(), true);
      b.addEventListener("mousedown", (e) => e.stopPropagation(), true);
    }
    main.addEventListener("click", (e) => { stop(e); current && current.primary(); });
    more.addEventListener("click", (e) => { stop(e); current && menu(wrap, current.menu()); });
    wrap.addEventListener("mouseenter", () => clearTimeout(hideTimer));
    wrap.addEventListener("mouseleave", () => schedule());

    function place(t) {
      if (!alive()) { wrap.remove(); return; }
      if (!wrap.isConnected) document.documentElement.appendChild(wrap);
      clearTimeout(hideTimer);
      current = t;
      const r = t.rect();
      wrap.style.left = `${Math.max(4, r.left + 8)}px`;
      wrap.style.top = `${Math.max(4, r.top + 8)}px`;
      wrap.classList.add("cosmograv-show");
    }
    function schedule() {
      clearTimeout(hideTimer);
      hideTimer = setTimeout(() => { if (!openMenu) { wrap.classList.remove("cosmograv-show"); current = null; } }, 450);
    }
    addEventListener("scroll", () => { if (current) { const r = current.rect(); if (r.bottom < 0 || r.top > innerHeight) schedule(); else place(current); } }, { passive: true, capture: true });
    return { place, schedule, get current() { return current; }, el: wrap };
  }

  /** Saves the frame on screen as a full-resolution PNG, right in the browser. */
  function saveFrame(video, name) {
    try {
      const w = video.videoWidth, h = video.videoHeight;
      if (!w || !h) return toast("Play the video for a moment first, then try again.", false);
      const c = document.createElement("canvas");
      c.width = w; c.height = h;
      c.getContext("2d").drawImage(video, 0, 0, w, h);
      c.toBlob((blob) => {
        if (!blob) return toast("This site doesn't allow saving its frames.", false);
        const a = document.createElement("a");
        const t = video.currentTime || 0;
        const stamp = `${Math.floor(t / 60)}m${String(Math.floor(t % 60)).padStart(2, "0")}s`;
        a.href = URL.createObjectURL(blob);
        a.download = `${(name || "Frame").replace(/[\\/:*?"<>|]+/g, " ").trim().slice(0, 120)} ${stamp}.png`;
        document.documentElement.appendChild(a);
        a.click();
        setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 2000);
        toast(`Frame saved · ${w}×${h} PNG`);
      }, "image/png");
    } catch {
      toast("This site doesn't allow saving its frames.", false);
    }
  }

  async function copy(text, done) {
    try { await navigator.clipboard.writeText(text); toast(done || "Copied"); } catch { toast("Couldn't copy here.", false); }
  }

  function title() {
    return (document.querySelector('meta[property="og:title"]')?.content || document.title || "").trim();
  }

  globalThis.CosmoGrav = { MARK, QUALITIES, send, toast, menu, closeMenu, qualityEntries, floatingButton, getSettings, alive, title, saveFrame, copy };
})();
