/*
 * Paperreads — reader page (module A). Hosted in a WKWebView loaded with loadFileURL.
 *
 * API (called from Swift):
 *   Reader.load({html, highlights:[{id, blockIndex, startOffset, quote}], position?:{b, frac}, prefs?})
 *                                                                      → {maxBlock}
 *   Reader.setPrefs({fontSize, measure, font, lineHeight})             → true (keeps the reading anchor)
 *   Reader.getPosition()                                               → {b, frac} | null
 *   Reader.addHighlight({id, blockIndex, startOffset, quote})          → Bool (applied)
 *   Reader.removeHighlight(id)
 *   Reader.scrollToBlock(b)                                            → Bool
 *   Reader.flashHighlight(id)                                          → Bool
 *   Reader.getSelection()                                              → JSON string | null
 *
 * Messages to Swift (handler "reader"):
 *   {type:"ready"}
 *   {type:"selection", action:"highlight"|"explain"|"ask", selection:{quote, blockIndex, startOffset, contextText}}
 *   {type:"highlightClicked", id}
 *   {type:"position", b, frac}      top-most visible block + progress through it (0–1), throttled
 *
 * Reading anchor: a position is "held" after Reader.load(position) and Reader.setPrefs — every
 * later layout change (KaTeX batches, late images, window/panel resizes) re-applies it until the
 * user scrolls. Without a hold, layout changes re-apply the last position seen while scrolling,
 * so the line being read stays put when content above it changes height.
 *
 * Offsets are measured in Paperreads.linearize(block).text — the same function that produced
 * blocks.json — so a stored highlight always maps back onto the same characters. Multi-block
 * quotes join the per-block parts with "\n" (block text never contains a newline).
 */
