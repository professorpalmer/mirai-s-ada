// Shared helpers of the result cards. Each card's HTML holds its numbers in one DATA object at the top and calls
// these helpers. No number lives in this file. bench/render_cards.ps1 renders every card with headless Edge.
var NS = 'http://www.w3.org/2000/svg';
var NM = 'not measured';
var REPO = 'github.com/professorpalmer/mirai-s-ada';
var COLOR = { serve: 'var(--serve)', ref: 'var(--ref)', opt: 'var(--opt)', serveSoft: 'var(--serve-soft)', refSoft: 'var(--ref-soft)', optSoft: 'var(--opt-soft)' };

function el(tag, attrs, text) {
  var e = document.createElementNS(NS, tag);
  for (var k in attrs) e.setAttribute(k, attrs[k]);
  if (text !== undefined) e.textContent = text;
  return e;
}
function svg(w, h) { return el('svg', { viewBox: '0 0 ' + w + ' ' + h, preserveAspectRatio: 'xMidYMid meet' }); }
function fmt(v, d) {
  if (v === null || v === undefined) return NM;
  return Number(v).toLocaleString('en-US', { minimumFractionDigits: d || 0, maximumFractionDigits: d || 0 });
}
function esc(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;'); }

// The card frame: eyebrow, title, optional sub line and legend, the body, and the small-print sources.
// legend: [[color, text]]. foot: array of strings, printed in small type at the bottom.
function card(o) {
  var leg = o.legend ? '<div class="legend">' + o.legend.map(function (i) {
    return '<span><i class="sw" style="background:' + i[0] + '"></i>' + esc(i[1]) + '</span>';
  }).join('') + '</div>' : '';
  document.getElementById('card').innerHTML =
    '<div class="top"><span class="eyebrow">' + esc(o.eyebrow) + '</span><b>' + REPO + '</b></div><h1>' + esc(o.title) + '</h1>' +
    (o.sub ? '<p class="sub">' + esc(o.sub) + '</p>' : '') + leg +
    '<div class="body" id="body"></div>' +
    '<div class="foot">' + (o.foot || []).map(esc).join('<br>') + '</div>';
  return document.getElementById('body');
}

// A panel inside the body, with a small heading. Returns the element to draw into.
function panel(body, title, flex) {
  var p = document.createElement('div');
  p.className = 'panel';
  p.style.flex = flex || '1';
  p.innerHTML = (title ? '<h2>' + esc(title) + '</h2>' : '');
  var inner = document.createElement('div');
  inner.style.flex = '1'; inner.style.minHeight = '0'; inner.style.display = 'flex';
  p.appendChild(inner);
  body.appendChild(p);
  return inner;
}

// A column table. cols: [{ key, name, sub, color, focus }]. rows: [{ label, note, <key>: cell }].
// cell = null (prints "not measured"), { v: 'text', unit: 'small text' } (a value), or { t: 'text' } (a plain note).
function colTable(target, cols, rows, o) {
  o = o || {};
  var h = '<div class="tt" style="grid-template-columns:' + (o.labelFr || '1.25fr') + ' ' + cols.map(function (c) { return c.fr || '1fr'; }).join(' ') + '"><div></div>';
  cols.forEach(function (c) {
    h += '<div class="hd" style="color:' + c.color + '">' + esc(c.name) + '<small>' + esc(c.sub || '') + '</small></div>';
  });
  rows.forEach(function (r) {
    h += '<div class="lb">' + esc(r.label) + (r.note ? '<small>' + esc(r.note) + '</small>' : '') + '</div>';
    cols.forEach(function (c) {
      var x = r[c.key], cls = 'v' + (c.focus ? ' focus' : '');
      if (x === null || x === undefined) h += '<div class="' + cls + ' nm">' + NM + '</div>';
      else if (x.t !== undefined) h += '<div class="' + cls + ' txt">' + esc(x.t) + '</div>';
      else h += '<div class="' + cls + '"><span>' + esc(x.v) + (x.unit ? '<small>' + esc(x.unit) + '</small>' : '') + '</span></div>';
    });
  });
  target.innerHTML = h + '</div>';
  var tt = target.firstChild;
  tt.style.gridTemplateRows = 'auto repeat(' + rows.length + ', minmax(0, 1fr))';
}

// Grouped horizontal bars. series: [{ key, name, color }]. rows: [{ label, note, <key>: { v, text } or null }].
// o: { max, W, H, labelW, R, barH }. A null cell draws a stub and "not measured".
function hbars(target, rows, series, o) {
  var W = o.W || 1104, H = o.H || 360, LW = o.labelW !== undefined ? o.labelW : 300, R = o.R || 220, gap = 6;
  var rowH = H / rows.length;
  var barH = o.barH || Math.min(26, (rowH - 14 - gap * (series.length - 1)) / series.length);
  var s = svg(W, H);
  var x = function (v) { return LW + v / o.max * (W - LW - R); };
  rows.forEach(function (r, i) {
    var y0 = i * rowH, mid = y0 + rowH / 2;
    if (i) s.appendChild(el('line', { x1: 0, x2: W, y1: y0, y2: y0, stroke: 'var(--line)' }));
    if (o.below) {   // label and note above the bar, the bar in the lower part of the row
      s.appendChild(el('text', { class: 'cat', x: 0, y: y0 + 26 }, r.label));
      if (r.note) s.appendChild(el('text', { x: 0, y: y0 + 48, style: 'font-size:15px' }, r.note));
      mid = y0 + 56 + barH / 2 + (rowH - 56 - barH) / 2 - 6;
    } else {
      s.appendChild(el('text', { class: 'cat', x: 0, y: mid + (r.note ? -5 : 7) }, r.label));
      if (r.note) s.appendChild(el('text', { x: 0, y: mid + 18, style: 'font-size:15px' }, r.note));
    }
    var shown = series.filter(function (se) { return r[se.key] !== undefined; });
    var total = shown.length * barH + (shown.length - 1) * gap;
    shown.forEach(function (se, j) {
      var c = r[se.key], yy = mid - total / 2 + j * (barH + gap);
      if (c === null) {
        s.appendChild(el('rect', { x: LW, y: yy, width: 6, height: barH, rx: 2, fill: 'var(--nm)', opacity: 0.5 }));
        s.appendChild(el('text', { class: 'nm', x: LW + 16, y: yy + barH / 2 + 6 }, se.name + ': ' + NM));
        return;
      }
      var w = Math.max(x(c.v) - LW, 4);
      s.appendChild(el('rect', { x: LW, y: yy, width: w, height: barH, rx: 3, fill: se.color }));
      s.appendChild(el('text', { class: 'val', x: LW + w + 10, y: yy + barH / 2 + 7, style: 'font-size:' + (o.valSize || 20) + 'px;fill:' + (se.textColor || se.color) }, c.text));
    });
  });
  target.appendChild(s);
}
