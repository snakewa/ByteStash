// Markdown preview for the Mac client, matching the web app's MarkdownRenderer:
// GitHub-flavoured Markdown with single line breaks kept (remark-gfm + remark-breaks),
// GitHub alerts (> [!NOTE] …), raw HTML shown as text, and Mermaid diagrams with
// zoom / pan / copy / SVG / PNG / full-screen controls (MermaidViewer.tsx).
//
// Swift calls ByteStash.render(markdown, {dark}) and receives messages on
// webkit.messageHandlers.bytestash: {type: "copy", text}, {type: "save", name, text | base64},
// {type: "snapshot", name, rect} and {type: "error", message}.
(function () {
  'use strict';

  const ICONS = {
    zoomIn: '<circle cx="11" cy="11" r="8"/><line x1="21" x2="16.65" y1="21" y2="16.65"/><line x1="11" x2="11" y1="8" y2="14"/><line x1="8" x2="14" y1="11" y2="11"/>',
    zoomOut: '<circle cx="11" cy="11" r="8"/><line x1="21" x2="16.65" y1="21" y2="16.65"/><line x1="8" x2="14" y1="11" y2="11"/>',
    reset: '<path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M8 16H3v5"/>',
    copy: '<rect width="14" height="14" x="8" y="8" rx="2" ry="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>',
    check: '<path d="M20 6 9 17l-5-5"/>',
    download: '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" x2="12" y1="15" y2="3"/>',
    image: '<rect width="18" height="18" x="3" y="3" rx="2" ry="2"/><circle cx="9" cy="9" r="2"/><path d="m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21"/>',
    maximize: '<path d="M8 3H5a2 2 0 0 0-2 2v3"/><path d="M21 8V5a2 2 0 0 0-2-2h-3"/><path d="M3 16v3a2 2 0 0 0 2 2h3"/><path d="M16 21h3a2 2 0 0 0 2-2v-3"/>',
    minimize: '<path d="M8 3v3a2 2 0 0 1-2 2H3"/><path d="M21 8h-3a2 2 0 0 1-2-2V3"/><path d="M3 16h3a2 2 0 0 1 2 2v3"/><path d="M16 21v-3a2 2 0 0 1 2-2h3"/>',
    alert: '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4"/><path d="M12 17h.01"/>',
    box: '<path d="M21 8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16Z"/><path d="m3.3 7 8.7 5 8.7-5"/><path d="M12 22V12"/>',
    info: '<circle cx="12" cy="12" r="10"/><path d="M12 16v-4"/><path d="M12 8h.01"/>',
    lightbulb: '<path d="M15 14c.2-1 .7-1.7 1.5-2.5 1-.9 1.5-2.2 1.5-3.5A6 6 0 0 0 6 8c0 1 .2 2.2 1.5 3.5.7.7 1.3 1.5 1.5 2.5"/><path d="M9 18h6"/><path d="M10 22h4"/>',
    important: '<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/><path d="M12 7v2"/><path d="M12 13h.01"/>',
    octagon: '<path d="M12 16h.01"/><path d="M12 8v4"/><path d="M15.312 2a2 2 0 0 1 1.414.586l4.688 4.688A2 2 0 0 1 22 8.688v6.624a2 2 0 0 1-.586 1.414l-4.688 4.688a2 2 0 0 1-1.414.586H8.688a2 2 0 0 1-1.414-.586l-4.688-4.688A2 2 0 0 1 2 15.312V8.688a2 2 0 0 1 .586-1.414l4.688-4.688A2 2 0 0 1 8.688 2z"/>'
  };

  const ALERTS = {
    NOTE: { title: 'Note', icon: 'info' },
    TIP: { title: 'Tip', icon: 'lightbulb' },
    IMPORTANT: { title: 'Important', icon: 'important' },
    WARNING: { title: 'Warning', icon: 'alert' },
    CAUTION: { title: 'Caution', icon: 'octagon' }
  };
  const ALERT_RE = /^\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\][ \t]*/i;

  function icon(name) {
    return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" ' +
      'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + ICONS[name] + '</svg>';
  }

  function native(message) {
    const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bytestash;
    if (handler) handler.postMessage(message);
    else (window.__nativeMessages = window.__nativeMessages || []).push(message); // browser testing
  }

  function escapeHTML(value) {
    return String(value).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }

  // http(s), mailto, in-page anchors and relative paths; images may also be data:image/*.
  function safeURL(href, image) {
    if (!href) return null;
    const url = String(href).trim();
    if (/^(https?:|mailto:|#)/i.test(url)) return url;
    if (image && /^data:image\//i.test(url)) return url;
    if (!/^[a-z][a-z0-9+.-]*:/i.test(url)) return url;
    return null;
  }

  let slugCounts = {};
  function slug(text) {
    let base = String(text).toLowerCase().trim()
      .replace(/<[^>]*>/g, '')
      .replace(/[^\p{L}\p{N}\s_-]/gu, '')
      .replace(/\s+/g, '-') || 'section';
    const count = slugCounts[base] || 0;
    slugCounts[base] = count + 1;
    return count ? base + '-' + count : base;
  }

  marked.use({
    gfm: true,
    breaks: true,
    renderer: {
      // react-markdown doesn't render raw HTML either: show it as text.
      html(token) { return escapeHTML(token.text); },
      code(token) {
        const lang = (token.lang || '').trim().split(/\s+/)[0].toLowerCase();
        if (lang === 'mermaid') {
          return '<div class="mermaid-block" data-source="' + escapeHTML(token.text) + '"></div>';
        }
        let body = null;
        if (lang && window.hljs && hljs.getLanguage(lang)) {
          try { body = hljs.highlight(token.text, { language: lang, ignoreIllegals: true }).value; } catch (e) { body = null; }
        }
        if (body === null) body = escapeHTML(token.text);
        return '<pre><code class="hljs' + (lang ? ' language-' + escapeHTML(lang) : '') + '">' + body + '</code></pre>';
      },
      link(token) {
        const text = this.parser.parseInline(token.tokens);
        const url = safeURL(token.href, false);
        if (!url) return text;
        return '<a href="' + escapeHTML(url) + '"' + (token.title ? ' title="' + escapeHTML(token.title) + '"' : '') + '>' + text + '</a>';
      },
      image(token) {
        const url = safeURL(token.href, true);
        if (!url) return escapeHTML(token.text);
        return '<img src="' + escapeHTML(url) + '" alt="' + escapeHTML(token.text) + '"' +
          (token.title ? ' title="' + escapeHTML(token.title) + '"' : '') + '>';
      },
      heading(token) {
        const inner = this.parser.parseInline(token.tokens);
        return '<h' + token.depth + ' id="' + escapeHTML(slug(token.text)) + '">' + inner + '</h' + token.depth + '>\n';
      }
    }
  });

  // MARK: Post-processing

  function stripAlertMarker(paragraph) {
    const walker = document.createTreeWalker(paragraph, NodeFilter.SHOW_TEXT);
    let node;
    while ((node = walker.nextNode())) {
      if (!node.nodeValue.trim()) continue;
      node.nodeValue = node.nodeValue.replace(ALERT_RE, '');
      break;
    }
    // Drop the line break that followed "[!NOTE]".
    while (paragraph.firstChild &&
      ((paragraph.firstChild.nodeType === 3 && !paragraph.firstChild.nodeValue.trim()) ||
        paragraph.firstChild.nodeName === 'BR')) {
      paragraph.removeChild(paragraph.firstChild);
    }
  }

  function makeAlert(type, children) {
    const config = ALERTS[type];
    const box = document.createElement('div');
    box.className = 'admonition ' + type.toLowerCase();
    box.innerHTML = '<div class="admonition-title">' + icon(config.icon) + '<span>' + config.title + '</span></div>';
    const body = document.createElement('div');
    body.className = 'admonition-body';
    children.forEach((child) => body.appendChild(child));
    box.appendChild(body);
    return box;
  }

  function applyAlerts(root) {
    root.querySelectorAll('blockquote').forEach((quote) => {
      const first = quote.firstElementChild;
      if (!first || first.tagName !== 'P') return;
      const match = first.textContent.match(ALERT_RE);
      if (!match) return;
      stripAlertMarker(first);
      if (!first.childNodes.length) first.remove();
      quote.replaceWith(makeAlert(match[1].toUpperCase(), Array.from(quote.childNodes)));
    });
    // The web renderer also turns a plain paragraph starting with [!NOTE] into an alert.
    root.querySelectorAll('p').forEach((paragraph) => {
      if (paragraph.closest('.admonition')) return;
      const match = paragraph.textContent.match(ALERT_RE);
      if (!match) return;
      stripAlertMarker(paragraph);
      const alert = makeAlert(match[1].toUpperCase(), []);
      paragraph.replaceWith(alert);
      if (paragraph.childNodes.length) alert.querySelector('.admonition-body').appendChild(paragraph);
    });
  }

  function wrapTables(root) {
    root.querySelectorAll('table').forEach((table) => {
      const wrap = document.createElement('div');
      wrap.className = 'table-wrap';
      table.replaceWith(wrap);
      wrap.appendChild(table);
    });
  }

  function markTaskItems(root) {
    root.querySelectorAll('li > input[type="checkbox"]:first-child, li > p:first-child > input[type="checkbox"]:first-child')
      .forEach((box) => box.closest('li').classList.add('task'));
  }

  function flash(button, iconName) {
    button.innerHTML = icon('check');
    button.classList.add('done');
    setTimeout(() => { button.innerHTML = icon(iconName); button.classList.remove('done'); }, 2000);
  }

  function button(iconName, title, action) {
    const el = document.createElement('button');
    el.type = 'button';
    el.className = 'icon-btn';
    el.title = title;
    el.innerHTML = icon(iconName);
    el.addEventListener('click', (event) => { event.stopPropagation(); action(el); });
    return el;
  }

  function addCopyButtons(root) {
    root.querySelectorAll('pre').forEach((pre) => {
      const code = pre.querySelector('code');
      const copy = button('copy', 'Copy code', (el) => { native({ type: 'copy', text: code ? code.textContent : pre.textContent }); flash(el, 'copy'); });
      copy.classList.add('copy-code');
      pre.appendChild(copy);
    });
  }

  // MARK: Mermaid

  let mermaidConfigKey = null;
  let mermaidSeq = 0;

  function initMermaid(dark, htmlLabels) {
    const theme = dark ? 'dark' : 'default';
    const key = theme + '|' + htmlLabels;
    if (mermaidConfigKey === key) return;
    mermaid.initialize({ startOnLoad: false, theme, securityLevel: 'strict', htmlLabels, flowchart: { htmlLabels } });
    mermaidConfigKey = key;
  }

  async function mermaidSVG(code, dark, htmlLabels) {
    initMermaid(dark, htmlLabels);
    const id = 'mermaid-' + (++mermaidSeq);
    try {
      return (await mermaid.render(id, code)).svg;
    } finally {
      // A failed render leaves its scratch element in <body>.
      ['d' + id, id].forEach((stray) => {
        const el = document.getElementById(stray);
        if (el && !el.closest('#content')) el.remove();
      });
    }
  }

  function svgSize(svg) {
    const viewBox = (svg.getAttribute('viewBox') || '').split(/[\s,]+/).map(Number);
    let width = viewBox.length === 4 ? viewBox[2] : 0;
    let height = viewBox.length === 4 ? viewBox[3] : 0;
    if (!width || !height) {
      const box = svg.getBBox ? svg.getBBox() : { width: 0, height: 0 };
      width = width || box.width || 800;
      height = height || box.height || 600;
    }
    return { width, height };
  }

  function timestamp() { return Date.now(); }

  class Diagram {
    constructor(block, code) {
      this.block = block;
      this.code = code;
      this.scale = 1;
      this.x = 0;
      this.y = 0;
      this.touched = false;
      this.fullscreen = false;
      this.build();
    }

    build() {
      const block = this.block;
      block.innerHTML = '';
      const bar = document.createElement('div');
      bar.className = 'mermaid-bar';
      bar.innerHTML = '<span class="mermaid-title">' + icon('box') + 'Mermaid Diagram</span>';
      const tools = document.createElement('div');
      tools.className = 'mermaid-tools';
      const sep = () => { const s = document.createElement('div'); s.className = 'mermaid-sep'; return s; };
      tools.append(
        button('zoomIn', 'Zoom in', () => this.zoomBy(1.25)),
        button('zoomOut', 'Zoom out', () => this.zoomBy(0.8)),
        button('reset', 'Reset view', () => this.fit()),
        sep(),
        button('copy', 'Copy Mermaid code', (el) => { native({ type: 'copy', text: this.code }); flash(el, 'copy'); }),
        button('download', 'Download SVG', () => this.downloadSVG()),
        button('image', 'Download PNG', () => this.downloadPNG()),
        sep()
      );
      this.fullscreenButton = button('maximize', 'Full screen', () => this.toggleFullscreen());
      tools.append(this.fullscreenButton);
      bar.appendChild(tools);

      this.viewport = document.createElement('div');
      this.viewport.className = 'mermaid-viewport';
      this.stage = document.createElement('div');
      this.stage.className = 'mermaid-stage';
      this.viewport.innerHTML = '<div class="mermaid-loading">Rendering diagram…</div>';
      block.append(bar, this.viewport);
      this.bindGestures();
    }

    show(svgText) {
      this.stage.innerHTML = svgText;
      this.svg = this.stage.querySelector('svg');
      if (!this.svg) throw new Error('Mermaid produced no SVG');
      const size = svgSize(this.svg);
      this.width = size.width;
      this.height = size.height;
      this.svg.removeAttribute('style');
      this.svg.setAttribute('width', size.width);
      this.svg.setAttribute('height', size.height);
      this.viewport.innerHTML = '';
      this.viewport.appendChild(this.stage);
      this.fit();
    }

    fit() {
      if (!this.svg) return;
      this.touched = false;
      const padding = 16;
      const available = Math.max(this.viewport.clientWidth - padding * 2, 50);
      if (this.fullscreen) {
        const height = Math.max(this.viewport.clientHeight - padding * 2, 50);
        this.scale = Math.min(available / this.width, height / this.height, 2);
        this.x = (this.viewport.clientWidth - this.width * this.scale) / 2;
        this.y = (this.viewport.clientHeight - this.height * this.scale) / 2;
      } else {
        // Like the web view: fit the width, at most 600px tall, never enlarged.
        this.scale = Math.min(available / this.width, 600 / this.height, 1);
        const shown = this.height * this.scale;
        const height = Math.max(250, shown + padding * 2);
        this.viewport.style.height = height + 'px';
        this.x = (this.viewport.clientWidth - this.width * this.scale) / 2;
        this.y = (height - shown) / 2;
      }
      this.apply();
    }

    apply() {
      this.stage.style.transform = 'translate(' + this.x + 'px,' + this.y + 'px) scale(' + this.scale + ')';
    }

    zoomAt(factor, cx, cy) {
      const next = Math.min(8, Math.max(0.1, this.scale * factor));
      const ratio = next / this.scale;
      this.x = cx - (cx - this.x) * ratio;
      this.y = cy - (cy - this.y) * ratio;
      this.scale = next;
      this.touched = true;
      this.apply();
    }

    zoomBy(factor) {
      this.zoomAt(factor, this.viewport.clientWidth / 2, this.viewport.clientHeight / 2);
    }

    bindGestures() {
      const vp = this.viewport;
      let drag = null;
      vp.addEventListener('pointerdown', (e) => {
        if (e.button !== 0 || !this.svg) return;
        drag = { id: e.pointerId, x: e.clientX, y: e.clientY, ox: this.x, oy: this.y };
        vp.setPointerCapture(e.pointerId);
        vp.classList.add('dragging');
      });
      vp.addEventListener('pointermove', (e) => {
        if (!drag || drag.id !== e.pointerId) return;
        this.x = drag.ox + e.clientX - drag.x;
        this.y = drag.oy + e.clientY - drag.y;
        this.touched = true;
        this.apply();
      });
      const end = (e) => {
        if (!drag || drag.id !== e.pointerId) return;
        drag = null;
        vp.classList.remove('dragging');
      };
      vp.addEventListener('pointerup', end);
      vp.addEventListener('pointercancel', end);
      vp.addEventListener('dblclick', (e) => {
        const r = vp.getBoundingClientRect();
        this.zoomAt(e.altKey ? 0.5 : 2, e.clientX - r.left, e.clientY - r.top);
      });

      // ⌘/Ctrl-scroll or pinch zooms; in full screen a plain scroll pans. Otherwise the page scrolls.
      vp.addEventListener('wheel', (e) => {
        if (!this.svg) return;
        const r = vp.getBoundingClientRect();
        if (e.ctrlKey || e.metaKey) {
          e.preventDefault();
          this.zoomAt(Math.exp(-e.deltaY * 0.01), e.clientX - r.left, e.clientY - r.top);
        } else if (this.fullscreen) {
          e.preventDefault();
          this.x -= e.deltaX;
          this.y -= e.deltaY;
          this.touched = true;
          this.apply();
        }
      }, { passive: false });

      // Safari reports trackpad pinches as gesture events.
      let gestureScale = 1;
      vp.addEventListener('gesturestart', (e) => { e.preventDefault(); gestureScale = 1; });
      vp.addEventListener('gesturechange', (e) => {
        e.preventDefault();
        const r = vp.getBoundingClientRect();
        this.zoomAt(e.scale / gestureScale, e.clientX - r.left, e.clientY - r.top);
        gestureScale = e.scale;
      });
      vp.addEventListener('gestureend', (e) => e.preventDefault());
    }

    toggleFullscreen(force) {
      const next = force === undefined ? !this.fullscreen : force;
      if (next === this.fullscreen) return;
      if (next && activeFullscreen && activeFullscreen !== this) activeFullscreen.toggleFullscreen(false);
      this.fullscreen = next;
      this.block.classList.toggle('fullscreen', next);
      document.body.classList.toggle('has-fullscreen', next);
      if (next) this.viewport.style.height = '';
      this.fullscreenButton.innerHTML = icon(next ? 'minimize' : 'maximize');
      this.fullscreenButton.title = next ? 'Exit full screen' : 'Full screen';
      activeFullscreen = next ? this : null;
      requestAnimationFrame(() => this.fit());
    }

    serializedSVG() {
      const clone = this.svg.cloneNode(true);
      clone.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
      return new XMLSerializer().serializeToString(clone);
    }

    downloadSVG() {
      if (!this.svg) return;
      native({ type: 'save', name: 'diagram-' + timestamp() + '.svg', text: this.serializedSVG() });
    }

    async downloadPNG() {
      if (!this.svg) return;
      const name = 'diagram-' + timestamp() + '.png';
      try {
        // HTML labels (foreignObject) taint the canvas in WebKit, so draw an SVG-text version.
        const svgText = await mermaidSVG(this.code, currentDark, false);
        initMermaid(currentDark, true);
        const base64 = await rasterize(svgText, currentDark);
        native({ type: 'save', name, base64 });
      } catch (err) {
        initMermaid(currentDark, true);
        // Fall back to a native snapshot of what's on screen.
        const r = this.viewport.getBoundingClientRect();
        native({ type: 'snapshot', name, rect: { x: r.left, y: r.top, width: r.width, height: r.height } });
      }
    }
  }

  function rasterize(svgText, dark) {
    return new Promise((resolve, reject) => {
      const doc = new DOMParser().parseFromString(svgText, 'image/svg+xml');
      const svg = doc.querySelector('svg');
      if (!svg || doc.querySelector('parsererror')) return reject(new Error('Bad SVG'));
      const holder = document.createElement('div');
      holder.style.cssText = 'position:absolute;left:-99999px;top:0;visibility:hidden';
      holder.appendChild(document.importNode(svg, true));
      document.body.appendChild(holder);
      const size = svgSize(holder.firstChild);
      holder.remove();

      const scale = 2;
      svg.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
      svg.removeAttribute('style');
      svg.setAttribute('width', size.width * scale);
      svg.setAttribute('height', size.height * scale);
      const data = new XMLSerializer().serializeToString(svg);
      const img = new Image();
      img.onload = () => {
        try {
          const canvas = document.createElement('canvas');
          canvas.width = size.width * scale;
          canvas.height = size.height * scale;
          const ctx = canvas.getContext('2d');
          ctx.fillStyle = dark ? '#1E1E1E' : '#ffffff';
          ctx.fillRect(0, 0, canvas.width, canvas.height);
          ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
          resolve(canvas.toDataURL('image/png').split(',')[1]);
        } catch (err) {
          reject(err);
        }
      };
      img.onerror = () => reject(new Error('Could not load SVG'));
      img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(data);
    });
  }

  function showMermaidError(block, message) {
    const box = document.createElement('div');
    box.className = 'mermaid-error';
    box.innerHTML = icon('alert') + '<div class="mermaid-error-text"><strong>Failed to render diagram</strong></div>';
    box.querySelector('.mermaid-error-text').appendChild(document.createTextNode(message || 'Error rendering diagram'));
    block.replaceWith(box);
  }

  // MARK: Rendering

  let generation = 0;
  let currentDark = false;
  let currentMarkdown = null;
  let diagrams = [];
  let activeFullscreen = null;

  function setTheme(dark) {
    currentDark = !!dark;
    document.documentElement.classList.toggle('dark', currentDark);
    document.getElementById('hljs-light').disabled = currentDark;
    document.getElementById('hljs-dark').disabled = !currentDark;
  }

  async function renderDiagrams(gen) {
    for (const diagram of diagrams) {
      if (gen !== generation) return;
      try {
        const svg = await mermaidSVG(diagram.code, currentDark, true);
        if (gen !== generation) return;
        diagram.show(svg);
      } catch (err) {
        if (gen !== generation) return;
        showMermaidError(diagram.block, err && err.message ? err.message : String(err));
      }
    }
  }

  function render(markdown, options) {
    const dark = !!(options && options.dark);
    if (markdown === currentMarkdown && dark === currentDark && document.getElementById('content').childNodes.length) return;
    const gen = ++generation;
    const scrollY = window.scrollY;
    activeFullscreen = null;
    document.body.classList.remove('has-fullscreen');
    setTheme(dark);
    currentMarkdown = markdown;

    slugCounts = {};
    const content = document.getElementById('content');
    content.innerHTML = marked.parse(markdown || '');
    applyAlerts(content);
    markTaskItems(content);
    wrapTables(content);
    addCopyButtons(content);
    diagrams = Array.from(content.querySelectorAll('.mermaid-block')).map((block) => new Diagram(block, block.dataset.source || ''));
    window.scrollTo(0, scrollY);
    return renderDiagrams(gen);
  }

  window.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && activeFullscreen) activeFullscreen.toggleFullscreen(false);
  });

  let resizeTimer = null;
  window.addEventListener('resize', () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => diagrams.forEach((d) => { if (d.svg && (!d.touched || d.fullscreen)) d.fit(); }), 100);
  });

  window.ByteStash = {
    render,
    // Used by the native "Export as image" before/after it captures the page.
    prepareExport(on) {
      if (on && activeFullscreen) activeFullscreen.toggleFullscreen(false);
      document.body.classList.toggle('exporting', !!on);
      return { width: document.documentElement.scrollWidth, height: document.documentElement.scrollHeight };
    }
  };
})();
