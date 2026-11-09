/*
 * Paperreads — shared web helpers (module A).
 *
 * Used by ingest.html (offscreen), reader.html and chat.html. Exposes `window.Paperreads`:
 *   - sanitizer (single allowlist shared by ingest + chat + reader defence-in-depth)
 *   - math protect / restore for Markdown (placeholders survive marked untouched)
 *   - KaTeX rendering of `.m` spans (cached, with raw-TeX fallback)
 *   - block linearisation: the ONE function that defines block text and character offsets,
 *     used both for blocks.json and for highlight offsets so they always round-trip.
 *
 * Everything here is plain ES2020 with no dependencies; KaTeX / marked are used only when
 * the hosting page loaded them.
 */
(function (global) {
  'use strict';

  // ---------------------------------------------------------------------------
  // Sanitizer
  // ---------------------------------------------------------------------------

  const ALLOWED_TAGS = new Set([
    'h1', 'h2', 'h3', 'h4', 'p', 'ul', 'ol', 'li', 'figure', 'figcaption', 'img', 'table',
    'thead', 'tbody', 'tr', 'td', 'th', 'em', 'strong', 'i', 'b', 'sub', 'sup', 'a', 'span',
    'div', 'br', 'blockquote', 'code', 'pre', 'cite',
  ]);

  // Removed together with everything inside them.
  const DROP_TAGS = new Set([
    'script', 'style', 'iframe', 'frame', 'frameset', 'object', 'embed', 'applet', 'form',
    'input', 'button', 'select', 'option', 'optgroup', 'textarea', 'label', 'fieldset',
    'legend', 'svg', 'math', 'template', 'noscript', 'link', 'meta', 'base', 'head', 'title',
    'canvas', 'video', 'audio', 'source', 'track', 'map', 'area', 'param', 'dialog', 'portal',
    'slot', 'nav', 'footer', 'header', 'hr', 'wbr', 'caption', 'colgroup', 'col', 'datalist',
    'output', 'progress', 'meter', 'marquee', 'xmp', 'plaintext', 'noembed', 'noframes',
    'annotation', 'annotation-xml', 'semantics',
  ]);

  // Elements outside the allowlist that have a sensible allowlisted equivalent.
  const RENAME_TAGS = {
    h5: 'h4', h6: 'h4', tfoot: 'tbody', dl: 'div', dt: 'p', dd: 'p', tt: 'code', kbd: 'code',
    samp: 'code', var: 'i', dfn: 'i', address: 'p', q: 'span',
  };

  // Our own class vocabulary. Every other class is stripped.
  const OWN_CLASSES = new Set([
    'm', 'eq', 'eqn', 'tex-fallback', 'cite', 'xref', 'tag', 'sc', 'theorem', 'proof',
    'runin', 'note', 'fnref', 'biblist', 'bibitem', 'listing', 'line', 'algo', 'flexfig',
    'panel', 'fig', 'tbl', 'tabular', 'c', 'l', 'r', 'rt', 'rb', 'tagged', 'ack', 'abstract',
    'pre-wrap',
  ]);

  const MAX_DEPTH = 160;
  const DATA_IMG_RE = /^data:image\/(png|jpe?g|gif|webp|avif|bmp|svg\+xml)[;,]/i;

  function safeHref(value, opts) {
    const v = String(value || '').trim();
    if (!v) return null;
    if (v[0] === '#') return v.length <= 512 && !/\s/.test(v) ? v : null;
    let u;
    try { u = opts && opts.baseURL ? new URL(v, opts.baseURL) : new URL(v); } catch (_) { return null; }
    if (u.protocol !== 'https:') return null;
    if (u.username || u.password) return null;
    return u.href.length <= 4096 ? u.href : null;
  }

  function safeImgSrc(value, opts) {
    const v = String(value || '').trim();
    if (!v) return null;
    if (/^data:/i.test(v)) return DATA_IMG_RE.test(v) && v.length <= 8 * 1024 * 1024 ? v : null;
    let u;
    try { u = opts && opts.baseURL ? new URL(v, opts.baseURL) : new URL(v); } catch (_) { return null; }
    if (u.protocol !== 'https:' || u.username || u.password) return null;
    return u.href.length <= 4096 ? u.href : null;
  }

  function filterClasses(value) {
    const out = [];
    String(value || '').split(/\s+/).forEach((c) => { if (OWN_CLASSES.has(c) && !out.includes(c)) out.push(c); });
    return out.join(' ');
  }

  function copyAttrs(src, dst, tag, opts) {
    let kept = 0;
    const attrs = src.attributes;
    for (let i = 0; i < attrs.length; i++) {
      const name = attrs[i].name.toLowerCase();
      const value = attrs[i].value;
      let out = null;
      switch (name) {
        case 'src': if (tag === 'img') out = safeImgSrc(value, opts); break;
        case 'href': if (tag === 'a') out = safeHref(value, opts); break;
        case 'colspan':
        case 'rowspan':
          if ((tag === 'td' || tag === 'th') && /^\s*\d{1,4}\s*$/.test(value)) {
            const n = parseInt(value, 10);
            if (n >= 1 && n <= 1000) out = String(n);
          }
          break;
        case 'alt': if (tag === 'img') out = value.slice(0, 1000); break;
        case 'data-b': if (/^\d{1,7}$/.test(value)) out = value; break;
        case 'data-tex': if (value.length <= 20000) out = value; break;
        case 'data-d': if (value === '0' || value === '1') out = value; break;
        case 'class': out = filterClasses(value) || null; break;
        case 'id': if (opts && opts.keepIds && value.length <= 256) out = value; break;
        default: break;
      }
      if (out !== null && out !== undefined) { dst.setAttribute(name, out); kept++; }
    }
    return kept;
  }

  /**
   * Rebuilds the children of `srcParent` into fresh elements owned by `doc`, keeping only the
   * allowlist. Returns a DocumentFragment. Nothing from the source tree is moved or adopted,
   * so no attribute or node type can slip through.
   *
   * opts: { allowImages=true, keepIds=false, baseURL }
   */
  function sanitizeChildren(srcParent, doc, opts) {
    const o = Object.assign({ allowImages: true, keepIds: false, baseURL: null }, opts || {});
    const frag = doc.createDocumentFragment();
    walkSanitize(srcParent, frag, doc, o, 0);
    return frag;
  }

  function walkSanitize(srcParent, dstParent, doc, opts, depth) {
    for (let n = srcParent.firstChild; n; n = n.nextSibling) {
      if (n.nodeType === 3) { // text
        dstParent.appendChild(doc.createTextNode(n.data));
        continue;
      }
      if (n.nodeType !== 1) continue; // comments, PIs, CDATA …
      let tag = (n.localName || n.nodeName || '').toLowerCase();
      if (DROP_TAGS.has(tag)) continue;
      if (depth > MAX_DEPTH) { // pathological nesting: keep only its text
        const t = n.textContent;
        if (t) dstParent.appendChild(doc.createTextNode(t));
        continue;
      }
      if (RENAME_TAGS[tag]) tag = RENAME_TAGS[tag];
      if (!ALLOWED_TAGS.has(tag) || (n.namespaceURI && n.namespaceURI !== 'http://www.w3.org/1999/xhtml')) {
        walkSanitize(n, dstParent, doc, opts, depth + 1); // unwrap
        continue;
      }
      if (tag === 'img') {
        const src = opts.allowImages ? safeImgSrc(n.getAttribute('src'), opts) : null;
        if (!src) {
          const alt = (n.getAttribute('alt') || '').trim();
          if (alt && !opts.allowImages) dstParent.appendChild(doc.createTextNode(alt));
          continue;
        }
      }
      const el = doc.createElement(tag);
      const kept = copyAttrs(n, el, tag, opts);
      if (tag === 'span' && kept === 0) { // attribute-less spans are noise
        walkSanitize(n, dstParent, doc, opts, depth + 1);
        continue;
      }
      if (tag === 'a' && !el.hasAttribute('href') && !el.hasAttribute('data-b')) {
        walkSanitize(n, dstParent, doc, opts, depth + 1);
        continue;
      }
      if (tag !== 'img' && tag !== 'br') walkSanitize(n, el, doc, opts, depth + 1);
      dstParent.appendChild(el);
    }
  }

  function inertDocument() {
    return document.implementation.createHTMLDocument('');
  }

  /** Parses `html` (untrusted) and returns sanitized HTML. */
  function sanitizeHTML(html, opts) {
    const src = new DOMParser().parseFromString(String(html || ''), 'text/html');
    const doc = inertDocument();
    const box = doc.createElement('div');
    box.appendChild(sanitizeChildren(src.body, doc, opts));
    return box.innerHTML;
  }

  // ---------------------------------------------------------------------------
  // Math protect / restore (Markdown → marked → HTML)
  // ---------------------------------------------------------------------------

  const PH_OPEN = '';
  const PH_CLOSE = '';
  const PH_RE = /(\d+)/g;

  function isWS(c) { return c === ' ' || c === '\t' || c === '\n' || c === '\r' || c === '\f' || c === ' '; }

  /** Finds the index of `needle` at or after `from` that is not backslash-escaped. */
  function findUnescaped(s, needle, from) {
    let i = from;
    while (true) {
      i = s.indexOf(needle, i);
      if (i < 0) return -1;
      let bs = 0;
      for (let k = i - 1; k >= 0 && s[k] === '\\'; k--) bs++;
      if (bs % 2 === 0) return i;
      i += 1;
    }
  }

  function protectSegment(s, maths, opts) {
    let out = '';
    let i = 0;
    const n = s.length;
    const isolateDisplay = !!(opts && opts.isolateDisplay);
    const push = (tex, display, raw) => {
      const idx = maths.length;
      maths.push({ tex: tex, display: display, raw: raw });
      return PH_OPEN + idx + PH_CLOSE;
    };
    while (i < n) {
      const c = s[i];
      if (c === '\\') {
        const d = s[i + 1];
        if (d === '[' || d === '(') {
          const close = d === '[' ? '\\]' : '\\)';
          const end = s.indexOf(close, i + 2);
          if (end > i + 2) {
            const tex = s.slice(i + 2, end);
            if (d === '(' && /\n\s*\n/.test(tex)) { out += c; i += 1; continue; }
            const raw = s.slice(i, end + 2);
            let ph = push(tex, d === '[', raw);
            if (d === '[' && isolateDisplay) ph = isolate(s, i, end + 2, ph);
            out += ph;
            i = end + 2;
            continue;
          }
        }
        // keep escapes (e.g. "\$") intact for marked
        out += c + (d === undefined ? '' : d);
        i += 2;
        continue;
      }
      if (c === '$') {
        if (s[i + 1] === '$') {
          const end = findUnescaped(s, '$$', i + 2);
          if (end > i + 2) {
            const tex = s.slice(i + 2, end);
            if (tex.trim()) {
              const raw = s.slice(i, end + 2);
              let ph = push(tex, true, raw);
              if (isolateDisplay) ph = isolate(s, i, end + 2, ph);
              out += ph;
              i = end + 2;
              continue;
            }
          }
          out += '$$';
          i += 2;
          continue;
        }
        // inline $…$: opener not followed by whitespace, closer not preceded by whitespace
        // and not followed by a digit (avoids "$5 and $10").
        if (i + 1 < n && !isWS(s[i + 1])) {
          let j = i + 1;
          let found = -1;
          while (j < n) {
            j = findUnescaped(s, '$', j);
            if (j < 0) break;
            const between = s.slice(i + 1, j);
            if (/\n[ \t]*\n/.test(between)) break;
            if (s[j + 1] === '$') { j += 2; continue; }
            if (!isWS(s[j - 1]) && !/[0-9]/.test(s[j + 1] || '')) { found = j; break; }
            j += 1;
          }
          if (found > i + 1) {
            out += push(s.slice(i + 1, found), false, s.slice(i, found + 1));
            i = found + 1;
            continue;
          }
        }
        out += c;
        i += 1;
        continue;
      }
      out += c;
      i += 1;
    }
    return out;
  }

  // If a display equation occupies whole, unindented lines, give it its own paragraph so the
  // HTML has <p>PH</p> (which ingest turns into div.eq).
  function isolate(s, start, end, ph) {
    const lineStart = s.lastIndexOf('\n', start - 1) + 1;
    const before = s.slice(lineStart, start);
    const nl = s.indexOf('\n', end);
    const after = s.slice(end, nl < 0 ? s.length : nl);
    if (before.length === 0 && after.trim() === '') return '\n\n' + ph + '\n\n';
    return ph;
  }

  /**
   * Replaces math in Markdown with placeholders, skipping fenced code blocks and inline code.
   * Returns { text, maths: [{tex, display, raw}] }.
   */
  function protectMath(md, opts) {
    const src = String(md || '').replace(/\r\n?/g, '\n');
    const maths = [];
    let out = '';
    let text = '';
    const flushText = () => { if (text) { out += protectInline(text, maths, opts); text = ''; } };
    const lines = src.split('\n');
    let fence = null;
    for (let li = 0; li < lines.length; li++) {
      const line = lines[li];
      const nlc = li < lines.length - 1 ? '\n' : '';
      if (fence) {
        out += line + nlc;
        const m = /^ {0,3}(`{3,}|~{3,})\s*$/.exec(line);
        if (m && m[1][0] === fence[0] && m[1].length >= fence.length) fence = null;
        continue;
      }
      const open = /^ {0,3}(`{3,}|~{3,})/.exec(line);
      if (open && !(open[1][0] === '`' && line.slice(open.index + open[0].length).includes('`'))) {
        flushText();
        fence = open[1];
        out += line + nlc;
        continue;
      }
      text += line + nlc;
    }
    flushText();
    return { text: out, maths: maths };
  }

  // Splits text on inline code spans (matching backtick runs) and protects math elsewhere.
  function protectInline(s, maths, opts) {
    let out = '';
    let i = 0;
    let last = 0;
    while (i < s.length) {
      if (s[i] === '`') {
        let j = i;
        while (s[j] === '`') j++;
        const run = s.slice(i, j);
        const re = new RegExp('(^|[^`])' + run + '(?!`)', 'g');
        re.lastIndex = j;
        let m;
        let close = -1;
        while ((m = re.exec(s))) { close = m.index + m[1].length; break; }
        if (close >= 0 && !/\n[ \t]*\n/.test(s.slice(j, close))) {
          out += protectSegment(s.slice(last, i), maths, opts) + s.slice(i, close + run.length);
          i = close + run.length;
          last = i;
          continue;
        }
        i = j;
        continue;
      }
      i++;
    }
    return out + protectSegment(s.slice(last), maths, opts);
  }

  function collapseTeX(tex) { return String(tex).replace(/\s+/g, ' ').trim(); }

  function makeMathSpan(doc, tex, display) {
    const span = doc.createElement('span');
    span.className = 'm';
    span.setAttribute('data-tex', String(tex).trim());
    span.setAttribute('data-d', display ? '1' : '0');
    return span;
  }

  /** Replaces placeholder tokens inside text nodes (and alt attributes) with math spans. */
  function restoreMath(root, maths) {
    if (!maths || !maths.length) return;
    const doc = root.ownerDocument || root;
    const texts = [];
    const tw = doc.createTreeWalker(root, 4 /* SHOW_TEXT */);
    for (let t = tw.nextNode(); t; t = tw.nextNode()) if (t.data.indexOf(PH_OPEN) >= 0) texts.push(t);
    texts.forEach((t) => {
      const inCode = t.parentNode && t.parentNode.closest && t.parentNode.closest('code, pre');
      const frag = doc.createDocumentFragment();
      let last = 0;
      const s = t.data;
      PH_RE.lastIndex = 0;
      let m;
      while ((m = PH_RE.exec(s))) {
        if (m.index > last) frag.appendChild(doc.createTextNode(s.slice(last, m.index)));
        const item = maths[+m[1]];
        if (!item) { last = m.index + m[0].length; continue; }
        if (inCode) frag.appendChild(doc.createTextNode(item.raw));
        else frag.appendChild(makeMathSpan(doc, item.tex, item.display));
        last = m.index + m[0].length;
      }
      if (last < s.length) frag.appendChild(doc.createTextNode(s.slice(last)));
      t.parentNode.replaceChild(frag, t);
    });
    if (root.querySelectorAll) {
      root.querySelectorAll('img[alt]').forEach((img) => {
        const alt = img.getAttribute('alt');
        if (alt.indexOf(PH_OPEN) >= 0) {
          img.setAttribute('alt', alt.replace(PH_RE, (_, k) => (maths[+k] ? maths[+k].raw : '')));
        }
      });
    }
  }

  /**
   * Untrusted Markdown → sanitized DOM fragment (owned by `doc`) with math spans restored.
   * Order: protect math → marked → sanitize → restore math. KaTeX is applied by the caller.
   */
  function markdownToFragment(md, doc, opts) {
    const o = opts || {};
    const prot = protectMath(md, { isolateDisplay: !!o.isolateDisplay });
    let html;
    if (global.marked && typeof global.marked.parse === 'function') {
      html = global.marked.parse(prot.text, { async: false, gfm: true, breaks: false });
    } else {
      const esc = doc.createElement('div');
      esc.textContent = prot.text;
      html = '<p>' + esc.innerHTML.replace(/\n{2,}/g, '</p><p>') + '</p>';
    }
    const parsed = new DOMParser().parseFromString(String(html), 'text/html');
    const frag = sanitizeChildren(parsed.body, doc, { allowImages: o.allowImages !== false });
    const holder = doc.createElement('div');
    holder.appendChild(frag);
    restoreMath(holder, prot.maths);
    const out = doc.createDocumentFragment();
    while (holder.firstChild) out.appendChild(holder.firstChild);
    return out;
  }

  // ---------------------------------------------------------------------------
  // KaTeX rendering
  // ---------------------------------------------------------------------------

  const KATEX_MACROS = {
    '\\mathbbm': '\\mathbb{#1}',
    '\\mathds': '\\mathbb{#1}',
    '\\textsc': '\\text{#1}',
    '\\nicefrac': '\\frac{#1}{#2}',
    '\\bm': '\\boldsymbol{#1}',
    '\\bold': '\\mathbf{#1}',
    '\\EE': '\\mathbb{E}',
    '\\RR': '\\mathbb{R}',
    '\\NN': '\\mathbb{N}',
    '\\ZZ': '\\mathbb{Z}',
    '\\CC': '\\mathbb{C}',
    '\\argmin': '\\operatorname*{arg\\,min}',
    '\\argmax': '\\operatorname*{arg\\,max}',
    '\\qedhere': '',
    '\\nonumber': '',
    '\\notag': '',
    '\\displaylimits': '',
    '\\allowbreak': '',
    '\\protect': '',
    '\\hdots': '\\ldots',
    '\\textup': '\\textrm{#1}',
    '\\upmu': '\\mu',
    '\\updelta': '\\delta',
  };

  const renderCache = new Map(); // key → html | null (error)
  const RENDER_CACHE_MAX = 1500;
  const rendered = new WeakSet();

  function katexHTML(tex, display) {
    const key = (display ? 'D' : 'I') + tex;
    if (renderCache.has(key)) return renderCache.get(key);
    let html = null;
    try {
      html = global.katex.renderToString(tex, {
        displayMode: display,
        throwOnError: true,
        strict: 'ignore',
        trust: false,
        output: 'htmlAndMathml',
        maxExpand: 1000,
        maxSize: 40,
        macros: Object.assign({}, KATEX_MACROS),
      });
    } catch (_) {
      html = null;
    }
    if (renderCache.size >= RENDER_CACHE_MAX) renderCache.delete(renderCache.keys().next().value);
    renderCache.set(key, html);
    return html;
  }

  /** Renders one `.m` span in place. Idempotent. */
  function renderMathEl(el) {
    if (rendered.has(el)) return;
    rendered.add(el);
    const tex = el.getAttribute('data-tex') || '';
    const display = el.getAttribute('data-d') === '1';
    const html = global.katex ? katexHTML(tex, display) : null;
    if (html !== null) {
      el.innerHTML = html; // KaTeX output with trust:false
    } else {
      const code = document.createElement('code');
      code.className = 'tex-fallback';
      code.textContent = tex;
      el.textContent = '';
      el.appendChild(code);
    }
  }

  /** Synchronously renders every `.m` inside root. */
  function renderMath(root) {
    root.querySelectorAll('span.m').forEach(renderMathEl);
  }

  /**
   * Renders `.m` spans in frame-sized batches so big papers stay responsive. Spans near the
   * viewport go first. Returns a cancel function.
   */
  function renderMathProgressive(root, onDone) {
    const all = Array.from(root.querySelectorAll('span.m'));
    const vh = global.innerHeight || 800;
    const near = [];
    const rest = [];
    all.forEach((el) => {
      const r = el.getBoundingClientRect();
      (r.top < vh * 2 && r.bottom > -vh ? near : rest).push(el);
    });
    const queue = near.concat(rest);
    let i = 0;
    let cancelled = false;
    function step() {
      if (cancelled) return;
      const t0 = performance.now();
      while (i < queue.length && performance.now() - t0 < 12) renderMathEl(queue[i++]);
      if (i < queue.length) requestAnimationFrame(step);
      else if (onDone) onDone();
    }
    step();
    return () => { cancelled = true; };
  }

  // ---------------------------------------------------------------------------
  // Block linearisation (block text + offsets)
  // ---------------------------------------------------------------------------

  /** Elements that receive data-b. Anchors also carry data-b (internal links) — excluded. */
  const BLOCK_SELECTOR = '[data-b]:not(a)';

  // Element boundaries that separate words (cells, paragraphs …) even without whitespace.
  const BREAKING = new Set([
    'P', 'DIV', 'LI', 'TD', 'TH', 'TR', 'TABLE', 'THEAD', 'TBODY', 'UL', 'OL', 'FIGURE',
    'FIGCAPTION', 'BLOCKQUOTE', 'PRE', 'H1', 'H2', 'H3', 'H4', 'IMG',
  ]);

  // Offsets encoding in `offs`:
  //   >= 0  character offset inside text node `nodes[i]`
  //   -1    atomic element (math span / br): position before the element
  //   -2    start inside element `nodes[i]`
  //   -3    end inside element `nodes[i]`
  const OFF_BEFORE = -1;
  const OFF_START = -2;
  const OFF_END = -3;

  function mathString(el) {
    const tex = collapseTeX(el.getAttribute('data-tex') || '');
    return el.getAttribute('data-d') === '1' ? '$$' + tex + '$$' : '$' + tex + '$';
  }

  /**
   * Linearises `root` into the canonical block text: text nodes in order, each `.m` span as
   * `$tex$` / `$$tex$$` (atomic; its rendered KaTeX is ignored), whitespace collapsed to single
   * spaces, trimmed. With `withMap`, also returns per-character DOM positions.
   */
  function linearize(root, withMap) {
    const parts = [];
    const nodes = withMap ? [] : null;
    const offs = withMap ? [] : null;
    let space = true; // suppress leading whitespace
    let len = 0;

    function pushWS(node, off) {
      if (space) return;
      parts.push(' ');
      if (withMap) { nodes.push(node); offs.push(off); }
      len++;
      space = true;
    }
    function pushStr(str, node, off) {
      for (let k = 0; k < str.length; k++) {
        const ch = str[k];
        if (isWS(ch) || ch === '​') {
          if (ch === '​') continue;
          if (space) continue;
          parts.push(' ');
          space = true;
        } else {
          parts.push(ch);
          space = false;
        }
        if (withMap) { nodes.push(node); offs.push(off === null ? k : off); }
        len++;
      }
    }
    function walk(parent) {
      for (let c = parent.firstChild; c; c = c.nextSibling) {
        if (c.nodeType === 3) {
          pushStr(c.data, c, null);
        } else if (c.nodeType === 1) {
          const tag = c.tagName;
          if (tag === 'SPAN' && c.classList.contains('m')) {
            const s = mathString(c);
            for (let k = 0; k < s.length; k++) {
              parts.push(s[k]);
              if (withMap) { nodes.push(c); offs.push(OFF_BEFORE); }
              len++;
            }
            space = false;
          } else if (tag === 'BR') {
            pushWS(c, OFF_BEFORE);
          } else if (tag === 'SCRIPT' || tag === 'STYLE' || c.hasAttribute('data-pr-ui')) {
            continue;
          } else {
            const brk = BREAKING.has(tag) || (c.classList.contains('tag') || c.classList.contains('eqn'));
            if (brk) pushWS(c, OFF_START);
            walk(c);
            if (brk) pushWS(c, OFF_END);
          }
        }
      }
    }
    walk(root);
    if (parts.length && parts[parts.length - 1] === ' ') {
      parts.pop();
      if (withMap) { nodes.pop(); offs.pop(); }
      len--;
    }
    return { text: parts.join(''), nodes: nodes, offs: offs, length: len };
  }

  /** Canonical block text (used for blocks.json and selection context). */
  function blockText(el) { return linearize(el, false).text; }

  /** DOM point (node, offset) immediately before character i of a linearisation. */
  function charPoint(lin, i) {
    const n = lin.nodes[i];
    const o = lin.offs[i];
    if (o >= 0) return [n, o];
    if (o === OFF_START) return [n, 0];
    if (o === OFF_END) return [n, n.childNodes.length];
    const p = n.parentNode;
    return [p, Array.prototype.indexOf.call(p.childNodes, n)];
  }

  /**
   * Character offset of DOM boundary (node, offset) within a linearisation: the number of
   * characters positioned strictly before it. Binary search (positions are monotone).
   */
  function offsetOfPoint(lin, node, offset) {
    const doc = node.ownerDocument || node;
    const r = doc.createRange();
    try { r.setStart(node, offset); } catch (_) { return 0; }
    r.collapse(true);
    let lo = 0;
    let hi = lin.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      const pt = charPoint(lin, mid);
      let cmp;
      try { cmp = r.comparePoint(pt[0], pt[1]); } catch (_) { cmp = 1; }
      if (cmp < 0) lo = mid + 1; else hi = mid;
    }
    return lo;
  }

  // ---------------------------------------------------------------------------
  // Misc
  // ---------------------------------------------------------------------------

  function postToSwift(handler, message) {
    try {
      const h = global.webkit && global.webkit.messageHandlers && global.webkit.messageHandlers[handler];
      if (h) h.postMessage(message);
    } catch (_) { /* host not attached (e.g. tests) */ }
  }

  function parseArg(x) {
    if (typeof x === 'string') {
      try { return JSON.parse(x); } catch (_) { return x; }
    }
    return x;
  }

  global.Paperreads = {
    ALLOWED_TAGS: ALLOWED_TAGS,
    OWN_CLASSES: OWN_CLASSES,
    BLOCK_SELECTOR: BLOCK_SELECTOR,
    OFF_BEFORE: OFF_BEFORE,
    sanitizeChildren: sanitizeChildren,
    sanitizeHTML: sanitizeHTML,
    safeHref: safeHref,
    safeImgSrc: safeImgSrc,
    inertDocument: inertDocument,
    protectMath: protectMath,
    restoreMath: restoreMath,
    makeMathSpan: makeMathSpan,
    markdownToFragment: markdownToFragment,
    collapseTeX: collapseTeX,
    renderMath: renderMath,
    renderMathEl: renderMathEl,
    renderMathProgressive: renderMathProgressive,
    linearize: linearize,
    blockText: blockText,
    charPoint: charPoint,
    offsetOfPoint: offsetOfPoint,
    postToSwift: postToSwift,
    parseArg: parseArg,
  };
})(typeof window !== 'undefined' ? window : globalThis);
