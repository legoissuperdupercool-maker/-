// Tiny, safe markdown renderer for chat messages: escapes everything first, then
// adds code blocks, inline code, bold/italic, headings, lists and links.
(function (root) {
  function esc(s) {
    return s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
  }

  function inline(s) {
    const codes = [];
    s = s.replace(/`([^`\n]+)`/g, (_, c) => {
      codes.push(c);
      return `\u0000${codes.length - 1}\u0000`;
    });
    s = s
      .replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>')
      .replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<em>$2</em>')
      .replace(/\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)/g, '<a href="$2" target="_blank" rel="noreferrer">$1</a>')
      .replace(/(^|[\s(])(https?:\/\/[^\s<)]+)/g, '$1<a href="$2" target="_blank" rel="noreferrer">$2</a>');
    return s.replace(/\u0000(\d+)\u0000/g, (_, i) => `<code>${codes[+i]}</code>`);
  }

  function render(md) {
    const out = [];
    const parts = esc(md || '').split(/```/);
    parts.forEach((part, i) => {
      if (i % 2 === 1) {
        const nl = part.indexOf('\n');
        const lang = nl > 0 ? part.slice(0, nl).trim() : '';
        const body = nl >= 0 ? part.slice(nl + 1) : part;
        out.push(`<pre class="code"${lang ? ` data-lang="${lang}"` : ''}><button class="copy" type="button">Copy</button><code>${body.replace(/\n$/, '')}</code></pre>`);
        return;
      }
      let list = null;
      const flush = () => {
        if (list) out.push(`</${list}>`);
        list = null;
      };
      for (const raw of part.split('\n')) {
        const line = raw.trimEnd();
        let m;
        if ((m = line.match(/^\s*[-*•]\s+(.*)/))) {
          if (list !== 'ul') {
            flush();
            out.push('<ul>');
            list = 'ul';
          }
          out.push(`<li>${inline(m[1])}</li>`);
        } else if ((m = line.match(/^\s*\d+[.)]\s+(.*)/))) {
          if (list !== 'ol') {
            flush();
            out.push('<ol>');
            list = 'ol';
          }
          out.push(`<li>${inline(m[1])}</li>`);
        } else if ((m = line.match(/^(#{1,4})\s+(.*)/))) {
          flush();
          out.push(`<h${m[1].length + 2}>${inline(m[2])}</h${m[1].length + 2}>`);
        } else if (line.trim() === '') {
          flush();
        } else {
          flush();
          out.push(`<p>${inline(line)}</p>`);
        }
      }
      flush();
    });
    return out.join('');
  }

  const api = { render, esc };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.md = api;
})(this);