(function (global) {
  'use strict';

  const P = global.Paperreads;
  const QUOTE_MAX = 4000;
  const CONTEXT_MAX = 8000;

  const paper = document.getElementById('paper');
  const toolbar = document.getElementById('toolbar');

  let blocks = [];             // block elements in document order
  let posByB = new Map();      // data-b → index in `blocks`
  let linCache = new WeakMap(); // block → linearisation (invalidated on DOM mutation)
  let cancelMath = null;
  const highlights = new Map(); // id → {id, blockIndex, startOffset, quote}

  // reading position (see header comment)
  const POST_INTERVAL = 250;   // ms between position messages (minimum)
  let hold = null;             // {b, frac} re-applied on layout changes until the user scrolls
  let lastKnown = null;        // last position measured while scrolling
  let lastPosted = null;
  let lastPostAt = 0;
  let postTimer = 0;
  let scrollRaf = 0;
  let expectedY = 0;           // scrollY right after our own restore
  let expectedH = 0;           // scrollHeight right after our own restore
  let suppressRestoreUntil = 0; // after scrollToBlock: let the smooth scroll run
  let progressBar = null;

  // ---------------------------------------------------------------- helpers

  function lin(block) {
    let l = linCache.get(block);
    if (!l) { l = P.linearize(block, true); linCache.set(block, l); }
    return l;
  }
  function invalidate() { linCache = new WeakMap(); }

  function indexBlocks() {
    blocks = Array.from(paper.querySelectorAll(P.BLOCK_SELECTOR));
    posByB = new Map();
    blocks.forEach((el, i) => {
      const b = parseInt(el.getAttribute('data-b'), 10);
      if (!posByB.has(b)) posByB.set(b, i);
    });
  }

  function blockNumber(el) { return parseInt(el.getAttribute('data-b'), 10); }

  function toInt(x) {
    const n = typeof x === 'number' ? x : parseInt(x, 10);
    return Number.isFinite(n) ? Math.trunc(n) : NaN;
  }

  function normHighlight(h) {
    h = P.parseArg(h);
    if (!h || typeof h !== 'object') return null;
    const id = h.id == null ? '' : String(h.id);
    const quote = typeof h.quote === 'string' ? h.quote : '';
    const blockIndex = toInt(h.blockIndex);
    const startOffset = toInt(h.startOffset);
    if (!id || !quote || !Number.isFinite(blockIndex)) return null;
    return { id: id, quote: quote, blockIndex: blockIndex, startOffset: Number.isFinite(startOffset) ? startOffset : 0 };
  }

  /** Wraps tables in a horizontal scroller (reader-only presentation). */
  function wrapTables() {
    paper.querySelectorAll('table').forEach((t) => {
      if (t.parentElement && t.parentElement.classList.contains('tscroll')) return;
      if (t.parentElement && t.parentElement.closest('table')) return;
      const w = document.createElement('div');
      w.className = 'tscroll';
      t.parentNode.insertBefore(w, t);
      w.appendChild(t);
    });
  }

  // ---------------------------------------------------------------- typography prefs

  const MEASURES = { narrow: '58ch', normal: '68ch', wide: '80ch' };
  const FONTS = { serif: 'var(--serif)', sans: 'var(--sans)' };
  const LINE_HEIGHTS = { compact: '1.48', normal: '1.62', relaxed: '1.8' };
  const DEFAULT_PREFS = { fontSize: 19, measure: 'normal', font: 'serif', lineHeight: 'normal' };
  let prefs = Object.assign({}, DEFAULT_PREFS);

  function normPrefs(p) {
    p = P.parseArg(p);
    const out = Object.assign({}, prefs);
    if (!p || typeof p !== 'object') return out;
    const size = toInt(p.fontSize);
    if (Number.isFinite(size)) out.fontSize = Math.min(26, Math.max(14, size));
    if (typeof p.measure === 'string' && Object.prototype.hasOwnProperty.call(MEASURES, p.measure)) out.measure = p.measure;
    if (typeof p.font === 'string' && Object.prototype.hasOwnProperty.call(FONTS, p.font)) out.font = p.font;
    if (typeof p.lineHeight === 'string' && Object.prototype.hasOwnProperty.call(LINE_HEIGHTS, p.lineHeight)) out.lineHeight = p.lineHeight;
    return out;
  }

  /** Applies prefs as CSS custom properties on :root (reader.css reads them). */
  function applyPrefs(p) {
    prefs = p;
    const st = document.documentElement.style;
    st.setProperty('--reader-size', p.fontSize + 'px');
    st.setProperty('--reader-measure', MEASURES[p.measure]);
    st.setProperty('--reader-font', FONTS[p.font]);
    st.setProperty('--reader-leading', LINE_HEIGHTS[p.lineHeight]);
    document.documentElement.setAttribute('data-reader-font', p.font);
  }

  // ---------------------------------------------------------------- reading position

  function firstBlockNumber() { return blocks.length ? blockNumber(blocks[0]) : 0; }

  /** Top-most block visible at the top edge of the viewport, and how far through it we are. */
  function computePosition() {
    if (!blocks.length) return null;
    if (global.scrollY <= 1) return { b: firstBlockNumber(), frac: 0 };
    let lo = 0;
    let hi = blocks.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (blocks[mid].getBoundingClientRect().bottom <= 1) lo = mid + 1; else hi = mid;
    }
    if (lo >= blocks.length) lo = blocks.length - 1;
    const el = blocks[lo];
    const r = el.getBoundingClientRect();
    let frac = r.height > 0 ? -r.top / r.height : 0;
    if (!Number.isFinite(frac)) frac = 0;
    frac = Math.min(1, Math.max(0, frac));
    return { b: blockNumber(el), frac: Math.round(frac * 10000) / 10000 };
  }

  /** Like computePosition, plus the anchor block's document geometry for layout-shift fixes. */
  function measureAnchor() {
    const pos = computePosition();
    if (!pos) return null;
    const el = global.scrollY <= 1 ? null : blockForNumber(pos.b);
    if (el) {
      const r = el.getBoundingClientRect();
      pos.el = el;
      pos.docTop = r.top + global.scrollY;
      pos.height = r.height;
    }
    return pos;
  }

  /**
   * Keeps the last measured anchor in place after a layout change while not holding. Content
   * that changed height above the anchor is compensated with scrollBy(delta), which leaves
   * momentum scrolling alone when nothing above moved; a reflow of the anchor block itself
   * (width change) re-applies the fraction instead.
   */
  function keepAnchor(a) {
    if (!a.el) {
      if (global.scrollY > 1) global.scrollTo(0, 0);
      return;
    }
    if (!a.el.isConnected) { restorePosition(a); return; }
    const r = a.el.getBoundingClientRect();
    if (Math.abs(r.height - a.height) > 1) {
      restorePosition(a);
    } else {
      const delta = r.top + global.scrollY - a.docTop;
      if (Math.abs(delta) >= 1) global.scrollBy(0, delta);
    }
    lastKnown = measureAnchor() || a;
  }

  /** The block for data-b `b`, or the closest earlier block when it no longer exists. */
  function blockForNumber(b) {
    if (posByB.has(b)) return blocks[posByB.get(b)];
    let best = null;
    for (let i = 0; i < blocks.length; i++) {
      const n = blockNumber(blocks[i]);
      if (n <= b) best = blocks[i]; else break;
    }
    return best || blocks[0] || null;
  }

  function normPosition(pos) {
    pos = P.parseArg(pos);
    if (!pos || typeof pos !== 'object') return null;
    const b = toInt(pos.b);
    let frac = typeof pos.frac === 'number' ? pos.frac : parseFloat(pos.frac);
    if (!Number.isFinite(b) || b < 0) return null;
    if (!Number.isFinite(frac)) frac = 0;
    return { b: b, frac: Math.min(1, Math.max(0, frac)) };
  }

  function docHeight() { return document.documentElement.scrollHeight; }

  /** Scrolls so that `frac` of block `b` sits at the top of the viewport. */
  function restorePosition(pos) {
    if (!pos || !blocks.length) return false;
    const el = blockForNumber(pos.b);
    if (!el) return false;
    let y = 0;
    if (!(blockNumber(el) <= firstBlockNumber() && pos.frac <= 0)) {
      const r = el.getBoundingClientRect();
      y = Math.max(0, Math.round(r.top + global.scrollY + pos.frac * r.height));
    }
    global.scrollTo(0, y);
    expectedY = global.scrollY;
    expectedH = docHeight();
    updateProgress();
    return true;
  }

  /** Ends a hold; re-measures so later layout changes anchor on where the reader now is
   * (not on pre-load/pre-prefs geometry). */
  function releaseHold() {
    if (!hold) return;
    hold = null;
    lastKnown = blocks.length ? measureAnchor() : null;
  }

  function updateProgress() {
    if (!progressBar) return;
    const max = docHeight() - global.innerHeight;
    const p = blocks.length && max > 0 ? Math.min(1, Math.max(0, global.scrollY / max)) : 0;
    progressBar.style.transform = 'scaleX(' + p.toFixed(4) + ')';
  }

  function samePosition(a, b) {
    return !!a && !!b && a.b === b.b && Math.abs(a.frac - b.frac) < 0.005;
  }

  function postPosition() {
    postTimer = 0;
    if (hold || !blocks.length) return;
    const pos = computePosition();
    if (!pos) return;
    lastPostAt = performance.now();
    if (samePosition(pos, lastPosted)) return;
    lastPosted = pos;
    P.postToSwift('reader', { type: 'position', b: pos.b, frac: pos.frac });
  }

  function schedulePost() {
    if (postTimer) return;
    const wait = Math.max(0, POST_INTERVAL - (performance.now() - lastPostAt));
    postTimer = setTimeout(postPosition, Math.max(wait, 16));
  }

  function onScrollFrame() {
    scrollRaf = 0;
    updateProgress();
    if (hold || !blocks.length) return;
    lastKnown = measureAnchor();
    schedulePost();
  }

  function onScroll() {
    if (hold) {
      // A scroll we did not cause, with the layout unchanged, is the user (e.g. dragging the
      // scrollbar, which sends no wheel/key events). Layout-caused clamps are left to the observer.
      if (Math.abs(global.scrollY - expectedY) > 2 && docHeight() === expectedH) releaseHold();
    }
    if (!scrollRaf) scrollRaf = requestAnimationFrame(onScrollFrame);
  }

  const NAV_KEYS = new Set(['ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', 'Home', 'End', ' ', 'Spacebar']);

  global.addEventListener('scroll', onScroll, { passive: true });
  global.addEventListener('wheel', releaseHold, { passive: true });
  global.addEventListener('touchstart', releaseHold, { passive: true });
  document.addEventListener('mousedown', releaseHold, { passive: true });
  document.addEventListener('keydown', (ev) => { if (NAV_KEYS.has(ev.key)) releaseHold(); }, { passive: true });

  // Every layout change of the paper (math batches, images, prefs, width changes) re-anchors.
  if (typeof global.ResizeObserver === 'function') {
    new global.ResizeObserver(() => {
      if (!blocks.length) return;
      if (performance.now() < suppressRestoreUntil) return;
      if (hold) restorePosition(hold);
      else if (lastKnown) keepAnchor(lastKnown);
      updateProgress();
    }).observe(paper);
  }

  function ensureProgressBar() {
    if (progressBar) return;
    progressBar = document.createElement('div');
    progressBar.id = 'progress';
    progressBar.setAttribute('data-pr-ui', '');
    progressBar.setAttribute('aria-hidden', 'true');
    document.body.appendChild(progressBar);
  }

  // ---------------------------------------------------------------- highlight painting

  const NO_INLINE_PARENT = new Set(['TR', 'TBODY', 'THEAD', 'TABLE', 'UL', 'OL']);

  /** Wraps linear range [s, e) of `block` in mark.hl[data-id]. */
  function wrapRange(block, l, s, e, id) {
    const segs = [];
    let i = s;
    while (i < e) {
      const n = l.nodes[i];
      const o = l.offs[i];
      if (o >= 0) {
        let j = i;
        while (j + 1 < e && l.nodes[j + 1] === n && l.offs[j + 1] >= 0) j++;
        segs.push({ kind: 't', node: n, a: o, b: l.offs[j] + 1 });
        i = j + 1;
      } else if (o === P.OFF_BEFORE && n.nodeType === 1 && n.classList.contains('m')) {
        let j = i;
        while (j + 1 < e && l.nodes[j + 1] === n) j++;
        segs.push({ kind: 'm', node: n });
        i = j + 1;
      } else {
        i++;
      }
    }
    let wrapped = 0;
    for (let k = segs.length - 1; k >= 0; k--) {
      const sg = segs[k];
      if (sg.kind === 't') {
        let t = sg.node;
        if (!t.parentNode || NO_INLINE_PARENT.has(t.parentNode.nodeName)) continue;
        const end = Math.min(sg.b, t.data.length);
        if (end <= sg.a) continue;
        if (end < t.data.length) t.splitText(end);
        if (sg.a > 0) t = t.splitText(sg.a);
        if (!t.data.trim() && segs.length > 1 && (k === 0 || k === segs.length - 1)) continue;
        const m = makeMark(id);
        t.parentNode.insertBefore(m, t);
        m.appendChild(t);
        wrapped++;
      } else {
        const span = sg.node;
        if (!span.parentNode) continue;
        const m = makeMark(id);
        span.parentNode.insertBefore(m, span);
        m.appendChild(span);
        wrapped++;
      }
    }
    if (wrapped) invalidate();
    return wrapped;
  }

  function makeMark(id) {
    const m = document.createElement('mark');
    m.className = 'hl';
    m.setAttribute('data-id', id);
    return m;
  }

  function nearestIndexOf(hay, needle, around) {
    if (!needle) return -1;
    let best = -1;
    let bestDist = Infinity;
    let i = hay.indexOf(needle);
    while (i >= 0) {
      const d = Math.abs(i - around);
      if (d < bestDist) { best = i; bestDist = d; }
      i = hay.indexOf(needle, i + 1);
    }
    return best;
  }

  /** Locates where each quote part sits: [{pos, start, len}] or null. */
  function locate(h) {
    const parts = h.quote.split('\n');
    let pos = posByB.has(h.blockIndex) ? posByB.get(h.blockIndex) : -1;
    let start = -1;
    const first = parts[0];

    if (pos >= 0) {
      const text = lin(blocks[pos]).text;
      if (text.substr(h.startOffset, first.length) === first) start = h.startOffset;
      else start = nearestIndexOf(text, first, h.startOffset);
    }
    if (start < 0) {
      // fallback: search nearby blocks first, then the whole paper
      const origin = pos >= 0 ? pos : 0;
      const order = [];
      for (let d = 1; d <= 6; d++) { order.push(origin - d, origin + d); }
      for (let k = 0; k < blocks.length; k++) order.push(k);
      const seen = new Set(pos >= 0 ? [pos] : []);
      for (const k of order) {
        if (k < 0 || k >= blocks.length || seen.has(k)) continue;
        seen.add(k);
        const idx = lin(blocks[k]).text.indexOf(first);
        if (idx >= 0 && first) { pos = k; start = idx; break; }
      }
    }
    if (start < 0 || pos < 0) return null;

    const out = [{ pos: pos, start: start, len: first.length }];
    for (let k = 1; k < parts.length; k++) {
      const p = pos + k;
      if (p >= blocks.length) break;
      const part = parts[k];
      if (!part) continue;
      const text = lin(blocks[p]).text;
      let s = text.startsWith(part) ? 0 : text.indexOf(part);
      if (s < 0) continue;
      out.push({ pos: p, start: s, len: part.length });
    }
    return out;
  }

  function paint(h) {
    const where = locate(h);
    if (!where) return false;
    // compute all linearisations before mutating anything
    const jobs = where.map((w) => ({ block: blocks[w.pos], l: lin(blocks[w.pos]), s: w.start, e: w.start + w.len }));
    let any = 0;
    jobs.forEach((j) => { any += wrapRange(j.block, j.l, j.s, j.e, h.id); });
    return any > 0;
  }

  function unpaint(id) {
    const marks = paper.querySelectorAll('mark.hl[data-id="' + cssEscape(id) + '"]');
    if (!marks.length) return false;
    const parents = new Set();
    marks.forEach((m) => {
      const p = m.parentNode;
      if (!p) return;
      while (m.firstChild) p.insertBefore(m.firstChild, m);
      p.removeChild(m);
      parents.add(p);
    });
    parents.forEach((p) => p.normalize());
    invalidate();
    return true;
  }

  function cssEscape(s) {
    if (global.CSS && CSS.escape) return CSS.escape(s);
    return String(s).replace(/["\\]/g, '\\$&');
  }

  // ---------------------------------------------------------------- selection

  function blockOfNode(node) {
    const el = node.nodeType === 1 ? node : node.parentElement;
    if (!el) return null;
    const b = el.closest(P.BLOCK_SELECTOR);
    return b && paper.contains(b) ? b : null;
  }

  /**
   * Index (in `blocks`) of the block containing the DOM point; otherwise the first block
   * after it (forward) or the last block before it (backward). -1 when there is none.
   */
  function blockPosForPoint(node, offset, forward) {
    const inside = blockOfNode(node);
    if (inside) return posByB.get(blockNumber(inside));
    const r = document.createRange();
    try { r.setStart(node, offset); } catch (_) { return -1; }
    r.collapse(true);
    let lo = 0;
    let hi = blocks.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (r.comparePoint(blocks[mid], 0) < 0) lo = mid + 1; else hi = mid;
    }
    if (forward) return lo < blocks.length ? lo : -1;
    return lo - 1;
  }

  function snapOutOfMath(node, offset, isEnd) {
    const el = node.nodeType === 1 ? node : node.parentElement;
    const m = el && el.closest('span.m');
    if (!m || !paper.contains(m)) return [node, offset];
    const p = m.parentNode;
    const idx = Array.prototype.indexOf.call(p.childNodes, m);
    return [p, isEnd ? idx + 1 : idx];
  }

  function currentSelection() {
    const sel = global.getSelection();
    if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return null;
    const range = sel.getRangeAt(0);
    if (!paper.contains(range.commonAncestorContainer) && range.commonAncestorContainer !== paper) {
      // selection must at least intersect the paper
      if (!range.intersectsNode(paper)) return null;
    }
    if (!blocks.length) return null;

    let [sn, so] = snapOutOfMath(range.startContainer, range.startOffset, false);
    let [en, eo] = snapOutOfMath(range.endContainer, range.endOffset, true);
    if (!paper.contains(sn)) { sn = paper; so = 0; }
    if (!paper.contains(en)) { en = paper; eo = paper.childNodes.length; }

    const sp = blockPosForPoint(sn, so, true);
    const ep = blockPosForPoint(en, eo, false);
    if (sp < 0 || ep < 0 || ep < sp) return null;

    const parts = [];
    for (let p = sp; p <= ep; p++) {
      const l = lin(blocks[p]);
      const s = p === sp ? P.offsetOfPoint(l, sn, so) : 0;
      const e = p === ep ? P.offsetOfPoint(l, en, eo) : l.length;
      parts.push({ pos: p, s: s, e: Math.max(s, e), text: l.text });
    }
    // trim whitespace at the ends so the quote starts/ends on content
    const f = parts[0];
    while (f.s < f.e && f.text[f.s] === ' ') f.s++;
    const z = parts[parts.length - 1];
    while (z.e > z.s && z.text[z.e - 1] === ' ') z.e--;
    const nonEmpty = parts.filter((p) => p.e > p.s);
    if (!nonEmpty.length) return null;
    // drop empty leading blocks (selection started at the very end of a block)
    const firstPart = nonEmpty[0];
    const lastPart = nonEmpty[nonEmpty.length - 1];
    const used = parts.slice(parts.indexOf(firstPart), parts.indexOf(lastPart) + 1);

    let quote = used.map((p) => p.text.slice(p.s, p.e)).join('\n');
    if (quote.length > QUOTE_MAX) quote = quote.slice(0, QUOTE_MAX).replace(/\s+$/, '');

    let context = used.map((p) => p.text).join('\n');
    if (context.length > CONTEXT_MAX) {
      const center = firstPart.s + Math.floor(Math.min(quote.length, CONTEXT_MAX) / 2);
      let a = Math.max(0, center - CONTEXT_MAX / 2);
      a = Math.min(a, context.length - CONTEXT_MAX);
      context = context.slice(a, a + CONTEXT_MAX);
    }
    return {
      quote: quote,
      blockIndex: blockNumber(blocks[firstPart.pos]),
      startOffset: firstPart.s,
      contextText: context,
    };
  }

  // ---------------------------------------------------------------- toolbar

  let toolbarTimer = 0;

  function hideToolbar() {
    toolbar.classList.remove('shown');
    toolbar.hidden = true;
  }

  function positionToolbar() {
    const sel = global.getSelection();
    if (!sel || sel.rangeCount === 0 || sel.isCollapsed) { hideToolbar(); return; }
    const range = sel.getRangeAt(0);
    if (!range.intersectsNode(paper) || !String(sel).trim()) { hideToolbar(); return; }
    const rects = Array.from(range.getClientRects()).filter((r) => r.width > 0 || r.height > 0);
    const first = rects.length ? rects[0] : range.getBoundingClientRect();
    if (!first || (first.width === 0 && first.height === 0)) { hideToolbar(); return; }
    toolbar.hidden = false;
    const tw = toolbar.offsetWidth;
    const th = toolbar.offsetHeight;
    const vw = document.documentElement.clientWidth;
    let left = first.left + Math.min(first.width, 240) / 2 - tw / 2;
    left = Math.max(12, Math.min(left, vw - tw - 12));
    let top = first.top - th - 10;
    if (top < 8) {
      const last = rects.length ? rects[rects.length - 1] : first;
      top = last.bottom + 10;
    }
    toolbar.style.left = Math.round(left + global.scrollX) + 'px';
    toolbar.style.top = Math.round(top + global.scrollY) + 'px';
    requestAnimationFrame(() => toolbar.classList.add('shown'));
  }

  function scheduleToolbar() {
    clearTimeout(toolbarTimer);
    toolbarTimer = setTimeout(positionToolbar, 120);
  }

  toolbar.addEventListener('mousedown', (ev) => ev.preventDefault()); // keep the selection
  toolbar.addEventListener('click', (ev) => {
    const btn = ev.target.closest('button[data-action]');
    if (!btn) return;
    ev.preventDefault();
    const action = btn.getAttribute('data-action');
    const selection = currentSelection();
    hideToolbar();
    if (!selection) return;
    P.postToSwift('reader', { type: 'selection', action: action, selection: selection });
    if (action === 'highlight') {
      const s = global.getSelection();
      if (s) s.removeAllRanges();
    }
  });

  document.addEventListener('selectionchange', () => {
    const sel = global.getSelection();
    if (!sel || sel.isCollapsed) { clearTimeout(toolbarTimer); hideToolbar(); return; }
    scheduleToolbar();
  });
  document.addEventListener('mouseup', scheduleToolbar);
  document.addEventListener('keyup', (ev) => { if (ev.shiftKey || ev.key === 'Shift') scheduleToolbar(); });
  document.addEventListener('keydown', (ev) => {
    if (ev.key === 'Escape') {
      hideToolbar();
      const s = global.getSelection();
      if (s) s.removeAllRanges();
    }
  });
  global.addEventListener('resize', () => { if (!toolbar.hidden) positionToolbar(); });

  // ---------------------------------------------------------------- clicks

  paper.addEventListener('click', (ev) => {
    const xref = ev.target.closest('a[data-b]');
    if (xref && paper.contains(xref) && !xref.hasAttribute('href')) {
      ev.preventDefault();
      Reader.scrollToBlock(parseInt(xref.getAttribute('data-b'), 10));
      return;
    }
    const a = ev.target.closest('a[href]');
    if (a) {
      const href = a.getAttribute('href') || '';
      if (!/^https:/i.test(href)) ev.preventDefault();
      return; // https: Swift opens it in the default browser
    }
    const mark = ev.target.closest('mark.hl');
    if (mark && paper.contains(mark)) {
      const sel = global.getSelection();
      if (sel && !sel.isCollapsed) return;
      P.postToSwift('reader', { type: 'highlightClicked', id: mark.getAttribute('data-id') });
    }
  });

  // ---------------------------------------------------------------- flashes

  function flash(el) {
    el.classList.remove('flash');
    void el.offsetWidth; // restart animation
    el.classList.add('flash');
    clearTimeout(el._flashTimer);
    el._flashTimer = setTimeout(() => el.classList.remove('flash'), 2000);
  }

  function scrollIntoViewCentered(el) {
    const prefersReduced = global.matchMedia && global.matchMedia('(prefers-reduced-motion: reduce)').matches;
    el.scrollIntoView({ behavior: prefersReduced ? 'auto' : 'smooth', block: 'center', inline: 'nearest' });
  }

  // ---------------------------------------------------------------- public API

  const Reader = {
    load: function (payload) {
      const data = P.parseArg(payload) || {};
      if (cancelMath) { cancelMath(); cancelMath = null; }
      hideToolbar();
      highlights.clear();
      invalidate();
      ensureProgressBar();
      clearTimeout(postTimer);
      postTimer = 0;
      hold = null;
      lastKnown = null;
      lastPosted = null;
      suppressRestoreUntil = 0;
      applyPrefs(normPrefs(data.prefs));
      blocks = [];
      posByB = new Map();
      paper.textContent = '';
      const html = typeof data.html === 'string' ? data.html : '';
      if (!html.trim()) {
        const p = document.createElement('p');
        p.className = 'empty';
        p.textContent = 'No text to show.';
        paper.appendChild(p);
        indexBlocks();
        global.scrollTo(0, 0);
        updateProgress();
        return { maxBlock: -1 };
      }
      // Content was sanitized at ingest; sanitize again (defence in depth: the file is on disk).
      const src = new DOMParser().parseFromString(html, 'text/html');
      paper.appendChild(P.sanitizeChildren(src.body, document, { allowImages: true, keepBlockIds: true }));
      paper.querySelectorAll('img').forEach((img) => {
        img.loading = 'lazy';
        img.decoding = 'async';
        img.referrerPolicy = 'no-referrer';
      });
      wrapTables();
      indexBlocks();
      global.scrollTo(0, 0);
      (Array.isArray(data.highlights) ? data.highlights : []).forEach((h) => {
        const n = normHighlight(h);
        if (!n) return;
        highlights.set(n.id, n);
        paint(n);
      });
      // Restore before math renders, so the renderer starts with the equations on screen; the
      // hold then re-anchors after every KaTeX batch and late image until the user scrolls.
      const pos = normPosition(data.position);
      if (pos && !(pos.b <= firstBlockNumber() && pos.frac <= 0)) {
        hold = pos;
        restorePosition(pos);
      } else {
        updateProgress();
      }
      cancelMath = P.renderMathProgressive(paper, () => {
        cancelMath = null;
        if (hold) restorePosition(hold);
      });
      let maxBlock = -1;
      blocks.forEach((el) => { const n = blockNumber(el); if (Number.isFinite(n) && n > maxBlock) maxBlock = n; });
      return { maxBlock: maxBlock };
    },

    setPrefs: function (p) {
      const next = normPrefs(p);
      const pos = hold || computePosition();
      applyPrefs(next);
      if (pos && blocks.length) {
        hold = pos;
        restorePosition(pos);
      }
      if (!toolbar.hidden) positionToolbar();
      return true;
    },

    getPosition: function () {
      if (!blocks.length) return null;
      const pos = hold || computePosition();
      return pos ? { b: pos.b, frac: pos.frac } : null;
    },

    addHighlight: function (h) {
      const n = normHighlight(h);
      if (!n) return false;
      if (highlights.has(n.id)) unpaint(n.id);
      highlights.set(n.id, n);
      return paint(n);
    },

    removeHighlight: function (id) {
      const key = String(P.parseArg(id));
      highlights.delete(key);
      return unpaint(key);
    },

    scrollToBlock: function (b) {
      const n = toInt(P.parseArg(b));
      if (!Number.isFinite(n) || !posByB.has(n)) return false;
      const el = blocks[posByB.get(n)];
      releaseHold();
      suppressRestoreUntil = performance.now() + 900;
      scrollIntoViewCentered(el);
      flash(el);
      return true;
    },

    flashHighlight: function (id) {
      const key = String(P.parseArg(id));
      const marks = paper.querySelectorAll('mark.hl[data-id="' + cssEscape(key) + '"]');
      if (!marks.length) return false;
      releaseHold();
      suppressRestoreUntil = performance.now() + 900;
      scrollIntoViewCentered(marks[0]);
      marks.forEach(flash);
      return true;
    },

    getSelection: function () {
      const s = currentSelection();
      return s ? JSON.stringify(s) : null;
    },
  };

  global.Reader = Reader;

  function ready() { P.postToSwift('reader', { type: 'ready' }); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', ready, { once: true });
  else ready();
})(window);
