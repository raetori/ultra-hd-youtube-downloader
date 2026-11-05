// Hover button on videos and large images on any site (turned on in CosmoGrav's extension settings).
(() => {
  const CG = globalThis.CosmoGrav;
  if (!CG || globalThis.__cosmogravHover) return;
  globalThis.__cosmogravHover = true;

  const MIN_VIDEO = { w: 200, h: 120 };
  const MIN_IMAGE = { w: 240, h: 200 };
  const FILE_VIDEO = /\.(mp4|mov|m4v|webm)(\?|$)/i;
  const button = CG.floatingButton();

  const big = (el, min) => {
    const r = el.getBoundingClientRect();
    return r.width >= min.w && r.height >= min.h && r.bottom > 0 && r.top < innerHeight;
  };

  const PINTEREST = /(^|\.)pinterest\.[a-z.]+$/i.test(location.hostname);

  /**
   * Pinterest plays every pin in the feed, search and boards from a stream, and the page address is the feed,
   * not the pin. The pin's own link (/pin/<number>/) is in the card around the video or picture.
   */
  function pinLink(el) {
    if (!PINTEREST) return null;
    const PIN = /\/pin\/(?:[\w-]+--)?(\d{5,30})/;
    const idIn = (href) => { try { return new URL(href, location.href).pathname.match(PIN)?.[1]; } catch { return null; } };
    const card = el.closest("[data-grid-item], [data-test-id='pin'], [data-test-id='pinWrapper'], [data-test-id='pin-visual-wrapper']");
    const link = el.closest("a[href*='/pin/']") || card?.querySelector("a[href*='/pin/']");
    const id = (link && idIn(link.href)) || (!card && idIn(location.href));
    // A pin opened on its own page: the big video there is that pin.
    return id ? `https://www.pinterest.com/pin/${id}/` : null;
  }

  /** Posts on social sites play from a stream, so their own page link works best. */
  function videoLink(v) {
    const src = v.currentSrc || v.src || "";
    if (/^https?:/.test(src) && FILE_VIDEO.test(src)) return src;
    const pin = pinLink(v);
    if (pin) return pin;
    const post = v.closest("article, [role='article'], [data-testid='tweet']");
    const scope = post || v.parentElement?.parentElement?.parentElement || document;
    const permalink = [...scope.querySelectorAll("a[href]")].map((a) => a.href).find((h) =>
      /\/status\/\d+|\/reel\/|\/p\/[\w-]+|\/video\/\d+|\/videos\/\d+|vimeo\.com\/\d+|\/clip\//.test(h));
    return post && permalink ? permalink : location.href;
  }

  function targetFor(el) {
    if (el.tagName === "VIDEO" && big(el, MIN_VIDEO)) {
      return {
        el,
        rect: () => el.getBoundingClientRect(),
        primary: () => CG.send([{ url: videoLink(el), title: CG.title() }]),
        menu: () => [
          { heading: "Download with CosmoGrav" },
          ...CG.qualityEntries((q) => CG.send([{ url: videoLink(el), title: CG.title() }], { quality: q })),
          "-",
          { label: "From here to the end", hint: fmt(el.currentTime), action: () => CG.send([{ url: videoLink(el), title: CG.title() }], { from: el.currentTime }) },
          { label: "Save this frame", hint: "PNG", action: () => CG.saveFrame(el, CG.title()) },
          { label: "Send this page instead", action: () => CG.send([{ url: location.href, title: document.title }]) },
        ],
      };
    }
    if (el.tagName === "IMG" && CG._images !== false && big(el, MIN_IMAGE)) {
      const src = () => globalThis.CosmoOriginals.original(el.currentSrc || el.src);
      return {
        el,
        rect: () => el.getBoundingClientRect(),
        primary: () => CG.send([{ url: src(), title: el.alt || CG.title() }]),
        menu: () => [
          { heading: "Image" },
          { label: "Download the original", hint: "full size", action: () => CG.send([{ url: src(), title: el.alt || CG.title() }]) },
          ...(pinLink(el) ? [{ label: "Send the whole pin", hint: "video too", action: () => CG.send([{ url: pinLink(el), title: el.alt || CG.title() }]) }] : []),
          { label: "Open the original", action: () => window.open(src(), "_blank", "noopener") },
          { label: "Copy image link", action: () => CG.copy(src(), "Image link copied") },
        ],
      };
    }
    return null;
  }

  const fmt = (t) => { t = Math.max(0, Math.floor(t || 0)); const h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = t % 60; return (h ? `${h}:${String(m).padStart(2, "0")}` : `${m}`) + `:${String(s).padStart(2, "0")}`; };

  let last = 0, enabled = true;
  CG.getSettings().then((s) => { enabled = s.hoverEverywhere !== false; CG._images = s.hoverImages !== false; });
  try { chrome.storage.onChanged.addListener((c, a) => { if (a === "local" && c.settings) { enabled = c.settings.newValue.hoverEverywhere !== false; CG._images = c.settings.newValue.hoverImages !== false; } }); } catch {}

  addEventListener("pointermove", (e) => {
    if (!enabled || e.pointerType === "touch") return;
    const now = performance.now();
    if (now - last < 110) return;
    last = now;
    if (button.el.contains(e.target)) return;
    // Players often lay controls over the video, so look underneath the pointer.
    const stack = document.elementsFromPoint(e.clientX, e.clientY).slice(0, 12);
    let t = null;
    for (const el of stack) {
      if (el.tagName === "VIDEO" || el.tagName === "IMG") { t = targetFor(el); if (t) break; }
    }
    if (t) {
      if (!button.current || button.current.el !== t.el) button.place(t); else button.place(button.current);
    } else if (button.current) {
      button.schedule();
    }
  }, { passive: true, capture: true });
})();
