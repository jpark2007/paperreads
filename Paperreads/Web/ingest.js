/*
 * Paperreads — ingest (module A). Runs in an offscreen WKWebView loading ingest.html.
 *
 *   Ingest.fromArxivHTML(html, baseURL) → JSON string of IngestResult
 *   Ingest.fromMarkdown(md)             → JSON string of IngestResult
 *
 * IngestResult = { title, authors: [String], abstract, html, blocks: [{b, section, text}] }
 *
 * All parsing happens in inert documents (DOMParser / createHTMLDocument), so nothing in the
 * untrusted input is ever executed or fetched. The output HTML is rebuilt through the shared
 * allowlist sanitizer, then block-tagged.
 */
(function (global) {
  'use strict';

  const P = global.Paperreads;

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  function collapse(s) { return String(s || '').replace(/[\s ​]+/g, ' ').trim(); }

  function texEscapeText(s) {
    return String(s).replace(/[\\{}$%&#_^~]/g, (c) => {
      switch (c) {
        case '\\': return '\\textbackslash{}';
        case '^': return '\\textasciicircum{}';
        case '~': return '\\textasciitilde{}';
        default: return '\\' + c;
      }
    });
  }

  function removeAll(root, selector) {
    root.querySelectorAll(selector).forEach((el) => { if (el.parentNode) el.parentNode.removeChild(el); });
  }

  function unwrap(el) {
    const p = el.parentNode;
    if (!p) return;
    while (el.firstChild) p.insertBefore(el.firstChild, el);
    p.removeChild(el);
  }

  function rename(el, tag) {
    const doc = el.ownerDocument;
    const n = doc.createElement(tag);
    for (let i = 0; i < el.attributes.length; i++) n.setAttribute(el.attributes[i].name, el.attributes[i].value);
    while (el.firstChild) n.appendChild(el.firstChild);
    el.parentNode.replaceChild(n, el);
    return n;
  }

  function hasClass(el, c) { return el.classList && el.classList.contains(c); }

  /** LaTeXML's expanded pgf/TikZ code: never TeX anyone can (or should) read. */
  const PGF_TEX_RE = /\\lxSVG@|\\pgfpicture|\\pgfsys@|\\endpgfpicture/;

  /** TeX source of a MathML element (LaTeXML puts it in alttext). */
  function mathTeX(math) {
    let tex = math.getAttribute('alttext');
    if (!tex) {
      const ann = math.querySelector('annotation[encoding="application/x-tex"], annotation[encoding="application/x-latex"]');
      if (ann) tex = ann.textContent;
    }
    if (!tex) tex = math.textContent;
    tex = String(tex || '').replace(/\\lx@inpgf@ignorespaces\s*/g, '').trim();
    // A picture inside the formula: the alttext is kilobytes of pgf internals. Rebuild the
    // TeX from the MathML presentation instead (pictures themselves are handled by callers).
    if (PGF_TEX_RE.test(tex)) tex = mathmlToTeX(math);
    return tex;
  }

  /** Readable text of a <math> (its MathML presentation), for when KaTeX cannot parse the TeX. */
  function mathAlt(math) {
    const c = math.cloneNode(true);
    c.querySelectorAll('annotation, annotation-xml, img, svg, .box').forEach((n) => n.remove());
    const parts = [];
    (function walk(n) {
      for (let k = n.firstChild; k; k = k.nextSibling) {
        if (k.nodeType === 3) { parts.push(k.data); continue; }
        if (k.nodeType !== 1) continue;
        if (k.localName === 'mo') {
          const t = collapse(k.textContent.replace(INVISIBLE_MATH_RE, ''));
          parts.push(/^[=+−\-<>≤≥≈≡≔→↦⊗×∘∈⊂⊆:]=?$|^:=$/.test(t) ? ' ' + t + ' ' : t);
          continue;
        }
        walk(k);
        if (/^(mtd|mtr)$/.test(k.localName)) parts.push(' ');
      }
    })(c);
    return collapse(parts.join('').replace(INVISIBLE_MATH_RE, '')).slice(0, 2000);
  }

  // MathML presentation → TeX, for formulas whose alttext is unusable (pictures inside).
  const TEX_SPECIAL_RE = /[\\{}$%&#_^~]/g;
  function texToken(s) {
    return String(s).replace(INVISIBLE_MATH_RE, '').replace(TEX_SPECIAL_RE, (c) => (c === '\\' ? '\\backslash ' : c === '^' ? '\\hat{}' : c === '~' ? '\\sim ' : '\\' + c));
  }
  function mathmlToTeX(el) {
    const kids = (n) => Array.from(n.children).filter((c) => !/^(annotation|annotation-xml)$/.test(c.localName));
    const g = (n) => '{' + (n ? conv(n) : '') + '}';
    function conv(n) {
      const t = n.localName;
      const k = kids(n);
      switch (t) {
        case 'mi': {
          const s = collapse(n.textContent);
          return s.length > 1 ? '\\mathrm{' + texToken(s) + '}' : texToken(s);
        }
        case 'mn': return texToken(collapse(n.textContent));
        case 'mo': return texToken(collapse(n.textContent)) + ' ';
        case 'mtext': {
          const s = n.textContent.replace(INVISIBLE_MATH_RE, '');
          return collapse(s) ? '\\text{' + texEscapeText(s) + '}' : '';
        }
        case 'mspace': return '\\,';
        case 'msub': return g(k[0]) + '_' + g(k[1]);
        case 'msup': return g(k[0]) + '^' + g(k[1]);
        case 'msubsup': return g(k[0]) + '_' + g(k[1]) + '^' + g(k[2]);
        case 'munder': return '\\underset' + g(k[1]) + g(k[0]);
        case 'mover': return '\\overset' + g(k[1]) + g(k[0]);
        case 'munderover': return '\\overset' + g(k[2]) + '{\\underset' + g(k[1]) + g(k[0]) + '}';
        case 'mfrac': return '\\frac' + g(k[0]) + g(k[1]);
        case 'msqrt': return '\\sqrt{' + k.map(conv).join('') + '}';
        case 'mroot': return '\\sqrt[' + (k[1] ? conv(k[1]) : '') + ']' + g(k[0]);
        case 'mtable':
          return '\\begin{matrix}' + k.map((r) => kids(r).map((c) => conv(c)).join(' & ')).join(' \\\\ ') + '\\end{matrix}';
        case 'mtr': case 'mlabeledtr': return k.map(conv).join(' & ');
        case 'semantics': return k.length ? conv(k[0]) : '';
        case 'img': case 'svg': return '';
        default: return k.map(conv).join('');
      }
    }
    return conv(el).replace(/\s+/g, ' ').trim();
  }

  /** Pictures LaTeXML drew inside a formula (after convertPictures: img.diagram / div.box). */
  function mathHasPicture(math) { return !!math.querySelector('img, svg, div.box'); }

  /**
   * A formula with pictures inside, as a sequence of TeX runs and the (already converted)
   * picture nodes: [{tex}|{node}]. The TeX of each run is rebuilt from MathML.
   */
  function splitPictureMath(math) {
    const items = [];
    let run = [];
    const flush = () => {
      const tex = run.join('').replace(/\s+/g, ' ').trim();
      run = [];
      if (tex) items.push({ tex: tex });
    };
    (function walk(n) {
      for (let c = n.firstElementChild; c; c = c.nextElementSibling) {
        const t = c.localName;
        if (t === 'annotation' || t === 'annotation-xml') continue;
        if (t === 'img' || t === 'svg' || (t === 'div' && hasClass(c, 'box'))) {
          flush();
          items.push({ node: c });
          continue;
        }
        if (mathHasPicture(c)) { walk(c); continue; }
        run.push(mathmlToTeX(c) + ' ');
      }
    })(math);
    flush();
    return items;
  }

  /** `items` from splitPictureMath → inline content: math spans and the pictures. */
  function pictureMathFragment(doc, items, display) {
    const frag = doc.createDocumentFragment();
    items.forEach((it) => {
      if (it.node) frag.appendChild(it.node);
      else frag.appendChild(P.makeMathSpan(doc, (display ? '\\displaystyle ' : '') + it.tex, false));
    });
    return frag;
  }

  /** Plain text with <br> and block boundaries as newlines (for author parsing). */
  function textWithBreaks(el) {
    let out = '';
    (function walk(n) {
      for (let c = n.firstChild; c; c = c.nextSibling) {
        if (c.nodeType === 3) out += c.data;
        else if (c.nodeType === 1) {
          const t = c.localName;
          if (t === 'br') { out += '\n'; continue; }
          if (t === 'math') { out += c.textContent; continue; }
          const block = /^(p|div|li|tr|td|th|h[1-6]|table|ul|ol)$/.test(t) || hasClass(c, 'ltx_role_address') || hasClass(c, 'ltx_contact');
          if (block) out += '\n';
          walk(c);
          if (block) out += '\n';
        }
      }
    })(el);
    return out;
  }

  /** Title text with math rendered as its Unicode MathML text (readable natively). */
  function unicodeText(el) {
    const c = el.cloneNode(true);
    c.querySelectorAll('.ltx_note, .ltx_role_footnote, sup.ltx_note_mark, .ltx_tag, .ltx_pubnotes, .ltx_role_thanks, annotation, annotation-xml').forEach((n) => n.remove());
    return collapse(c.textContent);
  }

  const AFFIL_RE = /(univ|institut|department|dept\b|laborator|school|college|faculty|research|\binc\b|ltd|corp|gmbh|google|microsoft|meta\b|openai|deepmind|anthropic|nvidia|amazon|apple|ibm\b|\blab\b|labs\b|center|centre|academy|hospital|foundation|company|\bai\b|technolog|polytechn|ecole|école|universit|\bmit\b|\bcnrs\b|\binria\b|correspond|equal contribution|contributed equally|\bwork done)/i;

  const NAME_WORD_RE = /^(\p{Lu}[\p{L}\p{M}'’.\-]*|[\p{Lo}\p{M}]+|de|van|von|der|den|da|das|di|do|la|le|du|dos|del|della|y|bin|binti|al|el|ibn|zu|ten|ter|st\.)$/u;

  function cleanAuthorName(raw) {
    let s = String(raw || '').replace(/[†‡§¶*∗⋆★♠♣♢♡♯†‡§¶✉]/g, ' ');
    s = s.replace(/\(?\d+(,\d+)*\)?$/g, ' ');
    s = collapse(s).replace(/^[,;:&\s]+|[,;:&\s]+$/g, '');
    if (!s || s.length < 2 || s.length > 60) return null;
    if (/@|https?:|www\./i.test(s)) return null;
    if (/\d/.test(s)) return null;
    if (AFFIL_RE.test(s)) return null;
    if (s.split(' ').length > 6) return null;
    if (!/\p{L}/u.test(s)) return null;
    if (!s.split(' ').every((w) => NAME_WORD_RE.test(w))) return null;
    return s;
  }

  function splitAuthors(text) {
    const out = [];
    String(text || '').split(/\n|,|;|\s+and\s+|\s*&\s*|\s{3,}/).forEach((piece) => {
      const name = cleanAuthorName(piece);
      if (name && !out.some((x) => x.toLowerCase() === name.toLowerCase())) out.push(name);
    });
    return out;
  }

  // ---------------------------------------------------------------------------
  // Block tagging (shared by both paths)
  // ---------------------------------------------------------------------------

  /**
   * Assigns data-b=0..n in document order to h2,h3,h4, p, li (no nested p), figcaption,
   * div.eq, table (not inside div.eq), blockquote (no nested p), pre and div.listing (code
   * and algorithm listings). An element inside an
   * already-tagged block is not tagged again (so block texts never overlap). Empty blocks
   * are skipped. Returns [{b, section, text}].
   */
  function tagBlocks(container) {
    const blocks = [];
    let section = '';
    let b = 0;
    const tagged = [];
    const candidates = container.querySelectorAll('h2, h3, h4, p, li, figcaption, div.eq, table, blockquote, pre, div.listing');
    candidates.forEach((el) => {
      const tag = el.localName;
      if (tag === 'li' && el.querySelector('p')) return;
      if (tag === 'blockquote' && el.querySelector('p')) return;
      if (tag === 'table' && el.closest('div.eq')) return;
      if (tag === 'p' && el.closest('div.eq')) return;
      for (let a = el.parentElement; a && a !== container; a = a.parentElement) {
        if (a.hasAttribute('data-b')) return;
      }
      const text = P.blockText(el);
      if (!text) return;
      if (tag === 'h2' || tag === 'h3') section = text;
      el.setAttribute('data-b', String(b));
      tagged.push(el);
      blocks.push({ b: b, section: section, text: text });
      b++;
    });
    return blocks;
  }

  const BLOCKISH = 'h2, h3, h4, p, li, figcaption, div.eq, table, blockquote, pre, div.listing';

  /** data-b of the block best representing `target` (itself, first inside, ancestor, next). */
  function blockForTarget(target, container) {
    if (target.hasAttribute('data-b') && target.localName !== 'a') return target.getAttribute('data-b');
    const inside = target.querySelector(P.BLOCK_SELECTOR);
    if (inside) return inside.getAttribute('data-b');
    const anc = target.closest(P.BLOCK_SELECTOR);
    if (anc && container.contains(anc)) return anc.getAttribute('data-b');
    // first block after the target in document order
    const doc = container.ownerDocument;
    const tw = doc.createTreeWalker(container, 1 /* SHOW_ELEMENT */);
    tw.currentNode = target;
    for (let n = tw.nextNode(); n; n = tw.nextNode()) {
      if (n.hasAttribute('data-b') && n.localName !== 'a') return n.getAttribute('data-b');
    }
    return null;
  }

  /** Internal `#id` links → data-b on the anchor (href removed); then all ids stripped. */
  function resolveInternalLinks(container) {
    const ids = new Map();
    container.querySelectorAll('[id]').forEach((el) => { if (!ids.has(el.id)) ids.set(el.id, el); });
    container.querySelectorAll('a[href^="#"]').forEach((a) => {
      let id = a.getAttribute('href').slice(1);
      try { id = decodeURIComponent(id); } catch (_) { /* keep raw */ }
      const target = ids.get(id);
      const b = target ? blockForTarget(target, container) : null;
      a.removeAttribute('href');
      if (b !== null) {
        a.setAttribute('data-b', b);
        a.classList.add('xref');
      } else {
        unwrap(a);
      }
    });
    container.querySelectorAll('[id]').forEach((el) => el.removeAttribute('id'));
  }

  /**
   * Round-trips the built tree through the HTML parser. The tree was assembled with DOM calls,
   * which allow nestings the parser never produces (e.g. a <div> inside a <p>, from LaTeXML
   * description items). The reader re-parses content.html, so blocks must be tagged on exactly
   * the structure the parser yields, or block ids and blocks.json drift from what is shown.
   */
  function reparse(container) {
    const doc = new DOMParser().parseFromString(
      '<!DOCTYPE html><html><head></head><body>' + container.innerHTML + '</body></html>', 'text/html');
    return doc.body;
  }

  function finish(title, authors, abstract, built) {
    const container = reparse(built);
    const blocks = tagBlocks(container);
    resolveInternalLinks(container);
    return {
      title: collapse(title),
      authors: authors,
      abstract: String(abstract || '').trim(),
      html: container.innerHTML,
      blocks: blocks,
    };
  }

  // ---------------------------------------------------------------------------
  // arXiv / ar5iv (LaTeXML) HTML
  // ---------------------------------------------------------------------------

  function effectiveBase(doc, baseURL) {
    let base = String(baseURL || '');
    try {
      const u = new URL(base);
      const baseEl = doc.querySelector('base[href]');
      if (baseEl) return new URL(baseEl.getAttribute('href'), u).href;
      // Resolve exactly as a browser showing the page would. arXiv's image paths already
      // carry the versioned id ("2006.11239v2/images/x.png" on /html/2006.11239), so treating
      // the last segment as a directory produced /html/<id>/<id>v2/… — a 404 for every figure.
      u.hash = '';
      u.search = '';
      return u.href;
    } catch (_) {
      return null;
    }
  }

  function samePage(u, base) {
    try {
      const a = new URL(u);
      const b = new URL(base);
      const norm = (x) => x.origin + x.pathname.replace(/\/+$/, '');
      return norm(a) === norm(b);
    } catch (_) { return false; }
  }

  // ---------------------------------------------------------------------------
  // SVG pictures (tcolorbox boxes, TikZ diagrams, pgfplots)
  // ---------------------------------------------------------------------------

  const INVISIBLE_MATH_RE = /[⁡-⁤​]/g;

  /** Readable text of a subtree: MathML as its presentation text (no TeX annotation). */
  function plainText(el) {
    const c = el.cloneNode(true);
    c.querySelectorAll('annotation, annotation-xml, script, style').forEach((n) => n.remove());
    return collapse(c.textContent.replace(INVISIBLE_MATH_RE, ''));
  }

  function svgLength(svg, attr, vbIndex) {
    const v = parseFloat(svg.getAttribute(attr));
    if (isFinite(v) && v > 0) return v;
    const vb = (svg.getAttribute('viewBox') || '').trim().split(/[\s,]+/).map(parseFloat);
    return vb.length === 4 && isFinite(vb[vbIndex]) ? vb[vbIndex] : 0;
  }

  /**
   * A picture is a "box" (tcolorbox, framed theorem, mdframed …) when it carries at most a few
   * foreignObjects and the widest spans most of the picture: its content is running text,
   * not labels placed on a drawing.
   */
  function isBoxPicture(svg, fos) {
    if (!fos.length || fos.length > 4) return false;
    // Pictures inside formulas (ZX diagrams, tikz-cd squares, tree symbols) are drawings.
    if (hasClass(svg, 'ltx_markedasmath') ||
        svg.closest('math, table.ltx_equation, table.ltx_equationgroup, table.ltx_eqn_table, .ltx_eqn_table, .ltx_equationgroup')) return false;
    // TikZ matrices (commutative diagrams) are laid-out nodes, not running text.
    if (svg.querySelector('g.ltx_tikzmatrix')) return false;
    // Several labels that are each only a formula: node and arrow labels of a diagram.
    if (fos.length >= 2 && fos.every((f) => {
      const c = f.cloneNode(true);
      c.querySelectorAll('math').forEach((m) => m.remove());
      return f.querySelector('math') && !collapse(c.textContent);
    })) return false;
    const width = svgLength(svg, 'width', 2);
    const widest = Math.max.apply(null, fos.map((f) => parseFloat(f.getAttribute('width')) || 0));
    if (!(width > 0)) return true;
    if (widest < 0.6 * width) return false;
    // drawn text outside the foreignObjects means it is a diagram with a wide label
    const drawnText = Array.from(svg.querySelectorAll('text')).some((t) => !t.closest('foreignObject') && collapse(t.textContent));
    return !drawnText;
  }

  /** LaTeXML renders block structure inside inline contexts as spans; restore it. */
  function blockifySpans(root) {
    const map = [
      ['span.ltx_figure', 'figure'],
      ['span.ltx_caption', 'figcaption'],
      ['span.ltx_para', 'div'],
      ['span.ltx_p', 'p'],
      ['span.ltx_theorem, span.ltx_proof', 'div'],
      ['span.ltx_itemize', 'ul'],
      ['span.ltx_enumerate', 'ol'],
      ['span.ltx_item', 'li'],
      ['span.ltx_listing', 'div'],
    ];
    map.forEach(([sel, tag]) => {
      Array.from(root.querySelectorAll(sel)).forEach((el) => { if (el.isConnected) rename(el, tag); });
    });
    // minipages / logical blocks that hold paragraphs become plain divs
    Array.from(root.querySelectorAll('span.ltx_minipage, span.ltx_inline-logical-block, span.ltx_inline-block'))
      .reverse()
      .forEach((el) => {
        if (el.isConnected && el.querySelector('p, div, figure, ul, ol, table')) rename(el, 'div');
      });
  }

  /** Replaces `node` (inside `root`) with `repl`; a block replacement is hoisted out of a <p>. */
  function placeBlock(node, repl, root) {
    let target = node;
    // the picture usually sits alone in a span.ltx_inline-block wrapper
    const wrap = node.parentElement;
    if (wrap && wrap !== root && wrap.localName === 'span' && hasClass(wrap, 'ltx_inline-block') &&
        Array.from(wrap.childNodes).every((c) => c === node || (c.nodeType === 3 && !c.data.trim()))) {
      target = wrap;
    }
    const p = target.parentElement && target.parentElement.closest('p, span.ltx_p');
    if (p && root.contains(p) && p !== root) {
      p.parentNode.insertBefore(repl, p.nextSibling);
      target.remove();
    } else {
      target.parentNode.replaceChild(repl, target);
    }
  }

  function pictureToBox(svg, fos, root) {
    const doc = svg.ownerDocument;
    const box = doc.createElement('div');
    box.className = 'box';
    const id = svg.getAttribute('id');
    if (id) box.setAttribute('id', id);
    fos.forEach((fo, i) => {
      const content = fo.querySelector('.ltx_foreignobject_content') || fo;
      const holder = doc.createElement('div');
      while (content.firstChild) holder.appendChild(content.firstChild);
      blockifySpans(holder);
      const text = plainText(holder);
      if (!text && !holder.querySelector('img, math, svg')) return;
      const isTitle = i === 0 && fos.length >= 2 && text.split(' ').length <= 25 &&
        !holder.querySelector('math[display="block"], table, img, figure, ul, ol');
      if (isTitle) {
        const title = doc.createElement('p');
        title.className = 'box-title';
        const ps = holder.querySelectorAll('p');
        if (ps.length === 1) {
          while (ps[0].firstChild) title.appendChild(ps[0].firstChild);
        } else {
          holder.querySelectorAll('p, div, figure, figcaption').forEach((n) => {
            n.parentNode.insertBefore(doc.createTextNode(' '), n);
            unwrap(n);
          });
          while (holder.firstChild) title.appendChild(holder.firstChild);
        }
        box.appendChild(title);
        return;
      }
      // bare inline content (no paragraph structure) gets a paragraph so it is a block
      if (!holder.querySelector('p, div, figure, ul, ol, table, h1, h2, h3, h4, h5, h6')) {
        const p = doc.createElement('p');
        while (holder.firstChild) p.appendChild(holder.firstChild);
        holder.appendChild(p);
      }
      box.appendChild(holder);
    });
    if (!box.childNodes.length) { placeBlock(svg, doc.createTextNode(''), root); return; }
    placeBlock(svg, box, root);
  }

  // Accents drawn over a single character (mover) → combining characters.
  const COMBINING_ACCENT = {
    '\u00AF': '\u0304', '\u203E': '\u0305', '\u2015': '\u0305', '\u0332': '\u0305', '_': '\u0305',
    '^': '\u0302', '\u02C6': '\u0302', '~': '\u0303', '\u02DC': '\u0303', '\u02D9': '\u0307',
    '\u00A8': '\u0308', '\u02C7': '\u030C', '\u00B4': '\u0301', '`': '\u0300', '\u02D8': '\u0306',
    '\u2192': '\u20D7', '\u20D7': '\u20D7',
  };
  const ITALIC_LETTER_RE = /^[A-Za-z\u03B1-\u03C9\u0391-\u03A9]$/;

  /**
   * A label's MathML/HTML as styled runs: [{ text, dy (em, relative to the baseline),
   * scale, italic }]. Sub/superscripts are shifted and smaller, single-letter identifiers
   * italic, over-accents become combining characters — so f_{r-1} does not read "fr−1".
   */
  function labelRuns(fo) {
    const runs = [];
    const push = (text, st) => {
      text = text.replace(INVISIBLE_MATH_RE, '');
      if (!text) return;
      const last = runs[runs.length - 1];
      if (last && last.dy === st.dy && last.scale === st.scale && last.italic === st.italic) last.text += text;
      else runs.push({ text, dy: st.dy, scale: st.scale, italic: st.italic });
    };
    const script = (st, up) => {
      const scale = Math.max(0.5, st.scale * 0.72);
      return { dy: st.dy + (up ? -0.42 : 0.28) * st.scale, scale, italic: st.italic };
    };
    const kids = (el) => Array.from(el.children);
    function walk(n, st, depth) {
      if (depth > 60) return;
      if (n.nodeType === 3) { push(n.data.replace(/[ \t\n\r\f]+/g, ' '), st); return; }
      if (n.nodeType !== 1) return;
      const tag = String(n.localName || '').toLowerCase();
      const c = kids(n);
      switch (tag) {
        case 'annotation': case 'annotation-xml': case 'script': case 'style': return;
        case 'mi': {
          const t = n.textContent.trim();
          const italic = ITALIC_LETTER_RE.test(t) && n.getAttribute('mathvariant') !== 'normal';
          push(t, { dy: st.dy, scale: st.scale, italic });
          return;
        }
        case 'mn': case 'mo': case 'mtext': case 'ms':
          push(n.textContent.trim(), { dy: st.dy, scale: st.scale, italic: false });
          return;
        case 'mspace': push(' ', st); return;
        case 'msub': case 'msup': case 'msubsup':
          if (c.length < 2) break;
          walk(c[0], st, depth + 1);
          if (tag !== 'msup') walk(c[1], script(st, false), depth + 1);
          if (tag === 'msup') walk(c[1], script(st, true), depth + 1);
          if (tag === 'msubsup' && c[2]) walk(c[2], script(st, true), depth + 1);
          return;
        case 'mover': case 'munder': case 'munderover': {
          if (c.length < 2) break;
          const over = tag === 'mover' ? c[1] : tag === 'munderover' ? c[2] : null;
          const base = c[0].textContent.replace(INVISIBLE_MATH_RE, '').trim();
          const accent = over && COMBINING_ACCENT[over.textContent.trim()];
          if (accent && Array.from(base).length === 1 && tag === 'mover') {
            const b = c[0].localName === 'mi' && ITALIC_LETTER_RE.test(base) && c[0].getAttribute('mathvariant') !== 'normal';
            push(base + accent, { dy: st.dy, scale: st.scale, italic: b });
            return;
          }
          walk(c[0], st, depth + 1);
          if (tag !== 'mover') walk(c[1], script(st, false), depth + 1);
          if (over) walk(over, script(st, true), depth + 1);
          return;
        }
        case 'mfrac':
          if (c.length < 2) break;
          walk(c[0], st, depth + 1); push('/', st); walk(c[1], st, depth + 1);
          return;
        case 'msqrt': push('\u221A(', st); c.forEach((k) => walk(k, st, depth + 1)); push(')', st); return;
        case 'mroot':
          if (c.length < 2) break;
          walk(c[1], script(st, true), depth + 1); push('\u221A(', st); walk(c[0], st, depth + 1); push(')', st);
          return;
        case 'br': case 'p': case 'div': push(' ', st); break;
        default: break;
      }
      for (let k = n.firstChild; k; k = k.nextSibling) walk(k, st, depth + 1);
    }
    walk(fo, { dy: 0, scale: 1, italic: false }, 0);
    // trim and collapse spaces across runs
    let prevSpace = true;
    runs.forEach((r) => {
      r.text = r.text.replace(/ +/g, ' ');
      if (prevSpace) r.text = r.text.replace(/^ /, '');
      if (r.text) prevSpace = r.text.endsWith(' ');
    });
    while (runs.length && runs[runs.length - 1].text.trim() === '') runs.pop();
    if (runs.length) runs[runs.length - 1].text = runs[runs.length - 1].text.replace(/ $/, '');
    return runs.filter((r) => r.text);
  }

  /** foreignObject label → SVG <text> drawn where the label was (no HTML inside an image). */
  function labelToText(fo, xdoc) {
    const text = plainText(fo);
    if (!text) return null;
    const width = parseFloat(fo.getAttribute('width')) || 0;
    const height = parseFloat(fo.getAttribute('height')) || 0;
    const fsMatch = /font-size:\s*([\d.]+)pt/.exec(fo.getAttribute('style') || '');
    let fs = fsMatch ? parseFloat(fsMatch[1]) : 10;
    if (!(fs > 0 && fs < 100)) fs = 10;
    const fgMatch = /--ltx-fg-color:\s*(#[0-9a-fA-F]{3,8})/.exec(fo.innerHTML);
    const t = xdoc.createElementNS('http://www.w3.org/2000/svg', 'text');
    const tr = fo.getAttribute('transform');
    if (tr && /^[\w\s().,+\-eE]*$/.test(tr)) t.setAttribute('transform', tr);
    t.setAttribute('font-size', String(fs));
    t.setAttribute('font-family', 'ui-serif, Georgia, serif');
    t.setAttribute('stroke', 'none');
    if (fgMatch) t.setAttribute('fill', fgMatch[1]);
    const x = parseFloat(fo.getAttribute('x')) || 0;
    const y = parseFloat(fo.getAttribute('y')) || 0;
    // wrap only when the box is clearly taller than one line
    const lines = [];
    if (height > fs * 1.9 && width > 0) {
      const maxChars = Math.max(6, Math.floor(width / (fs * 0.5)));
      let line = '';
      text.split(' ').forEach((w) => {
        if (line && (line + ' ' + w).length > maxChars) { lines.push(line); line = w; } else line = line ? line + ' ' + w : w;
      });
      if (line) lines.push(line);
    } else {
      // One line: keep the math structure (scripts, italics, accents).
      const runs = fo.querySelector('math') ? labelRuns(fo) : [];
      if (runs.length && runs.some((r) => r.dy || r.italic || r.scale !== 1 || /[\u0300-\u036F\u20D7]/.test(r.text))) {
        const line = xdoc.createElementNS('http://www.w3.org/2000/svg', 'tspan');
        line.setAttribute('x', String(x));
        line.setAttribute('y', String(+(y + fs * 0.85).toFixed(2)));
        let cur = 0;
        runs.forEach((r) => {
          const span = xdoc.createElementNS('http://www.w3.org/2000/svg', 'tspan');
          if (r.dy !== cur) span.setAttribute('dy', String(+((r.dy - cur) * fs).toFixed(2)));
          cur = r.dy;
          if (r.scale !== 1) span.setAttribute('font-size', String(+(fs * r.scale).toFixed(2)));
          if (r.italic) span.setAttribute('font-style', 'italic');
          span.textContent = r.text;
          line.appendChild(span);
        });
        t.appendChild(line);
        return t;
      }
      lines.push(text);
    }
    lines.forEach((ln, i) => {
      const span = xdoc.createElementNS('http://www.w3.org/2000/svg', 'tspan');
      span.setAttribute('x', String(x));
      span.setAttribute('y', String(+(y + fs * (0.85 + i * 1.2)).toFixed(2)));
      span.textContent = ln;
      t.appendChild(span);
    });
    return t;
  }

  function pictureToImage(svg, fos, root) {
    const doc = svg.ownerDocument;
    const labels = fos.map(plainText).filter(Boolean);
    const width = svgLength(svg, 'width', 2);
    const height = svgLength(svg, 'height', 3);
    let url = null;
    if (width >= 4 && height >= 4) {
      try {
        const clean = P.buildSafeSVG(svg, labelToText);
        if (!clean.getAttribute('viewBox')) clean.setAttribute('viewBox', '0 0 ' + width + ' ' + height);
        url = P.svgDataURL(clean);
      } catch (_) { url = null; }
    }
    if (!url) {
      // too large / degenerate: keep any labels as text so nothing is silently lost
      const span = doc.createElement('span');
      span.textContent = labels.join(' · ');
      svg.parentNode.replaceChild(span, svg);
      return;
    }
    const img = doc.createElement('img');
    img.setAttribute('src', url);
    img.setAttribute('alt', labels.join(' · ').slice(0, 1000));
    img.className = 'diagram';
    const id = svg.getAttribute('id');
    if (id) img.setAttribute('id', id);
    const wrap = svg.parentElement;
    if (wrap && wrap.localName === 'span' && hasClass(wrap, 'ltx_inline-block') &&
        Array.from(wrap.childNodes).every((c) => c === svg || (c.nodeType === 3 && !c.data.trim()))) {
      wrap.parentNode.replaceChild(img, wrap);
    } else {
      svg.parentNode.replaceChild(img, svg);
    }
  }

  /**
   * LaTeXML pictures: tcolorbox-style boxes become div.box with their text (theorems, abstracts
   * and prompts drawn in boxes); everything else becomes a sanitized SVG image.
   */
  function convertPictures(root) {
    // Outermost pictures first; a box's content can itself hold pictures, which surface as
    // outermost on the next round.
    for (let round = 0; round < 8; round++) {
      const svgs = Array.from(root.querySelectorAll('svg')).filter((s) => !(s.parentElement && s.parentElement.closest('svg')));
      if (!svgs.length) return;
      svgs.forEach((svg) => {
        if (!svg.isConnected) return;
        const fos = Array.from(svg.querySelectorAll('foreignObject')).filter((f) => !(f.parentElement && f.parentElement.closest('foreignObject')));
        if (fos.length && isBoxPicture(svg, fos)) pictureToBox(svg, fos, root);
        else pictureToImage(svg, fos, root);
      });
    }
  }

  /**
   * Turns a LaTeXML abstract into `div.abstract > h2 "Abstract" + paragraphs` and makes sure it
   * comes before the first section. The h2 makes "Abstract" the section of its blocks.
   */
  function prepareAbstract(absEl, root) {
    const doc = absEl.ownerDocument;
    Array.from(absEl.querySelectorAll('.ltx_title_abstract, h1, h2, h3, h4, h5, h6')).forEach((h) => {
      if (/^\s*abstract\s*[.:]?\s*$/i.test(h.textContent) || hasClass(h, 'ltx_title_abstract')) h.remove();
    });
    const div = absEl.localName === 'div' ? absEl : rename(absEl, 'div');
    div.classList.add('abstract');
    const h = doc.createElement('h2');
    h.textContent = 'Abstract';
    div.insertBefore(h, div.firstChild);
    // First thing in the body (title/authors are removed later; front-matter notes such as
    // permission statements follow it).
    if (div.parentNode !== root || root.firstElementChild !== div) {
      const prevAbs = Array.from(root.children).filter((c) => c !== div && hasClass(c, 'abstract'));
      const after = prevAbs.length ? prevAbs[prevAbs.length - 1].nextSibling : root.firstChild;
      root.insertBefore(div, after);
    }
  }

  /**
   * Replaces `node` (somewhere inside paragraph `p`) with the block content `frag`, placed
   * between `p` (holding what came before `node`) and a new paragraph holding what came after.
   */
  function splitParagraphAround(p, node, frag) {
    const doc = p.ownerDocument;
    let tail = null;
    if (p.lastChild && !(p.lastChild === node)) {
      const range = doc.createRange();
      range.setStartAfter(node);
      range.setEndAfter(p.lastChild);
      const rest = range.extractContents();
      tail = p.cloneNode(false);
      tail.removeAttribute('id');
      tail.appendChild(rest);
    }
    node.remove();
    const hasContent = (el) => !!(collapse(el.textContent) || el.querySelector('img, math, svg, .m'));
    const parent = p.parentNode;
    const next = p.nextSibling;
    parent.insertBefore(frag, next);
    if (tail && hasContent(tail)) parent.insertBefore(tail, next);
    if (!hasContent(p)) {
      if (p.getAttribute('id') && tail && tail.parentNode && !tail.getAttribute('id')) tail.setAttribute('id', p.getAttribute('id'));
      p.remove();
    }
  }

  /** Converts LaTeXML equation tables into div.eq rows (one per numbered/leaf row). */
  function convertEquationTables(root) {
    const doc = root.ownerDocument;
    // Inside inline contexts (e.g. tcolorbox pictures) LaTeXML writes the same structure with
    // spans: span.ltx_eqn_table > span > span.ltx_eqn_row > span.ltx_eqn_cell.
    const tables = Array.from(root.querySelectorAll(
      'table.ltx_equation, table.ltx_equationgroup, table.ltx_eqn_table, span.ltx_eqn_table, span.ltx_equationgroup'));
    tables.forEach((table) => {
      if (!table.isConnected || !root.contains(table)) return;
      const rows = Array.from(table.querySelectorAll('tr, .ltx_eqn_row')).filter((tr) => !tr.querySelector('tr, .ltx_eqn_row'));
      const out = [];
      rows.forEach((tr) => {
        const tagEl = tr.querySelector('.ltx_tag_equation, .ltx_eqn_eqno .ltx_tag');
        const number = tagEl ? collapse(tagEl.textContent) : '';
        const pieces = [];
        const alts = [];
        (function walk(n) {
          for (let c = n.firstChild; c; c = c.nextSibling) {
            if (c.nodeType === 3) {
              const t = collapse(c.data);
              if (t) { pieces.push('\\text{ ' + texEscapeText(t) + ' }'); alts.push(t); }
            } else if (c.nodeType === 1) {
              if (c.localName === 'math') {
                if (mathHasPicture(c)) splitPictureMath(c).forEach((it) => pieces.push(it.node ? it : it.tex));
                else { pieces.push(mathTeX(c)); alts.push(mathAlt(c)); }
                continue;
              }
              if (c.localName === 'img' || (c.localName === 'div' && hasClass(c, 'box'))) { pieces.push({ node: c }); continue; }
              if (hasClass(c, 'ltx_eqn_eqno') || hasClass(c, 'ltx_tag_equation') || hasClass(c, 'ltx_tag')) continue;
              if (hasClass(c, 'ltx_note')) continue;
              walk(c);
            }
          }
        })(tr);
        const mixed = pieces.some((x) => typeof x !== 'string');
        const tex = mixed ? '' : pieces.filter(Boolean).join(' ').trim();
        const body = tr.parentNode;
        const rowId = tr.getAttribute('id') ||
          (body && (body.localName === 'tbody' || body.localName === 'span') && body !== table &&
            body.firstElementChild === tr ? body.getAttribute('id') || '' : '');
        if (mixed) {
          // pictures in the row: TeX runs and images side by side
          const items = [];
          pieces.forEach((x) => {
            if (typeof x !== 'string') { items.push(x); return; }
            if (!x) return;
            const last = items[items.length - 1];
            if (last && !last.node) last.tex += ' ' + x; else items.push({ tex: x });
          });
          out.push({ items: items, number: number, id: rowId });
          return;
        }
        if (!tex) {
          if (number && out.length && !out[out.length - 1].number) out[out.length - 1].number = number;
          return;
        }
        out.push({ tex: tex, alt: collapse(alts.join(' ')).slice(0, 2000), number: number, id: rowId });
      });
      const frag = doc.createDocumentFragment();
      out.forEach((eq, i) => {
        const div = doc.createElement('div');
        div.className = 'eq';
        const id = eq.id || (i === 0 ? table.getAttribute('id') : '');
        if (id) div.setAttribute('id', id);
        if (eq.items) {
          const line = doc.createElement('span');
          line.appendChild(pictureMathFragment(doc, eq.items, true));
          div.appendChild(line);
        } else {
          div.appendChild(P.makeMathSpan(doc, eq.tex, true, eq.alt));
        }
        if (eq.number) {
          const n = doc.createElement('span');
          n.className = 'eqn';
          n.textContent = eq.number;
          div.appendChild(n);
        }
        frag.appendChild(div);
      });
      // keep the group id reachable for references to the whole group
      if (out.length > 1 && table.getAttribute('id') && frag.firstChild && !frag.firstChild.getAttribute('id')) {
        frag.firstChild.setAttribute('id', table.getAttribute('id'));
      }
      // a div.eq may not live inside <p>: split the paragraph around the equation so the text
      // after it (e.g. "… satisfies [eq] so any two …") stays after it
      const p = table.closest('p');
      if (p && root.contains(p)) {
        splitParagraphAround(p, table, frag);
      } else {
        table.parentNode.replaceChild(frag, table);
      }
    });
  }

  function convertInlineMath(root) {
    const doc = root.ownerDocument;
    Array.from(root.querySelectorAll('math')).forEach((m) => {
      if (!m.isConnected || !m.parentNode) return;
      const display = (m.getAttribute('display') || '').toLowerCase() === 'block';
      if (mathHasPicture(m)) {
        const holder = doc.createElement(display ? 'div' : 'span');
        if (display) holder.className = 'eq';
        const id = m.getAttribute('id');
        if (id) holder.setAttribute('id', id);
        const inner = doc.createElement('span');
        inner.appendChild(pictureMathFragment(doc, splitPictureMath(m), display));
        holder.appendChild(inner);
        const p = display && m.closest('p');
        if (p && root.contains(p)) splitParagraphAround(p, m, holder);
        else m.parentNode.replaceChild(holder, m);
        return;
      }
      const tex = mathTeX(m);
      const span = P.makeMathSpan(doc, tex, display, mathAlt(m));
      const id = m.getAttribute('id');
      if (id) span.setAttribute('id', id);
      m.parentNode.replaceChild(span, m);
    });
  }

  /** LaTeXML footnotes → superscript mark + note paragraph after the enclosing block. */
  function convertFootnotes(root) {
    const doc = root.ownerDocument;
    Array.from(root.querySelectorAll('.ltx_note')).forEach((note) => {
      if (!note.isConnected) return;
      const markEl = note.querySelector('.ltx_note_mark');
      const mark = markEl ? collapse(markEl.textContent) : '';
      const content = note.querySelector('.ltx_note_content');
      const sup = doc.createElement('sup');
      sup.className = 'fnref';
      sup.textContent = mark || '*';
      if (!content) { note.parentNode.replaceChild(sup, note); return; }
      const body = content.cloneNode(true);
      body.querySelectorAll('.ltx_note_mark, .ltx_tag_note').forEach((n) => n.remove());
      // flatten nested block structure into one paragraph
      body.querySelectorAll('p, div, li, ul, ol, table, figure, blockquote').forEach((n) => {
        n.parentNode.insertBefore(doc.createTextNode(' '), n);
        if (n.localName === 'table' || n.localName === 'figure') n.remove(); else unwrap(n);
      });
      const p = doc.createElement('p');
      p.className = 'note';
      const lead = doc.createElement('sup');
      lead.textContent = mark || '*';
      p.appendChild(lead);
      p.appendChild(doc.createTextNode(' '));
      while (body.firstChild) p.appendChild(body.firstChild);
      if (!collapse(p.textContent.replace(mark, ''))) { note.parentNode.replaceChild(sup, note); return; }
      let anchor = note.closest('table, figure') || note.closest('p, li, figcaption, h1, h2, h3, h4, h5, h6, blockquote');
      if (anchor && anchor.localName === 'li') {
        // keep list structure valid: append at the end of the item
        note.parentNode.replaceChild(sup, note);
        anchor.appendChild(p);
        return;
      }
      note.parentNode.replaceChild(sup, note);
      if (anchor && anchor.parentNode) anchor.parentNode.insertBefore(p, anchor.nextSibling);
    });
  }

  /** LaTeXML inline tabulars use span.ltx_tabular / ltx_tr / ltx_td → real tables. */
  function convertSpanTables(root) {
    const map = [
      ['span.ltx_tabular, div.ltx_tabular', 'table'],
      ['span.ltx_thead', 'thead'],
      ['span.ltx_tbody', 'tbody'],
      ['span.ltx_tfoot', 'tbody'],
      ['span.ltx_tr', 'tr'],
      ['span.ltx_td.ltx_th, span.ltx_th', 'th'],
      ['span.ltx_td', 'td'],
    ];
    map.forEach(([sel, tag]) => {
      Array.from(root.querySelectorAll(sel)).forEach((el) => { if (el.isConnected) rename(el, tag); });
    });
  }

  /** Map LaTeXML semantic classes onto our own small class vocabulary. */
  function mapClasses(root) {
    const doc = root.ownerDocument;
    const add = (sel, cls) => root.querySelectorAll(sel).forEach((el) => el.classList.add(cls));
    add('.ltx_tag', 'tag');
    add('.ltx_font_smallcaps', 'sc');
    add('.ltx_theorem', 'theorem');
    add('.ltx_proof', 'proof');
    add('.ltx_biblist', 'biblist');
    add('.ltx_bibitem', 'bibitem');
    add('.ltx_listing', 'listing');
    add('.ltx_listingline, .ltx_listing_line', 'line');
    // Lines that are not lstlisting code (algorithmic pseudocode): their whitespace text nodes
    // are LaTeXML source formatting, so they must not be kept verbatim.
    root.querySelectorAll('.line').forEach((l) => {
      if (!l.closest('.ltx_lstlisting') && !l.querySelector('[class*="ltx_lst_"]')) l.classList.add('alg');
    });
    add('.ltx_algorithm, figure.ltx_float_algorithm', 'algo');
    add('.ltx_flex_figure', 'flexfig');
    add('.ltx_figure_panel, .ltx_flex_cell', 'panel');
    add('figure.ltx_figure', 'fig');
    add('figure.ltx_table', 'tbl');
    add('table.ltx_tabular, table.ltx_tabular', 'tabular');
    add('.ltx_align_center', 'c');
    add('.ltx_align_left', 'l');
    add('.ltx_align_right', 'r');
    add('.ltx_border_t, .ltx_border_tt', 'rt');
    add('.ltx_border_b, .ltx_border_bb', 'rb');
    add('.ltx_acknowledgements', 'ack');
    add('a.ltx_ref', 'xref');
    root.querySelectorAll('ul.ltx_itemize, ol.ltx_enumerate, ul.ltx_enumerate, ol.ltx_itemize').forEach((l) => {
      if (l.querySelector(':scope > li > .ltx_tag_item')) l.classList.add('tagged');
    });
    // font spans → semantic inline tags
    Array.from(root.querySelectorAll('span.ltx_font_bold')).forEach((el) => { if (!el.closest('h1,h2,h3,h4,h5,h6')) rename(el, 'b'); });
    Array.from(root.querySelectorAll('span.ltx_font_italic, span.ltx_emph')).forEach((el) => rename(el, 'i'));
    Array.from(root.querySelectorAll('span.ltx_font_typewriter')).forEach((el) => { if (!el.closest('pre, code')) rename(el, 'code'); });
    // theorem/paragraph run-in titles (h5/h6) → bold lead paragraph
    Array.from(root.querySelectorAll('h6, .ltx_title_theorem, .ltx_title_proof, .ltx_title_acknowledgements')).forEach((h) => {
      if (!h.isConnected || /^h[1-4]$/.test(h.localName) && !hasClass(h, 'ltx_title_theorem') && !hasClass(h, 'ltx_title_proof')) return;
      const p = doc.createElement('p');
      p.className = 'runin';
      const s = doc.createElement('strong');
      while (h.firstChild) s.appendChild(h.firstChild);
      p.appendChild(s);
      h.parentNode.replaceChild(p, h);
    });
    // table captions: move before the table as a paragraph
    Array.from(root.querySelectorAll('table > caption')).forEach((cap) => {
      const table = cap.parentNode;
      const p = doc.createElement('p');
      while (cap.firstChild) p.appendChild(cap.firstChild);
      table.parentNode.insertBefore(p, table);
      cap.remove();
    });
  }

  function absolutizeLinks(root, base, pageURL) {
    root.querySelectorAll('img').forEach((img) => {
      const raw = img.getAttribute('src') || img.getAttribute('data-src') || '';
      let abs = null;
      if (/^data:/i.test(raw)) abs = raw;
      else if (raw) { try { abs = new URL(raw, base).href; } catch (_) { abs = null; } }
      if (abs) img.setAttribute('src', abs); else img.removeAttribute('src');
    });
    root.querySelectorAll('a[href]').forEach((a) => {
      const raw = (a.getAttribute('href') || '').trim();
      if (!raw || raw[0] === '#') return;
      let u;
      try { u = new URL(raw, base); } catch (_) { a.removeAttribute('href'); return; }
      if (u.hash && (samePage(u.href, pageURL) || samePage(u.href, base))) {
        a.setAttribute('href', u.hash);
        return;
      }
      a.setAttribute('href', u.href);
    });
  }

  const NOISE_SELECTORS = [
    'nav', 'footer', 'header', 'script', 'style', 'noscript', 'button', 'form', 'input', 'iframe',
    '.ltx_page_header', '.ltx_page_footer', '.ltx_page_navbar', '.ltx_page_logo', '.ltx_TOC',
    '.ltx_dates', '.ltx_classification', '.ltx_ERROR', '.ltx_pagination', '.ltx_rdf',
    '.package-alerts', '.ltx_role_affiliation', '.ltx_role_email', '.ltx_role_address',
    '.ltx_role_author', '.ltx_role_thanks', '.ltx_role_institutetext', '.ltx_role_orcid',
    '.ltx_role_pagestyle', '.ltx_role_newpage', '.ltx_role_footnotetext', '.ltx_role_affiliationtext',
    '.ltx_role_keywords_head', '#header', '#footer', '.arxiv-watermark',
    '.sr-only', '.html-header-message', '.html-header-logo',
    // lstlisting's "download this listing" link (a ⬇ glyph + data: URL)
    '.ltx_listing_data',
  ].join(', ');

  function fromArxivHTML(html, baseURL) {
    if (typeof html !== 'string') throw new Error('html must be a string');
    const src = new DOMParser().parseFromString(html, 'text/html');
    const base = effectiveBase(src, baseURL);
    const root = src.querySelector('article.ltx_document') || src.querySelector('.ltx_document') || src.body;
    if (!root) throw new Error('empty document');

    // --- header metadata (before any mutation) ---
    const titleEl = root.querySelector('.ltx_title_document') || src.querySelector('.ltx_title_document');
    let title = titleEl ? unicodeText(titleEl) : '';
    if (!title) {
      const meta = src.querySelector('meta[name="citation_title"]');
      title = meta ? collapse(meta.getAttribute('content')) : collapse(src.title || '');
    }

    let authors = [];
    root.querySelectorAll('.ltx_authors .ltx_personname, .ltx_personname').forEach((pn) => {
      const c = pn.cloneNode(true);
      c.querySelectorAll('.ltx_role_email, .ltx_role_affiliation, .ltx_role_address, .ltx_contact, .ltx_note, sup, a[href^="mailto:"]').forEach((n) => n.remove());
      splitAuthors(textWithBreaks(c)).forEach((a) => {
        if (!authors.some((x) => x.toLowerCase() === a.toLowerCase())) authors.push(a);
      });
    });
    if (!authors.length) {
      src.querySelectorAll('meta[name="citation_author"]').forEach((m) => {
        const a = cleanAuthorName(m.getAttribute('content'));
        if (a) authors.push(a);
      });
    }
    authors = authors.slice(0, 200);

    // --- structural conversion ---
    convertPictures(root);
    convertEquationTables(root);
    convertInlineMath(root);

    let abstract = '';
    const absEls = Array.from(root.querySelectorAll('.ltx_abstract')).filter((a) => !a.parentElement || !a.parentElement.closest('.ltx_abstract'));
    absEls.forEach((absEl, i) => {
      const c = absEl.cloneNode(true);
      c.querySelectorAll('.ltx_title, .ltx_title_abstract, h1, h2, h3, h4, h5, h6, .ltx_note').forEach((n) => n.remove());
      const paras = Array.from(c.querySelectorAll('p'));
      const text = paras.length ? paras.map((p) => P.blockText(p)).filter(Boolean).join('\n\n') : P.blockText(c);
      if (text && i === 0) abstract = text;
      // The abstract stays in the body as the first section (labelled "Abstract"), so the
      // reader shows it and blocks.json — Claude's view of the paper — includes it.
      prepareAbstract(absEl, root);
    });

    // drop the header block (rendered natively) and page chrome
    removeAll(root, '.ltx_title_document, .ltx_authors');
    convertFootnotes(root);
    removeAll(root, NOISE_SELECTORS);
    // any other LaTeXML role noise, except bibliography numbers and display roles
    root.querySelectorAll('[class*="ltx_role_"]').forEach((el) => {
      if (!el.isConnected) return;
      const roles = Array.from(el.classList).filter((c) => c.indexOf('ltx_role_') === 0);
      const keep = roles.every((r) => /^ltx_role_(refnum|display|text|footnote|number|bibtitle|year|author_list|journal|volume|pages)/.test(r));
      if (!keep && el.closest('.ltx_bibitem') === null) el.remove();
    });

    convertSpanTables(root);
    mapClasses(root);
    if (base) absolutizeLinks(root, base, String(baseURL || base));

    // LaTeXML heading levels: h2 section, h3 subsection, h4 subsubsection, h5 paragraph.
    // A stray h1 inside the body (e.g. part) becomes h2.
    root.querySelectorAll('h1').forEach((h) => rename(h, 'h2'));

    // --- sanitize into a fresh inert document ---
    const doc = P.inertDocument();
    const container = doc.createElement('div');
    container.appendChild(P.sanitizeChildren(root, doc, { keepIds: true, allowImages: true }));
    pruneEmpty(container);
    return finish(title, authors, abstract, container);
  }

  /** Removes elements that ended up empty after cleaning (no text, image, math or br). */
  function pruneEmpty(container) {
    const sel = 'p, div, span, li, figure, figcaption, blockquote, cite, em, strong, i, b, sub, sup';
    let changed = true;
    let guard = 0;
    // layout tables with nothing in them (LaTeXML spacer tabulars) only add blank space
    Array.from(container.querySelectorAll('table')).reverse().forEach((t) => {
      if (t.isConnected && !t.querySelector('img, span.m, br') && collapse(t.textContent) === '') t.remove();
    });
    while (changed && guard++ < 4) {
      changed = false;
      Array.from(container.querySelectorAll(sel)).reverse().forEach((el) => {
        if (el.classList.contains('m') || el.classList.contains('eq')) return;
        if (el.querySelector('img, span.m, br, table, td')) return;
        if (el.hasAttribute('id') && el.localName !== 'span') { if (collapse(el.textContent)) return; }
        if (collapse(el.textContent) === '') {
          // Whitespace-only inline elements are spacing: lstlisting writes every space and
          // indent run as <span class="ltx_lst_space"> </span>. Keep the whitespace itself
          // (verbatim inside code, one space elsewhere) so words don't run together.
          const raw = el.textContent;
          if (raw && /^(span|em|strong|i|b|cite|sub|sup)$/.test(el.localName)) {
            const verbatim = el.closest('.listing, .line, pre, code');
            el.parentNode.replaceChild(el.ownerDocument.createTextNode(verbatim ? raw : ' '), el);
            changed = true;
            return;
          }
          if (el.hasAttribute('id') && el.parentNode && !el.parentNode.hasAttribute('id')) {
            el.parentNode.setAttribute('id', el.getAttribute('id'));
          }
          el.remove();
          changed = true;
        }
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Markdown (PDF → Claude → Markdown)
  // ---------------------------------------------------------------------------

  const TAG_RE = /\\tag\*?\{([^{}]*)\}/;

  function displayToEq(container) {
    const doc = container.ownerDocument;
    // Paragraphs whose only content is one or more display math spans → div.eq each.
    Array.from(container.querySelectorAll('p')).forEach((p) => {
      const kids = Array.from(p.childNodes).filter((n) => !(n.nodeType === 3 && !n.data.trim()) && !(n.nodeType === 1 && n.localName === 'br'));
      if (!kids.length) return;
      const allDisplay = kids.every((n) => n.nodeType === 1 && n.localName === 'span' && n.classList.contains('m') && n.getAttribute('data-d') === '1');
      if (!allDisplay) return;
      const frag = doc.createDocumentFragment();
      kids.forEach((span) => frag.appendChild(makeEq(doc, span)));
      p.parentNode.replaceChild(frag, p);
    });
    // Remaining display math directly in a top-level paragraph stays inline-display; extract
    // \tag into the eq number where it is a standalone div.eq only.
  }

  function makeEq(doc, span) {
    let tex = span.getAttribute('data-tex') || '';
    let number = '';
    const m = TAG_RE.exec(tex);
    if (m) {
      number = '(' + m[1].trim() + ')';
      tex = tex.replace(TAG_RE, '').trim();
    }
    const div = doc.createElement('div');
    div.className = 'eq';
    div.appendChild(P.makeMathSpan(doc, tex, true));
    if (number) {
      const n = doc.createElement('span');
      n.className = 'eqn';
      n.textContent = number;
      div.appendChild(n);
    }
    return div;
  }

  /** `> **Figure n.** caption` blockquotes → figure > figcaption. */
  function figureQuotes(container) {
    const doc = container.ownerDocument;
    Array.from(container.querySelectorAll('blockquote')).forEach((bq) => {
      const first = bq.querySelector('p') || bq;
      const lead = first.querySelector('strong, b');
      const text = collapse(first.textContent);
      if (!lead || !/^(fig(ure)?\.?|table|tab\.|algorithm)\s*[A-Za-z]?\d+/i.test(text) || first.firstElementChild !== lead) return;
      if (collapse(first.textContent.slice(0, 1)) !== collapse(lead.textContent.slice(0, 1))) return;
      const fig = doc.createElement('figure');
      fig.className = /^tab/i.test(text) ? 'tbl' : 'fig';
      const cap = doc.createElement('figcaption');
      const ps = Array.from(bq.childNodes);
      ps.forEach((n, i) => {
        if (n.nodeType === 1 && n.localName === 'p') {
          if (i > 0 && cap.childNodes.length) cap.appendChild(doc.createElement('br'));
          while (n.firstChild) cap.appendChild(n.firstChild);
        } else if (n.nodeType === 1 || (n.nodeType === 3 && n.data.trim())) {
          cap.appendChild(n.cloneNode(true));
        }
      });
      fig.appendChild(cap);
      bq.parentNode.replaceChild(fig, bq);
    });
  }

  /** Wrap bare tables so they behave like LaTeXML ones in the reader. */
  function markTables(container) {
    container.querySelectorAll('table').forEach((t) => t.classList.add('tabular'));
  }

  function headingText(h) { return P.blockText(h); }

  function looksLikeAuthorLine(p) {
    const text = collapse(p.textContent);
    if (!text || text.length > 400) return null;
    if (p.querySelector('span.m')) return null;
    if (/[a-z]{3,}\s+[a-z]{3,}\s+[a-z]{3,}\s+[a-z]{3,}/.test(text)) return null; // prose
    const names = splitAuthors(textWithBreaks(p));
    if (!names.length) return null;
    const pieces = text.split(/,|;|\s+and\s+|&|\n/).map(collapse).filter(Boolean);
    return names.length >= Math.max(1, Math.ceil(pieces.length / 3)) ? names : null;
  }

  function fromMarkdown(md) {
    if (typeof md !== 'string') throw new Error('markdown must be a string');
    const doc = P.inertDocument();
    const container = doc.createElement('div');
    // Images in model output would be fetched from arbitrary hosts by the reader; the
    // conversion prompt never asks for them, so keep only their alt text.
    container.appendChild(P.markdownToFragment(md, doc, { allowImages: false, isolateDisplay: true }));

    // Title: the first h1 (removed). Any later h1 is demoted to a section heading.
    let title = '';
    const h1s = Array.from(container.querySelectorAll('h1'));
    if (h1s.length) {
      title = headingText(h1s[0]);
      const titleNode = h1s[0];
      // author line: paragraph(s) directly after the title and before any heading
      let authors = [];
      let n = titleNode.nextElementSibling;
      const consumed = [];
      while (n && n.localName === 'p' && consumed.length < 3) {
        const names = looksLikeAuthorLine(n);
        if (!names) break;
        names.forEach((a) => { if (!authors.some((x) => x.toLowerCase() === a.toLowerCase())) authors.push(a); });
        consumed.push(n);
        n = n.nextElementSibling;
      }
      consumed.forEach((x) => x.remove());
      titleNode.remove();
      h1s.slice(1).forEach((h) => rename(h, 'h2'));
      return finishMarkdown(title, authors, container);
    }
    return finishMarkdown(title, [], container);
  }

  function finishMarkdown(title, authors, container) {
    // h5/h6 were already renamed to h4 by the sanitizer.
    displayToEq(container);
    figureQuotes(container);
    markTables(container);

    // Abstract: content under a heading matching /abstract/i, up to the next heading, or a
    // "**Abstract.** text…" run-in paragraph. Like the arXiv path it stays in the body as the
    // first section (div.abstract > h2 "Abstract"), so the reader shows it and blocks.json has it.
    let abstract = '';
    const doc = container.ownerDocument;
    const box = doc.createElement('div');
    box.className = 'abstract';
    const label = doc.createElement('h2');
    label.textContent = 'Abstract';
    box.appendChild(label);
    const absHead = Array.from(container.querySelectorAll('h2, h3, h4')).find((h) => /^\s*(\d+[.)]?\s*)?abstract\b/i.test(headingText(h)));
    if (absHead) {
      const parts = [];
      const move = [];
      for (let n = absHead.nextElementSibling; n && !/^h[1-4]$/.test(n.localName); n = n.nextElementSibling) {
        const t = P.blockText(n);
        if (t) parts.push(t);
        move.push(n);
      }
      abstract = parts.join('\n\n');
      absHead.parentNode.replaceChild(box, absHead);
      move.forEach((n) => box.appendChild(n));
    } else {
      const p = Array.from(container.querySelectorAll('p')).slice(0, 6).find((x) => {
        const lead = x.firstElementChild;
        return lead && /^(strong|b|em|i)$/.test(lead.localName) && /^\s*abstract\s*[.:—–-]?\s*$/i.test(lead.textContent) && x.firstChild === lead;
      });
      if (p) {
        p.firstElementChild.remove();
        // drop the separator left after the run-in label
        const first = p.firstChild;
        if (first && first.nodeType === 3) first.data = first.data.replace(/^\s*[.:—–-]?\s*/, '');
        abstract = P.blockText(p);
        p.parentNode.replaceChild(box, p);
        box.appendChild(p);
      }
    }
    if (box.parentNode && box.parentNode.firstChild !== box) {
      // first in the body (a stray front-matter paragraph may precede it)
      const host = box.parentNode;
      host.insertBefore(box, host.firstChild);
    }
    return finish(title, authors, abstract, container);
  }

  // ---------------------------------------------------------------------------

  const Ingest = {
    fromArxivHTML: function (html, baseURL) {
      return JSON.stringify(fromArxivHTML(html, baseURL));
    },
    fromMarkdown: function (md) {
      return JSON.stringify(fromMarkdown(md));
    },
    // exposed for tests
    _tagBlocks: tagBlocks,
    _splitAuthors: splitAuthors,
  };

  global.Ingest = Ingest;

  function ready() {
    Ingest.ready = true;
    P.postToSwift('ingest', { type: 'ready' });
  }
  if (typeof document !== 'undefined' && document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', ready, { once: true });
  } else {
    ready();
  }
})(typeof window !== 'undefined' ? window : globalThis);
