/*
 * Paperreads — chat transcript (module A). Hosted in a WKWebView loading chat.html.
 *
 * API (called from Swift):
 *   Chat.setMessages([{id, role, kind, markdown}])
 *   Chat.setStreaming(markdownOrNull, thinking)   // re-render throttled to ≤ 20 fps
 *   Chat.setReferences({"r3": "Title (2017)", …})
 *   Chat.setPaperTitle(str)
 *
 * Messages to Swift (handler "chat"):
 *   {type:"ready"}, {type:"jumpToBlock", b}, {type:"openReference", label}
 *
 * Markdown from the model is untrusted: protect math → marked → sanitize (shared allowlist,
 * images disabled) → restore math → citation chips → KaTeX.
 */
(function (global) {
  'use strict';

  const P = global.Paperreads;
  const FRAME_MS = 50; // 20 fps

  const transcript = document.getElementById('transcript');
  const listEl = document.getElementById('messages');
  const emptyEl = document.getElementById('empty');
  const streamEl = document.getElementById('stream');
  const streamBody = document.getElementById('stream-body');
  const thinkingEl = document.getElementById('thinking');

  let references = {};
  let paperTitle = '';
  let messageCount = 0;
  const nodeCache = new Map(); // id → {key, node}

  // ---------------------------------------------------------------- rendering

  const CITE_RE = /\[\s*([br]\s*\d{1,6}(?:\s*[-–]\s*[br]?\s*\d{1,6})?(?:\s*[,;]\s*[br]?\s*\d{1,6}(?:\s*[-–]\s*[br]?\s*\d{1,6})?)*)\s*\]/g;

  /** "b3, b4", "b3-b5", "r2; r7" → [{kind:"b", n:3}, …] (ranges capped at 12 items). */
  function parseCiteList(s) {
    const out = [];
    let kind = null;
    s.split(/[,;]/).forEach((piece) => {
      const m = /^\s*([br])?\s*(\d+)\s*(?:[-–]\s*([br])?\s*(\d+))?\s*$/.exec(piece);
      if (!m) return;
      kind = m[1] || kind;
      if (!kind) return;
      const a = parseInt(m[2], 10);
      const b = m[4] ? parseInt(m[4], 10) : a;
      if (b < a || b - a > 11) { out.push({ kind: kind, n: a }); if (b !== a) out.push({ kind: kind, n: b }); return; }
      for (let n = a; n <= b; n++) out.push({ kind: kind, n: n });
    });
    return out;
  }

  function refTitle(label) {
    const t = references[label];
    return typeof t === 'string' ? t : '';
  }

  function makeChip(item) {
    const a = document.createElement('a');
    a.className = 'cite';
    a.setAttribute('role', 'link');
    a.tabIndex = 0;
    if (item.kind === 'b') {
      a.setAttribute('data-b', String(item.n));
      a.textContent = '¶' + item.n;
      a.title = 'Jump to paragraph ' + item.n;
    } else {
      const label = 'r' + item.n;
      a.setAttribute('data-ref', label);
      a.textContent = shortRef(label, item.n);
      const t = refTitle(label);
      a.title = t || 'Reference ' + item.n;
    }
    return a;
  }

  /** Chip text for a reference; the full title is on hover (title attribute). */
  function shortRef(label, n) { return '[' + n + ']'; }

  function linkCitations(root) {
    const texts = [];
    const tw = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    for (let t = tw.nextNode(); t; t = tw.nextNode()) {
      if (t.data.indexOf('[') < 0) continue;
      const parent = t.parentElement;
      if (parent && parent.closest('code, pre, a, span.m')) continue;
      texts.push(t);
    }
    texts.forEach((t) => {
      const s = t.data;
      CITE_RE.lastIndex = 0;
      let m;
      let last = 0;
      let frag = null;
      while ((m = CITE_RE.exec(s))) {
        const items = parseCiteList(m[1]);
        if (!items.length) continue;
        if (!frag) frag = document.createDocumentFragment();
        if (m.index > last) frag.appendChild(document.createTextNode(s.slice(last, m.index)));
        items.forEach((it) => frag.appendChild(makeChip(it)));
        last = m.index + m[0].length;
      }
      if (!frag) return;
      if (last < s.length) frag.appendChild(document.createTextNode(s.slice(last)));
      t.parentNode.replaceChild(frag, t);
    });
  }

  function wrapTables(root) {
    root.querySelectorAll('table').forEach((t) => {
      if (t.parentElement && t.parentElement.classList.contains('tscroll')) return;
      const w = document.createElement('div');
      w.className = 'tscroll';
      t.parentNode.insertBefore(w, t);
      w.appendChild(t);
    });
  }

  /**
   * Model-written links are untrusted (the paper text can prompt-inject them): show the full
   * URL on hover and the destination host inline, so a click never goes somewhere unseen.
   */
  function exposeLinks(root) {
    root.querySelectorAll('a[href]').forEach((a) => {
      const href = a.getAttribute('href') || '';
      if (!/^https:/i.test(href)) return;
      let host = '';
      try { host = new URL(href).host; } catch (_) { return; }
      a.title = href;
      if (host && a.textContent.indexOf(host) < 0) {
        const s = document.createElement('span');
        s.className = 'link-host';
        s.textContent = ' (' + host + ')';
        a.parentNode.insertBefore(s, a.nextSibling);
      }
    });
  }

  function renderMarkdownInto(el, md) {
    const frag = P.markdownToFragment(String(md || ''), document, { allowImages: false });
    el.textContent = '';
    el.appendChild(frag);
    exposeLinks(el);
    linkCitations(el);
    wrapTables(el);
    P.renderMath(el);
  }

  function makeTurn(msg) {
    const role = msg.role === 'user' ? 'user' : 'assistant';
    const section = document.createElement('section');
    section.className = 'turn ' + role;
    if (role === 'user' && msg.kind === 'explain') {
      const label = document.createElement('div');
      label.className = 'caps label';
      label.textContent = 'Explain';
      section.appendChild(label);
    }
    const body = document.createElement('div');
    body.className = 'prose body';
    renderMarkdownInto(body, msg.markdown);
    section.appendChild(body);
    return section;
  }

  // ---------------------------------------------------------------- scrolling

  function nearBottom() {
    const el = document.scrollingElement || document.documentElement;
    return el.scrollHeight - el.scrollTop - el.clientHeight < 96;
  }
  function scrollToBottom() {
    const el = document.scrollingElement || document.documentElement;
    el.scrollTop = el.scrollHeight;
  }

  // ---------------------------------------------------------------- empty state

  function updateEmpty() {
    const empty = messageCount === 0 && streamEl.hidden;
    emptyEl.hidden = !empty;
    if (!empty) return;
    emptyEl.textContent = '';
    if (paperTitle) {
      emptyEl.appendChild(document.createTextNode('Ask anything about '));
      const em = document.createElement('em');
      em.textContent = paperTitle;
      emptyEl.appendChild(em);
      emptyEl.appendChild(document.createTextNode('.'));
    } else {
      emptyEl.textContent = 'Ask anything about this paper.';
    }
  }

  // ---------------------------------------------------------------- streaming (throttled)

  let pending = null;      // {markdown, thinking}
  let lastRender = 0;
  let timer = 0;

  function flushStream() {
    timer = 0;
    if (!pending) return;
    const { markdown, thinking } = pending;
    pending = null;
    lastRender = performance.now();
    const stick = nearBottom();
    const active = markdown !== null || thinking;
    streamEl.hidden = !active;
    if (!active) {
      streamBody.textContent = '';
      thinkingEl.hidden = true;
      streamEl.classList.remove('streaming');
      updateEmpty();
      return;
    }
    const hasText = typeof markdown === 'string' && markdown.length > 0;
    thinkingEl.hidden = !(thinking && !hasText);
    if (hasText) renderMarkdownInto(streamBody, markdown);
    else streamBody.textContent = '';
    streamEl.classList.toggle('streaming', hasText);
    updateEmpty();
    if (stick) scrollToBottom();
  }

  function scheduleStream() {
    if (timer) return;
    const wait = Math.max(0, FRAME_MS - (performance.now() - lastRender));
    timer = setTimeout(() => requestAnimationFrame(flushStream), wait);
  }

  // ---------------------------------------------------------------- clicks

  function activateChip(chip) {
    const b = chip.getAttribute('data-b');
    if (b !== null) {
      const n = parseInt(b, 10);
      if (Number.isFinite(n)) P.postToSwift('chat', { type: 'jumpToBlock', b: n });
      return;
    }
    const label = chip.getAttribute('data-ref');
    if (label && /^r\d{1,6}$/.test(label)) P.postToSwift('chat', { type: 'openReference', label: label });
  }

  transcript.addEventListener('click', (ev) => {
    const chip = ev.target.closest('a.cite');
    if (chip) { ev.preventDefault(); activateChip(chip); return; }
    const a = ev.target.closest('a');
    if (a) {
      const href = a.getAttribute('href') || '';
      if (!/^https:/i.test(href)) ev.preventDefault(); // https → Swift opens default browser
    }
  });
  transcript.addEventListener('keydown', (ev) => {
    if (ev.key !== 'Enter' && ev.key !== ' ') return;
    const chip = ev.target.closest && ev.target.closest('a.cite');
    if (chip) { ev.preventDefault(); activateChip(chip); }
  });

  // ---------------------------------------------------------------- public API

  const Chat = {
    setMessages: function (list) {
      const arr = P.parseArg(list);
      const items = Array.isArray(arr) ? arr : [];
      const stick = nearBottom();
      const seen = new Set();
      const nodes = [];
      items.forEach((raw, i) => {
        if (!raw || typeof raw !== 'object') return;
        const id = raw.id == null ? 'idx-' + i : String(raw.id);
        const msg = {
          id: id,
          role: raw.role === 'user' ? 'user' : 'assistant',
          kind: typeof raw.kind === 'string' ? raw.kind : 'ask',
          markdown: typeof raw.markdown === 'string' ? raw.markdown : '',
        };
        const key = msg.role + '\u0000' + msg.kind + '\u0000' + msg.markdown;
        let entry = nodeCache.get(id);
        if (!entry || entry.key !== key) {
          entry = { key: key, node: makeTurn(msg) };
          nodeCache.set(id, entry);
        }
        seen.add(id);
        nodes.push(entry.node);
      });
      for (const id of Array.from(nodeCache.keys())) if (!seen.has(id)) nodeCache.delete(id);
      // reconcile children in order, reusing nodes
      nodes.forEach((n, i) => {
        if (listEl.childNodes[i] !== n) listEl.insertBefore(n, listEl.childNodes[i] || null);
      });
      while (listEl.childNodes.length > nodes.length) listEl.removeChild(listEl.lastChild);
      messageCount = nodes.length;
      updateEmpty();
      if (stick || items.length <= 1) scrollToBottom();
      return true;
    },

    setStreaming: function (markdownOrNull, thinking) {
      let md = markdownOrNull;
      let th = thinking;
      if (md && typeof md === 'object' && !Array.isArray(md)) { th = md.thinking; md = md.markdown; }
      pending = { markdown: typeof md === 'string' ? md : null, thinking: !!th };
      if (pending.markdown === null && !pending.thinking) {
        // finishing: render immediately so the final message never flickers
        if (timer) { clearTimeout(timer); timer = 0; }
        flushStream();
        return true;
      }
      scheduleStream();
      return true;
    },

    setReferences: function (map) {
      const m = P.parseArg(map);
      references = {};
      if (m && typeof m === 'object') {
        Object.keys(m).forEach((k) => {
          if (/^r\d{1,6}$/.test(k) && typeof m[k] === 'string') references[k] = m[k].slice(0, 400);
        });
      }
      document.querySelectorAll('a.cite[data-ref]').forEach((a) => {
        const label = a.getAttribute('data-ref');
        const n = parseInt(label.slice(1), 10);
        a.textContent = shortRef(label, n);
        a.title = refTitle(label) || 'Reference ' + n;
      });
      return true;
    },

    setPaperTitle: function (title) {
      const t = P.parseArg(title);
      paperTitle = typeof t === 'string' ? t.replace(/\s+/g, ' ').trim().slice(0, 300) : '';
      updateEmpty();
      return true;
    },
  };

  global.Chat = Chat;

  updateEmpty();
  function ready() { P.postToSwift('chat', { type: 'ready' }); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', ready, { once: true });
  else ready();
})(window);
