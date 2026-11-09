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

  /** TeX source of a MathML element (LaTeXML puts it in alttext). */
  function mathTeX(math) {
    let tex = math.getAttribute('alttext');
    if (!tex) {
      const ann = math.querySelector('annotation[encoding="application/x-tex"], annotation[encoding="application/x-latex"]');
      if (ann) tex = ann.textContent;
    }
    if (!tex) tex = math.textContent;
    return String(tex || '').trim();
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
    c.querySelectorAll('.ltx_note, .ltx_role_footnote, sup.ltx_note_mark, .ltx_tag').forEach((n) => n.remove());
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

  function finish(title, authors, abstract, container) {
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
      // arxiv.org/html/<id> serves assets relative to "<id>/": unless the last segment is
      // clearly a file (foo.html), treat it as a directory. arXiv ids contain dots.
      const last = u.pathname.split('/').pop();
      if (last && !/\.(x?html?|php|aspx?)$/i.test(last) && !u.pathname.endsWith('/')) u.pathname += '/';
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

  /** Converts LaTeXML equation tables into div.eq rows (one per numbered/leaf row). */
  function convertEquationTables(root) {
    const doc = root.ownerDocument;
    const tables = Array.from(root.querySelectorAll('table.ltx_equation, table.ltx_equationgroup, table.ltx_eqn_table'));
    tables.forEach((table) => {
      if (!table.isConnected || !root.contains(table)) return;
      const rows = Array.from(table.querySelectorAll('tr')).filter((tr) => !tr.querySelector('tr'));
      const out = [];
      rows.forEach((tr) => {
        const tagEl = tr.querySelector('.ltx_tag_equation, .ltx_eqn_eqno .ltx_tag');
        const number = tagEl ? collapse(tagEl.textContent) : '';
        const pieces = [];
        (function walk(n) {
          for (let c = n.firstChild; c; c = c.nextSibling) {
            if (c.nodeType === 3) {
              const t = collapse(c.data);
              if (t) pieces.push('\\text{ ' + texEscapeText(t) + ' }');
            } else if (c.nodeType === 1) {
              if (c.localName === 'math') { pieces.push(mathTeX(c)); continue; }
              if (hasClass(c, 'ltx_eqn_eqno') || hasClass(c, 'ltx_tag_equation') || hasClass(c, 'ltx_tag')) continue;
              if (hasClass(c, 'ltx_note')) continue;
              walk(c);
            }
          }
        })(tr);
        const tex = pieces.filter(Boolean).join(' ').trim();
        const body = tr.parentNode;
        const rowId = tr.getAttribute('id') ||
          (body && body.localName === 'tbody' && body.firstElementChild === tr ? body.getAttribute('id') || '' : '');
        if (!tex) {
          if (number && out.length && !out[out.length - 1].number) out[out.length - 1].number = number;
          return;
        }
        out.push({ tex: tex, number: number, id: rowId });
      });
      const frag = doc.createDocumentFragment();
      out.forEach((eq, i) => {
        const div = doc.createElement('div');
        div.className = 'eq';
        const id = eq.id || (i === 0 ? table.getAttribute('id') : '');
        if (id) div.setAttribute('id', id);
        div.appendChild(P.makeMathSpan(doc, eq.tex, true));
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
      // a div.eq may not live inside <p>; hoist out of a paragraph if needed
      const p = table.closest('p');
      if (p && root.contains(p)) {
        p.parentNode.insertBefore(frag, p.nextSibling);
        table.remove();
      } else {
        table.parentNode.replaceChild(frag, table);
      }
    });
  }

  function convertInlineMath(root) {
    const doc = root.ownerDocument;
    Array.from(root.querySelectorAll('math')).forEach((m) => {
      if (!m.isConnected || !m.parentNode) return;
      const tex = mathTeX(m);
      const display = (m.getAttribute('display') || '').toLowerCase() === 'block';
      const span = P.makeMathSpan(doc, tex, display);
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
    convertEquationTables(root);
    convertInlineMath(root);

    let abstract = '';
    const absEl = root.querySelector('.ltx_abstract');
    if (absEl) {
      const c = absEl.cloneNode(true);
      c.querySelectorAll('.ltx_title, .ltx_title_abstract, h1, h2, h3, h4, h5, h6, .ltx_note').forEach((n) => n.remove());
      const paras = Array.from(c.querySelectorAll('p'));
      abstract = paras.length ? paras.map((p) => P.blockText(p)).filter(Boolean).join('\n\n') : P.blockText(c);
    }

    // drop the header block (rendered natively) and page chrome
    removeAll(root, '.ltx_title_document, .ltx_authors, .ltx_abstract');
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
    while (changed && guard++ < 4) {
      changed = false;
      Array.from(container.querySelectorAll(sel)).reverse().forEach((el) => {
        if (el.classList.contains('m') || el.classList.contains('eq')) return;
        if (el.querySelector('img, span.m, br, table, td')) return;
        if (el.hasAttribute('id') && el.localName !== 'span') { if (collapse(el.textContent)) return; }
        if (collapse(el.textContent) === '') {
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

    // Abstract: content under a heading matching /abstract/i, up to the next heading.
    // It is removed from the body (rendered natively), mirroring the arXiv path.
    let abstract = '';
    const absHead = Array.from(container.querySelectorAll('h2, h3, h4')).find((h) => /^\s*(\d+[.)]?\s*)?abstract\b/i.test(headingText(h)));
    if (absHead) {
      const parts = [];
      const remove = [absHead];
      for (let n = absHead.nextElementSibling; n && !/^h[1-4]$/.test(n.localName); n = n.nextElementSibling) {
        const t = P.blockText(n);
        if (t) parts.push(t);
        remove.push(n);
      }
      abstract = parts.join('\n\n');
      remove.forEach((n) => n.remove());
    } else {
      // "**Abstract.** text…" run-in paragraph
      const p = Array.from(container.querySelectorAll('p')).slice(0, 6).find((x) => {
        const lead = x.firstElementChild;
        return lead && /^(strong|b|em|i)$/.test(lead.localName) && /^\s*abstract\s*[.:—–-]?\s*$/i.test(lead.textContent) && x.firstChild === lead;
      });
      if (p) {
        p.firstElementChild.remove();
        abstract = P.blockText(p).replace(/^[.:—–-]\s*/, '');
        p.remove();
      }
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
