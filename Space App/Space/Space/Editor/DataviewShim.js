// Space: enough of Obsidian and the Dataview plugin for ```dataviewjs blocks to run in a web view.
// Space fills window.__space (the vault's pages, files and this note) before this script runs, and
// answers window.webkit.messageHandlers.space for everything that touches files.
(() => {
"use strict";
const S = window.__space;
const native = (op, args = {}) => window.webkit.messageHandlers.space.postMessage(Object.assign({ op }, args));

// ── Obsidian's DOM helpers ───────────────────────────────────────────────────────────────────────────
function applyOptions(el, o) {
  if (o == null) return el;
  if (typeof o === "string") { el.className = o; return el; }
  if (o.cls) (Array.isArray(o.cls) ? o.cls : String(o.cls).split(/\s+/)).filter(Boolean).forEach((c) => el.classList.add(c));
  if (o.text != null) { if (o.text instanceof Node) el.appendChild(o.text); else el.textContent = String(o.text); }
  if (o.attr) for (const [k, v] of Object.entries(o.attr)) { if (v === null || v === false) continue; el.setAttribute(k, v === true ? "" : String(v)); }
  for (const k of ["title", "type", "value", "href", "placeholder"]) if (o[k] != null) el.setAttribute(k, String(o[k]));
  if (o.value != null && "value" in el) el.value = o.value;
  if (o.parent) o.prepend ? o.parent.prepend(el) : o.parent.appendChild(el);
  return el;
}
const SVG_TAGS = new Set(["svg", "path", "circle", "rect", "line", "polyline", "polygon", "g", "text", "defs", "linearGradient", "radialGradient", "stop", "ellipse", "use", "tspan", "clipPath", "mask"]);
function make(tag, o, cb) {
  const el = SVG_TAGS.has(tag) ? document.createElementNS("http://www.w3.org/2000/svg", tag) : document.createElement(tag);
  applyOptions(el, o);
  if (cb) cb(el);
  return el;
}
const NP = Node.prototype;
Object.assign(NP, {
  createEl(tag, o, cb) { const el = make(tag, o, cb); (o && o.prepend) ? this.prepend(el) : this.appendChild(el); return el; },
  createDiv(o, cb) { return this.createEl("div", o, cb); },
  createSpan(o, cb) { return this.createEl("span", o, cb); },
  createSvg(tag, o, cb) { return this.createEl(tag, o, cb); },
  empty() { while (this.firstChild) this.removeChild(this.firstChild); },
  detach() { if (this.parentNode) this.parentNode.removeChild(this); },
  appendText(t) { this.appendChild(document.createTextNode(String(t))); },
  setText(t) { this.textContent = t == null ? "" : String(t); },
  getText() { return this.textContent; },
  indexOf(child) { return Array.prototype.indexOf.call(this.childNodes, child); },
  instanceOf(T) { return this instanceof T; },
});
const EP = Element.prototype;
Object.assign(EP, {
  addClass(...c) { c.flat().forEach((x) => x && this.classList.add(...String(x).split(/\s+/).filter(Boolean))); return this; },
  addClasses(c) { return this.addClass(...c); },
  removeClass(...c) { c.flat().forEach((x) => x && this.classList.remove(...String(x).split(/\s+/).filter(Boolean))); return this; },
  removeClasses(c) { return this.removeClass(...c); },
  toggleClass(c, v) { (Array.isArray(c) ? c : [c]).forEach((x) => this.classList.toggle(x, v)); return this; },
  hasClass(c) { return this.classList.contains(c); },
  setAttr(k, v) { if (v === null || v === undefined || v === false) this.removeAttribute(k); else this.setAttribute(k, v === true ? "" : String(v)); },
  setAttrs(o) { for (const [k, v] of Object.entries(o)) this.setAttr(k, v); },
  getAttr(k) { return this.getAttribute(k); },
  find(sel) { return this.querySelector(sel); },
  findAll(sel) { return Array.from(this.querySelectorAll(sel)); },
  show() { this.style.display = ""; },
  hide() { this.style.display = "none"; },
  isShown() { return this.style.display !== "none"; },
  toggle(v) { this.style.display = v ? "" : "none"; },
  onClickEvent(fn, opts) { this.addEventListener("click", fn, opts); },
  setCssStyles(o) { Object.assign(this.style, o); },
  setCssProps(o) { for (const [k, v] of Object.entries(o)) this.style.setProperty(k, v); },
});
window.createEl = (tag, o, cb) => make(tag, o, cb);
window.createDiv = (o, cb) => make("div", o, cb);
window.createSpan = (o, cb) => make("span", o, cb);
window.createFragment = (cb) => { const f = document.createDocumentFragment(); if (cb) cb(f); return f; };
Array.prototype.contains ??= function (x) { return this.includes(x); };
Array.prototype.remove ??= function (x) { const i = this.indexOf(x); if (i >= 0) this.splice(i, 1); };
Array.prototype.first ??= function () { return this[0]; };
Array.prototype.last ??= function () { return this[this.length - 1]; };
String.prototype.contains ??= function (x) { return this.includes(x); };

// ── Notices ──────────────────────────────────────────────────────────────────────────────────────────
class Notice {
  constructor(message, timeout = 4000) {
    let box = document.getElementById("space-notices");
    if (!box) { box = document.body.createDiv({ attr: { id: "space-notices" } }); }
    this.noticeEl = box.createDiv({ cls: "notice" });
    this.setMessage(message);
    if (timeout) setTimeout(() => this.hide(), timeout);
  }
  setMessage(m) { this.noticeEl.empty(); if (m instanceof Node) this.noticeEl.appendChild(m); else this.noticeEl.setText(m); return this; }
  hide() { this.noticeEl.detach(); }
}
window.Notice = Notice;

// ── Dates: the part of Luxon's DateTime that scripts use ─────────────────────────────────────────────
const RU_MONTHS = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"];
const pad = (n, w = 2) => String(Math.trunc(Math.abs(n))).padStart(w, "0");
class DateTime {
  constructor(ms, locale = "ru") { this.ts = ms; this.loc = locale; this._d = new Date(ms); }
  static fromMillis(ms) { return new DateTime(ms); }
  static fromJSDate(d) { return new DateTime(d.getTime()); }
  static now() { return new DateTime(Date.now()); }
  static local(y, m = 1, d = 1, h = 0, mi = 0, s = 0) { return y == null ? DateTime.now() : new DateTime(new Date(y, m - 1, d, h, mi, s).getTime()); }
  static fromISO(s) {
    const m = String(s).match(/^(\d{4})-(\d{2})(?:-(\d{2}))?(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?)?/);
    if (!m) { const t = Date.parse(s); return isNaN(t) ? DateTime.invalid() : new DateTime(t); }
    return DateTime.local(+m[1], +m[2], +(m[3] || 1), +(m[4] || 0), +(m[5] || 0), +(m[6] || 0));
  }
  static fromFormat(s, f) { return DateTime.fromISO(s); }
  static invalid() { const d = new DateTime(NaN); return d; }
  get isValid() { return !isNaN(this.ts); }
  get year() { return this._d.getFullYear(); }
  get month() { return this._d.getMonth() + 1; }
  get day() { return this._d.getDate(); }
  get hour() { return this._d.getHours(); }
  get minute() { return this._d.getMinutes(); }
  get second() { return this._d.getSeconds(); }
  get weekday() { return ((this._d.getDay() + 6) % 7) + 1; }
  get weekNumber() {
    const d = new Date(Date.UTC(this.year, this.month - 1, this.day));
    const day = d.getUTCDay() || 7; d.setUTCDate(d.getUTCDate() + 4 - day);
    return Math.ceil(((d - Date.UTC(d.getUTCFullYear(), 0, 1)) / 86400000 + 1) / 7);
  }
  get weekYear() { const d = new Date(this.ts); d.setDate(d.getDate() + 4 - (this.weekday)); return d.getFullYear(); }
  get daysInMonth() { return new Date(this.year, this.month, 0).getDate(); }
  valueOf() { return this.ts; }
  toMillis() { return this.ts; }
  toSeconds() { return this.ts / 1000; }
  toJSDate() { return new Date(this.ts); }
  setLocale(l) { return new DateTime(this.ts, l); }
  toISODate() { return `${this.year}-${pad(this.month)}-${pad(this.day)}`; }
  toISO() { return `${this.toISODate()}T${pad(this.hour)}:${pad(this.minute)}:${pad(this.second)}`; }
  toString() { return this.toISO(); }
  toJSON() { return this.toISO(); }
  toLocaleString(o) { return this._d.toLocaleString(this.loc, o); }
  toFormat(f) {
    const loc = this.loc;
    const name = (o) => this._d.toLocaleString(loc, o);
    const map = {
      yyyy: () => String(this.year), yy: () => pad(this.year % 100), y: () => String(this.year),
      kkkk: () => String(this.weekYear), WW: () => pad(this.weekNumber), W: () => String(this.weekNumber),
      MMMM: () => (loc.startsWith("ru") ? RU_MONTHS[this.month - 1] : name({ month: "long" })),
      MMM: () => name({ month: "short" }), MM: () => pad(this.month), M: () => String(this.month),
      LLLL: () => name({ month: "long" }), LLL: () => name({ month: "short" }), LL: () => pad(this.month), L: () => String(this.month),
      dd: () => pad(this.day), d: () => String(this.day),
      cccc: () => name({ weekday: "long" }), ccc: () => name({ weekday: "short" }), EEEE: () => name({ weekday: "long" }), EEE: () => name({ weekday: "short" }),
      c: () => String(this.weekday), E: () => String(this.weekday),
      HH: () => pad(this.hour), H: () => String(this.hour), hh: () => pad(this.hour % 12 || 12), h: () => String(this.hour % 12 || 12),
      mm: () => pad(this.minute), m: () => String(this.minute), ss: () => pad(this.second), s: () => String(this.second),
      a: () => (this.hour < 12 ? "AM" : "PM"),
    };
    const tokens = Object.keys(map).sort((a, b) => b.length - a.length);
    let out = "", i = 0;
    while (i < f.length) {
      if (f[i] === "'") { const j = f.indexOf("'", i + 1); out += f.slice(i + 1, j < 0 ? f.length : j); i = j < 0 ? f.length : j + 1; continue; }
      const t = tokens.find((k) => f.startsWith(k, i));
      if (t) { out += map[t](); i += t.length; } else { out += f[i]; i++; }
    }
    return out;
  }
  toRelative() {
    const diff = (this.ts - Date.now()) / 1000;
    const rtf = new Intl.RelativeTimeFormat(this.loc, { numeric: "auto" });
    const units = [["year", 31536000], ["month", 2592000], ["week", 604800], ["day", 86400], ["hour", 3600], ["minute", 60], ["second", 1]];
    for (const [u, s] of units) if (Math.abs(diff) >= s || u === "second") return rtf.format(Math.round(diff / s), u);
  }
  toRelativeCalendar() { return this.toRelative(); }
  startOf(u) {
    const d = new Date(this.ts);
    if (u === "year") d.setMonth(0, 1);
    if (u === "year" || u === "month") d.setDate(u === "month" ? 1 : d.getDate());
    if (u === "week") d.setDate(d.getDate() - ((d.getDay() + 6) % 7));
    if (u !== "hour" && u !== "minute") d.setHours(0, 0, 0, 0);
    else if (u === "hour") d.setMinutes(0, 0, 0); else d.setSeconds(0, 0);
    return new DateTime(d.getTime(), this.loc);
  }
  endOf(u) { return this.startOf(u).plus({ [u + "s"]: 1 }).minus({ milliseconds: 1 }); }
  plus(o) {
    const d = new Date(this.ts);
    const g = (k) => (o[k] || 0) + (o[k.replace(/s$/, "")] || 0);
    if (g("years")) d.setFullYear(d.getFullYear() + g("years"));
    if (g("months")) d.setMonth(d.getMonth() + g("months"));
    if (g("weeks") || g("days")) d.setDate(d.getDate() + 7 * g("weeks") + g("days"));
    return new DateTime(d.getTime() + g("hours") * 3600000 + g("minutes") * 60000 + g("seconds") * 1000 + g("milliseconds"), this.loc);
  }
  minus(o) { const n = {}; for (const [k, v] of Object.entries(o)) n[k] = -v; return this.plus(n); }
  diff(other, unit = "milliseconds") {
    const ms = this.ts - other.ts;
    const per = { milliseconds: 1, seconds: 1e3, minutes: 6e4, hours: 36e5, days: 864e5, weeks: 6048e5 };
    const u = Array.isArray(unit) ? unit[0] : unit;
    const val = ms / (per[u] || 1);
    return { [u]: val, as: (x) => ms / (per[x] || 1), toMillis: () => ms };
  }
  hasSame(other, unit) { return this.startOf(unit).ts === other.startOf(unit).ts; }
  equals(o) { return o && o.ts === this.ts; }
}
const Duration = { fromObject: (o) => ({ ...o, as: (u) => 0 }) };

// ── Links ────────────────────────────────────────────────────────────────────────────────────────────
class Link {
  constructor(path, display, embed = false) { this.path = path; this.display = display; this.embed = embed; this.type = "file"; this.subpath = undefined; }
  static file(path, embed, display) { return new Link(path, display, embed); }
  toString() { return this.markdown(); }
  markdown() { return `${this.embed ? "!" : ""}[[${this.path}${this.display ? "|" + this.display : ""}]]`; }
  obsidianLink() { return this.markdown(); }
  fileName() { return this.path.split("/").pop().replace(/\.md$/, ""); }
  withDisplay(d) { return new Link(this.path, d, this.embed); }
  toEmbed() { return new Link(this.path, this.display, true); }
  equals(o) { return o instanceof Link && linkKey(o.path) === linkKey(this.path); }
}
const linkKey = (p) => String(p).split("#")[0].split("/").pop().replace(/\.md$/i, "").toLowerCase();

// ── DataArray: Dataview's list with where/sort/swizzling (pages().file.tasks) ────────────────────────
const compare = (a, b) => {
  if (a == null && b == null) return 0;
  if (a == null) return -1;
  if (b == null) return 1;
  if (a instanceof Link) a = a.fileName().toLowerCase();
  if (b instanceof Link) b = b.fileName().toLowerCase();
  if (a instanceof DateTime || b instanceof DateTime) return +a - +b;
  if (typeof a === "number" && typeof b === "number") return a - b;
  if (typeof a === "boolean" && typeof b === "boolean") return (a ? 1 : 0) - (b ? 1 : 0);
  return String(a).localeCompare(String(b));
};
class DataArrayImpl {
  constructor(values) { this.values = values; }
  get length() { return this.values.length; }
  where(f) { return wrap(this.values.filter(f)); }
  filter(f) { return this.where(f); }
  map(f) { return wrap(this.values.map(f)); }
  flatMap(f) { return wrap(this.values.flatMap((v, i) => { const r = f(v, i); return isDA(r) ? r.values : r; })); }
  mutate(f) { this.values.forEach(f); return this; }
  limit(n) { return wrap(this.values.slice(0, n)); }
  slice(a, b) { return wrap(this.values.slice(a, b)); }
  concat(o) { return wrap(this.values.concat(isDA(o) ? o.values : o)); }
  indexOf(x, from) { return this.values.indexOf(x, from); }
  find(f) { return this.values.find(f); }
  findIndex(f) { return this.values.findIndex(f); }
  includes(x) { return this.values.includes(x); }
  join(sep) { return this.values.join(sep ?? ", "); }
  sort(key, dir, cmp) {
    const k = typeof key === "function" ? key : (x) => x;
    const s = dir === "desc" || dir === "descending" ? -1 : 1;
    return wrap(this.values.map((v, i) => [v, k(v), i]).sort((a, b) => (cmp ? cmp(a[1], b[1]) : compare(a[1], b[1])) * s || a[2] - b[2]).map((x) => x[0]));
  }
  sortInPlace(key, dir) { this.values = this.sort(key, dir).values; return this; }
  groupBy(key, cmp) {
    const groups = new Map();
    for (const v of this.values) {
      const k = key(v), id = k instanceof Link ? linkKey(k.path) : (k instanceof DateTime ? k.ts : k);
      if (!groups.has(id)) groups.set(id, { key: k, rows: [] });
      groups.get(id).rows.push(v);
    }
    return wrap([...groups.values()].map((g) => ({ key: g.key, rows: wrap(g.rows) }))).sort((g) => g.key, "asc", cmp);
  }
  groupIn(key) { return this.groupBy(key); }
  distinct(key) { const seen = new Set(), out = []; for (const v of this.values) { const k = key ? key(v) : v; const id = k instanceof Link ? linkKey(k.path) : +k || k; if (!seen.has(id)) { seen.add(id); out.push(v); } } return wrap(out); }
  every(f) { return this.values.every(f); }
  some(f) { return this.values.some(f); }
  none(f) { return !this.values.some(f); }
  all(f) { return this.every(f); }
  any(f) { return this.some(f); }
  first() { return this.values[0]; }
  last() { return this.values[this.values.length - 1]; }
  to(k) { return this.map((v) => v[k]); }
  into(k) { return this.flatMap((v) => v[k] ?? []); }
  expand(k) { const out = []; const go = (v) => { out.push(v); for (const c of (v[k] || [])) go(c); }; this.values.forEach(go); return wrap(out); }
  forEach(f) { this.values.forEach(f); }
  array() { return [...this.values]; }
  sum() { return this.values.reduce((a, b) => a + (+b || 0), 0); }
  avg() { return this.values.length ? this.sum() / this.values.length : 0; }
  min() { return this.values.reduce((a, b) => (a == null || compare(b, a) < 0 ? b : a), undefined); }
  max() { return this.values.reduce((a, b) => (a == null || compare(b, a) > 0 ? b : a), undefined); }
  reduce(f, init) { return this.values.reduce(f, init); }
  [Symbol.iterator]() { return this.values[Symbol.iterator](); }
  toString() { return this.values.join(", "); }
}
const isDA = (x) => x && x.__isDataArray === true;
function wrap(values) {
  const impl = new DataArrayImpl(values);
  return new Proxy(impl, {
    get(t, p) {
      if (p === "__isDataArray") return true;
      if (typeof p === "symbol" || p in t) { const v = t[p]; return typeof v === "function" ? v.bind(t) : v; }
      if (/^\d+$/.test(p)) return t.values[+p];
      // swizzle: pages.file.name → every page's file.name, lists flattened
      const out = [];
      for (const v of t.values) { if (v == null) continue; const x = v[p]; if (isDA(x)) out.push(...x.values); else if (Array.isArray(x)) out.push(...x); else if (x !== undefined) out.push(x); }
      return wrap(out);
    },
    set(t, p, v) { if (/^\d+$/.test(p)) t.values[+p] = v; else t[p] = v; return true; },
  });
}

// ── The vault's data from Space ─────────────────────────────────────────────────────────────────────
function revive(v) {
  if (Array.isArray(v)) return v.map(revive);
  if (v && typeof v === "object") {
    if ("$d" in v) return new DateTime(v.$d);
    if ("$l" in v) return new Link(v.$l, v.d || undefined);
    if ("$dur" in v) return { seconds: v.$dur, as: (u) => v.$dur / ({ seconds: 1, minutes: 60, hours: 3600, days: 86400 }[u] || 1) };
    const o = {};
    for (const [k, x] of Object.entries(v)) o[k] = revive(x);
    return o;
  }
  return v;
}
let pages = [], byPath = new Map(), byTitle = new Map(), allFiles = new Set(), allFolders = new Set();
function load(data) {
  pages = data.pages.map((raw) => {
    const p = revive(raw);
    const f = p.file;
    f.path = f.path; f.link = new Link(f.path.replace(/\.md$/, ""), undefined);
    f.link.path = f.path;
    for (const k of ["tasks", "lists", "tags", "etags", "outlinks", "inlinks", "aliases"]) f[k] = wrap(f[k] || []);
    f.tasks.values.forEach((t) => { t.link = f.link; t.path = f.path; t.children = t.children || []; t.subtasks = t.children; t.real = true; t.task = true; t.parent = undefined; });
    return p;
  });
  byPath = new Map(pages.map((p) => [p.file.path, p]));
  byTitle = new Map();
  for (const p of [...pages].sort((a, b) => a.file.path.localeCompare(b.file.path))) if (!byTitle.has(p.file.name.toLowerCase())) byTitle.set(p.file.name.toLowerCase(), p);
  allFiles = new Set(data.files);
  allFolders = new Set(data.folders);
}
load(S);

function pageFor(ref) {
  if (ref == null) return undefined;
  if (ref instanceof Link) ref = ref.path;
  if (ref.file) return ref;
  const s = String(ref);
  return byPath.get(s) || byPath.get(s + ".md") || byTitle.get(linkKey(s));
}

// FROM in dv.pages(): "folder", #tag, [[link]], and/or/-, brackets
function selectPages(source) {
  if (source == null || String(source).trim() === "") return pages;
  const text = String(source);
  let i = 0;
  const ws = () => { while (i < text.length && /\s/.test(text[i])) i++; };
  const word = (w) => { ws(); if (text.substr(i, w.length).toLowerCase() === w && !/[\p{L}\d]/u.test(text[i + w.length] || "")) { i += w.length; return true; } return false; };
  const atom = () => {
    ws();
    if (text[i] === "-" || text[i] === "!") { i++; const s = atom(); return pages.filter((p) => !s.includes(p)); }
    if (text[i] === "(") { i++; const s = or(); ws(); if (text[i] === ")") i++; return s; }
    if (text[i] === '"') {
      const j = text.indexOf('"', i + 1); const f = text.slice(i + 1, j < 0 ? text.length : j).replace(/^\/|\/$/g, ""); i = j < 0 ? text.length : j + 1;
      const l = f.toLowerCase();
      return pages.filter((p) => { const id = p.file.path.toLowerCase(); return !l || id.startsWith(l + "/") || id === l || id === l + ".md"; });
    }
    if (text[i] === "#") {
      let j = i + 1; while (j < text.length && /[\p{L}\p{N}_\/-]/u.test(text[j])) j++;
      const t = text.slice(i, j).toLowerCase(); i = j;
      return pages.filter((p) => p.file.tags.values.some((x) => x.toLowerCase() === t));
    }
    if (text.startsWith("[[", i)) {
      const j = text.indexOf("]]", i); const target = text.slice(i + 2, j).split("|")[0]; i = j + 2;
      const key = target ? linkKey(target) : (cur() ? cur().file.name.toLowerCase() : "");
      return pages.filter((p) => p.file.outlinks.values.some((l) => linkKey(l.path) === key));
    }
    throw new Error(`Непонятный источник в dv.pages(): ${text}`);
  };
  const and = () => { let s = atom(); while (word("and")) { const b = atom(); s = s.filter((p) => b.includes(p)); } return s; };
  const or = () => { let s = and(); while (word("or")) { const b = and(); s = s.concat(b.filter((p) => !s.includes(p))); } return s; };
  return or();
}

const cur = () => (S.current ? byPath.get(S.current) : undefined);

// ── Markdown, for dv.el / dv.paragraph and ```tasks queries ──────────────────────────────────────────
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
function inline(md) {
  let s = esc(md);
  s = s.replace(/`([^`]+)`/g, "<code>$1</code>");
  s = s.replace(/!\[\[([^\]]+)\]\]/g, (m, t) => `<span class="internal-embed">${t.split("|")[0]}</span>`);
  s = s.replace(/\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/g, (m, t, a) => `<a class="internal-link" data-href="${t}" href="#">${a || t.split("#")[0].split("/").pop()}</a>`);
  s = s.replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a class="external-link" href="$2">$1</a>');
  s = s.replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>").replace(/__(.+?)__/g, "<strong>$1</strong>");
  s = s.replace(/(^|[^*])\*(?!\s)(.+?)\*/g, "$1<em>$2</em>").replace(/(^|\W)_(?!\s)(.+?)_(?=\W|$)/g, "$1<em>$2</em>");
  s = s.replace(/==(.+?)==/g, "<mark>$1</mark>").replace(/~~(.+?)~~/g, "<del>$1</del>");
  s = s.replace(/(^|\s)(#[\p{L}\p{N}_\/-]+)/gu, '$1<a class="tag" href="#">$2</a>');
  return s;
}
function renderMarkdown(md, into) {
  const lines = String(md ?? "").split("\n");
  let i = 0, list = null, para = [];
  const flush = () => { if (para.length) { into.createEl("p").innerHTML = para.map(inline).join("<br>"); para = []; } };
  while (i < lines.length) {
    const l = lines[i];
    const fence = l.match(/^\s*(```|~~~)\s*(\S*)/);
    if (fence) {
      flush(); list = null;
      const body = []; i++;
      while (i < lines.length && !lines[i].trim().startsWith(fence[1])) body.push(lines[i++]);
      i++;
      if (fence[2].toLowerCase() === "tasks") renderTasksQuery(body, into);
      else { const pre = into.createEl("pre"); pre.createEl("code", { text: body.join("\n") }); }
      continue;
    }
    const h = l.match(/^(#{1,6})\s+(.*)$/);
    if (h) { flush(); list = null; into.createEl("h" + h[1].length).innerHTML = inline(h[2]); i++; continue; }
    const item = l.match(/^\s*([-*+]|\d+[.)])\s+(?:\[(.)\]\s+)?(.*)$/);
    if (item) {
      flush();
      if (!list) list = into.createEl(/\d/.test(item[1]) ? "ol" : "ul");
      const li = list.createEl("li");
      if (item[2] != null) { li.addClass("task-list-item"); const cb = li.createEl("input", { type: "checkbox", cls: "task-list-item-checkbox" }); cb.checked = item[2] !== " "; cb.disabled = true; li.appendText(" "); }
      li.insertAdjacentHTML("beforeend", inline(item[3]));
      i++; continue;
    }
    if (!l.trim()) { flush(); list = null; i++; continue; }
    list = null; para.push(l); i++;
  }
  flush();
  return into;
}

// The Tasks plugin's query blocks: done / not done, due before|after|on, path (does not) include(s), sort by, limit
function dayOf(word) {
  const t = new Date(); t.setHours(0, 0, 0, 0);
  const w = word.trim().toLowerCase();
  if (w === "today") return t.getTime();
  if (w === "tomorrow") return t.getTime() + 864e5;
  if (w === "yesterday") return t.getTime() - 864e5;
  const d = DateTime.fromISO(w); return d.isValid ? d.ts : NaN;
}
function renderTasksQuery(lines, into) {
  let tasks = pages.flatMap((p) => p.file.tasks.values);
  const sorts = []; let limit = Infinity; const hide = new Set(); let short = false;
  for (const raw of lines) {
    const q = raw.trim().toLowerCase(); let m;
    if (!q || q.startsWith("#")) continue;
    if (q === "not done") tasks = tasks.filter((t) => !t.completed);
    else if (q === "done") tasks = tasks.filter((t) => t.completed);
    else if (q === "has due date") tasks = tasks.filter((t) => t.due);
    else if (q === "no due date") tasks = tasks.filter((t) => !t.due);
    else if ((m = q.match(/^(due|scheduled|start|done|happens)\s+(before|after|on)\s+(.+)$/))) {
      const field = m[1] === "done" ? "completion" : m[1], d = dayOf(m[3]);
      tasks = tasks.filter((t) => {
        const v = m[1] === "happens" ? [t.due, t.scheduled, t.start].filter(Boolean) : [t[field]].filter(Boolean);
        return v.some((x) => (m[2] === "before" ? x.ts < d : m[2] === "after" ? x.ts > d : x.ts === d));
      });
    } else if ((m = q.match(/^(path|description|heading|filename)\s+(includes|does not include)\s+(.+)$/))) {
      const needle = raw.trim().slice(raw.trim().toLowerCase().indexOf(m[2]) + m[2].length).trim().toLowerCase();
      const get = (t) => (m[1] === "path" ? t.path : m[1] === "filename" ? t.path.split("/").pop() : t.visual || t.text).toLowerCase();
      tasks = tasks.filter((t) => get(t).includes(needle) === (m[2] === "includes"));
    } else if ((m = q.match(/^tags?\s+(include|includes|do not include|does not include)\s+(.+)$/))) {
      const tag = m[2].replace(/^#/, "");
      tasks = tasks.filter((t) => (t.tags || []).some((x) => String(x).toLowerCase().includes(tag)) === m[1].startsWith("include"));
    } else if ((m = q.match(/^sort by\s+(\w+)(\s+reverse)?$/))) sorts.push([m[1], !!m[2]]);
    else if ((m = q.match(/^limit(?:\s+to)?\s+(\d+)/))) limit = +m[1];
    else if ((m = q.match(/^hide\s+(.+)$/))) hide.add(m[1]);
    else if (q === "short mode") short = true;
  }
  const keyOf = { due: (t) => t.due, scheduled: (t) => t.scheduled, start: (t) => t.start, done: (t) => t.completion, priority: (t) => t.priority, path: (t) => t.path, description: (t) => t.visual, status: (t) => (t.completed ? 1 : 0) };
  if (!sorts.length) sorts.push(["status", false], ["due", false], ["path", false]);
  tasks = tasks.map((t, i) => [t, i]).sort((a, b) => {
    for (const [k, rev] of sorts) {
      const f = keyOf[k] || ((t) => t[k]);
      const x = f(a[0]), y = f(b[0]);
      if (x == null && y != null) return 1;
      if (y == null && x != null) return -1;
      const c = compare(x, y); if (c) return rev ? -c : c;
    }
    return a[1] - b[1];
  }).map((x) => x[0]).slice(0, limit);

  const box = into.createDiv({ cls: "block-language-tasks" });
  const ul = box.createEl("ul", { cls: "contains-task-list plugin-tasks-query-result" });
  const today = dayOf("today");
  for (const t of tasks) {
    const li = ul.createEl("li", { cls: "task-list-item plugin-tasks-list-item" + (t.completed ? " is-checked" : ""), attr: { "data-task": t.status } });
    const cb = li.createEl("input", { type: "checkbox", cls: "task-list-item-checkbox" });
    cb.checked = t.completed;
    cb.addEventListener("click", (e) => { e.preventDefault(); native("toggle", { path: t.path, line: t.line }); });
    const desc = li.createSpan({ cls: "tasks-list-text" });
    desc.innerHTML = inline(t.visual || t.text);
    const meta = li.createSpan({ cls: "task-extras" });
    const date = (emoji, d, cls) => { if (!d) return; const s = meta.createSpan({ cls: "task-" + cls, text: ` ${emoji} ${short ? "" : d.toISODate()}` }); if (cls === "due" && !t.completed && d.ts < today) s.addClass("is-overdue"); };
    if (!hide.has("due date")) date("📅", t.due, "due");
    if (!hide.has("scheduled date")) date("⏳", t.scheduled, "scheduled");
    if (!hide.has("done date")) date("✅", t.completion, "done");
    if (!hide.has("backlink")) {
      const a = li.createEl("a", { cls: "internal-link tasks-backlink", text: " (" + t.path.split("/").pop().replace(/\.md$/, "") + ")", attr: { "data-href": t.path, href: "#" } });
    }
  }
  if (!hide.has("task count")) box.createDiv({ cls: "tasks-count", text: `${tasks.length} ${plural(tasks.length, "задача", "задачи", "задач")}` });
}
const plural = (n, one, few, many) => { const m10 = n % 10, m100 = n % 100; return m10 === 1 && m100 !== 11 ? one : m10 >= 2 && m10 <= 4 && (m100 < 10 || m100 >= 20) ? few : many; };

// ── Files: Obsidian's app.vault ──────────────────────────────────────────────────────────────────────
function tfile(path) {
  const name = path.split("/").pop(), dot = name.lastIndexOf(".");
  const parentPath = path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "/";
  const p = byPath.get(path);
  return {
    path, name, basename: dot > 0 ? name.slice(0, dot) : name, extension: dot > 0 ? name.slice(dot + 1) : "",
    parent: tfolder(parentPath, false), vault: app.vault,
    stat: p ? { mtime: +p.file.mtime, ctime: +p.file.ctime, size: p.file.size } : { mtime: 0, ctime: 0, size: 0 },
  };
}
function tfolder(path, withChildren = true) {
  const f = { path, name: path === "/" ? "" : path.split("/").pop(), isRoot: () => path === "/" };
  if (withChildren) Object.defineProperty(f, "children", { get: () => [...allFiles].filter((x) => (path === "/" ? !x.includes("/") : x.startsWith(path + "/") && !x.slice(path.length + 1).includes("/"))).map(tfile) });
  return f;
}
const pathOf = (f) => (typeof f === "string" ? f : f.path);
const norm = (p) => String(p).replace(/^\/+/, "");

async function readText(path) {
  const t = await native("read", { path: norm(path) });
  if (t == null) throw new Error(`Файл не найден: ${path}`);
  return t;
}

const vault = {
  adapter: {
    basePath: undefined,
    exists: async (p) => allFiles.has(norm(p)) || allFolders.has(norm(p)),
    read: (p) => readText(p),
    write: async (p, t) => { await native("write", { path: norm(p), text: t }); allFiles.add(norm(p)); },
    getResourcePath: (p) => "space-file:///" + encodeURI(norm(p)),
  },
  getName: () => S.vaultName,
  getAbstractFileByPath(p) {
    p = norm(p).replace(/\/$/, "");
    if (p === "" || p === "/") return tfolder("/");
    if (allFiles.has(p)) return tfile(p);
    if (allFolders.has(p)) return tfolder(p);
    return null;
  },
  getFileByPath(p) { p = norm(p); return allFiles.has(p) ? tfile(p) : null; },
  getFolderByPath(p) { p = norm(p); return allFolders.has(p) ? tfolder(p) : null; },
  getRoot: () => tfolder("/"),
  getMarkdownFiles: () => [...allFiles].filter((p) => p.endsWith(".md")).map(tfile),
  getFiles: () => [...allFiles].map(tfile),
  getAllLoadedFiles: () => [...allFolders].map((p) => tfolder(p)).concat([...allFiles].map(tfile)),
  read: (f) => readText(pathOf(f)),
  cachedRead: (f) => readText(pathOf(f)),
  readBinary: async (f) => { const b = await native("readBinary", { path: norm(pathOf(f)) }); return b == null ? new ArrayBuffer(0) : base64ToBuffer(b); },
  async modify(f, text) { await native("write", { path: norm(pathOf(f)), text }); },
  async append(f, text) { const t = await readText(pathOf(f)); await native("write", { path: norm(pathOf(f)), text: t + text }); },
  async process(f, fn) { const t = await readText(pathOf(f)); const n = fn(t); if (n !== t) await native("write", { path: norm(pathOf(f)), text: n }); return n; },
  async create(p, text) {
    p = norm(p);
    if (allFiles.has(p)) throw new Error("Файл уже существует.");
    const ok = await native("create", { path: p, text: text ?? "" });
    if (!ok) throw new Error("Не удалось создать файл " + p);
    allFiles.add(p);
    return tfile(p);
  },
  async createBinary(p, buf) {
    p = norm(p);
    if (allFiles.has(p)) throw new Error("Файл уже существует.");
    const ok = await native("createBinary", { path: p, base64: bufferToBase64(buf) });
    if (!ok) throw new Error("Не удалось создать файл " + p);
    allFiles.add(p);
    return tfile(p);
  },
  async createFolder(p) {
    p = norm(p).replace(/\/$/, "");
    if (allFolders.has(p)) throw new Error("Папка уже существует.");
    await native("createFolder", { path: p });
    let acc = ""; for (const part of p.split("/")) { acc = acc ? acc + "/" + part : part; allFolders.add(acc); }
    return tfolder(p);
  },
  getResourcePath: (f) => "space-file:///" + encodeURI(norm(pathOf(f))),
  on: () => ({}), off: () => {}, offref: () => {},
};
function bufferToBase64(buf) {
  const bytes = new Uint8Array(buf instanceof ArrayBuffer ? buf : buf.buffer || buf); let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return btoa(s);
}
function base64ToBuffer(b) { const s = atob(b); const out = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i); return out.buffer; }

// Frontmatter as a plain object (flat YAML, like Obsidian's properties)
function splitFrontmatter(text) {
  const m = text.match(/^---\r?\n([\s\S]*?)\r?\n---[ \t]*(\r?\n|$)/);
  return m ? { yaml: m[1], body: text.slice(m[0].length) } : { yaml: null, body: text };
}
function parseYAML(yaml) {
  const out = {}; let lastKey = null;
  const scalar = (s) => {
    s = s.trim();
    if (/^".*"$|^'.*'$/.test(s)) return s.slice(1, -1);
    if (s === "true" || s === "false") return s === "true";
    if (s === "null" || s === "") return null;
    if (/^-?\d+(\.\d+)?$/.test(s)) return +s;
    if (/^\[.*\]$/.test(s) && !/^\[\[/.test(s)) return s.slice(1, -1).split(",").map((x) => scalar(x)).filter((x) => x !== null && x !== "");
    return s;
  };
  for (const raw of (yaml || "").split(/\r?\n/)) {
    if (!raw.trim() || raw.trim().startsWith("#")) continue;
    const item = raw.match(/^\s+-\s*(.*)$|^-\s+(.*)$/);
    if (item && lastKey) { if (!Array.isArray(out[lastKey])) out[lastKey] = []; out[lastKey].push(scalar(item[1] ?? item[2])); continue; }
    const kv = raw.match(/^([^:\s][^:]*):\s*(.*)$/);
    if (kv) { lastKey = kv[1].trim(); out[lastKey] = kv[2].trim() === "" ? null : scalar(kv[2]); }
  }
  return out;
}
function yamlValue(v) {
  if (v === null || v === undefined) return "";
  if (typeof v === "boolean" || typeof v === "number") return String(v);
  if (v instanceof DateTime) return v.toISODate();
  const s = String(v);
  return /^[\[\]{}#&*!|>'"%@`,]|: |^\s|\s$|^(true|false|null|-?\d+(\.\d+)?)$/.test(s) || s === "" ? JSON.stringify(s) : s;
}
function dumpYAML(o) {
  const lines = [];
  for (const [k, v] of Object.entries(o)) {
    if (v === undefined) continue;
    if (Array.isArray(v)) { if (!v.length) lines.push(`${k}: []`); else { lines.push(`${k}:`); v.forEach((x) => lines.push(`  - ${yamlValue(x)}`)); } }
    else lines.push(v === null ? `${k}:` : `${k}: ${yamlValue(v)}`);
  }
  return lines.join("\n");
}

const app = {
  vault,
  isMobile: !!S.isMobile,
  workspace: {
    openLinkText: (link, source, newLeaf) => native("open", { path: String(link), newTab: !!newLeaf }),
    getLastOpenFiles: () => S.recent || [],
    getActiveFile: () => (S.current ? tfile(S.current) : null),
    on: () => ({}), off: () => {}, offref: () => {}, trigger: () => {},
    onLayoutReady: (f) => f(),
  },
  fileManager: {
    async processFrontMatter(f, fn) {
      const text = await readText(pathOf(f));
      const { yaml, body } = splitFrontmatter(text);
      const fm = parseYAML(yaml);
      fn(fm);
      const dumped = dumpYAML(fm);
      const next = (dumped ? `---\n${dumped}\n---\n` : "") + body;
      if (next !== text) await native("write", { path: norm(pathOf(f)), text: next });
    },
    generateMarkdownLink: (f) => `[[${pathOf(f).replace(/\.md$/, "").split("/").pop()}]]`,
  },
  metadataCache: {
    getFirstLinkpathDest(link, source) { const p = pageFor(String(link).split("#")[0]); return p ? tfile(p.file.path) : (allFiles.has(norm(link)) ? tfile(norm(link)) : null); },
    getFileCache(f) {
      const p = byPath.get(pathOf(f)); if (!p) return null;
      return { frontmatter: p.file.frontmatter, tags: p.file.etags.values.map((tag) => ({ tag })), links: p.file.outlinks.values.map((l) => ({ link: l.path })) };
    },
    on: () => ({}), off: () => {}, offref: () => {},
    resolvedLinks: {},
  },
  commands: { commands: {}, executeCommandById: () => false },
  plugins: { plugins: {}, enabledPlugins: new Set(), getPlugin: () => null },
  setting: { open: () => {}, openTabById: () => {} },
};
window.app = app;

// Node and Obsidian modules: only `obsidian` exists here (requestUrl goes through Space, without CORS)
async function requestUrl(req) {
  const r = typeof req === "string" ? { url: req } : req;
  const res = await native("http", { url: r.url, method: r.method || "GET", headers: r.headers || {}, body: r.body == null ? null : (typeof r.body === "string" ? r.body : bufferToBase64(r.body)), binaryBody: r.body != null && typeof r.body !== "string" });
  if (!res) throw new Error("Нет сети или адрес недоступен: " + r.url);
  const buf = base64ToBuffer(res.body);
  const text = new TextDecoder().decode(buf);
  const out = { status: res.status, headers: res.headers, arrayBuffer: buf, text };
  Object.defineProperty(out, "json", { get: () => JSON.parse(text) });
  if (res.status >= 400 && r.throw !== false) { const e = new Error(`Запрос вернул ${res.status}`); e.status = res.status; throw e; }
  return out;
}
const obsidianModule = { requestUrl, request: async (r) => (await requestUrl(r)).text, Notice, moment: undefined, Platform: { isMobile: !!S.isMobile, isDesktop: !S.isMobile, isMacOS: !S.isMobile, isIosApp: !!S.isMobile } };
// Node's modules, as far as widgets need them on a Mac. Space runs AppleScript itself (after asking you),
// fs reaches only the app's temporary folder, and nothing else from Node is there.
class Buffer extends Uint8Array {
  static from(x, enc) {
    if (typeof x === "string") {
      if (enc === "base64") { const s = atob(x); const b = new Buffer(s.length); for (let i = 0; i < s.length; i++) b[i] = s.charCodeAt(i); return b; }
      const u = new TextEncoder().encode(x); const b = new Buffer(u.length); b.set(u); return b;
    }
    const u = x instanceof ArrayBuffer ? new Uint8Array(x) : Uint8Array.from(x); const b = new Buffer(u.length); b.set(u); return b;
  }
  static isBuffer(x) { return x instanceof Buffer; }
  static concat(list) { const n = list.reduce((a, b) => a + b.length, 0); const out = new Buffer(n); let o = 0; for (const b of list) { out.set(b, o); o += b.length; } return out; }
  toString(enc) {
    if (enc === "base64") return bufferToBase64(this);
    if (enc === "hex") return Array.from(this, (x) => x.toString(16).padStart(2, "0")).join("");
    return new TextDecoder().decode(this);
  }
}
window.Buffer = Buffer;
const nodeError = (name) => new Error(`Модуль «${name}» недоступен в Space: виджет написан для настольного Obsidian.`);
const tmpFiles = new Map();
const pathModule = {
  sep: "/",
  join: (...p) => p.filter((x) => x !== "").join("/").replace(/\/+/g, "/"),
  resolve: (...p) => pathModule.join(...p),
  basename: (p, ext) => { const b = String(p).split("/").pop(); return ext && b.endsWith(ext) ? b.slice(0, -ext.length) : b; },
  dirname: (p) => String(p).split("/").slice(0, -1).join("/") || "/",
  extname: (p) => { const b = String(p).split("/").pop(); const i = b.lastIndexOf("."); return i > 0 ? b.slice(i) : ""; },
};
const osModule = { tmpdir: () => S.tmpdir || "/tmp", homedir: () => S.homedir || "", platform: () => (S.isMobile ? "ios" : "darwin"), EOL: "\n", hostname: () => "space" };
const enoent = (p) => Object.assign(new Error(`ENOENT: no such file, ${p}`), { code: "ENOENT" });
const fsModule = {
  existsSync: (p) => tmpFiles.has(String(p)),
  readFileSync(p, enc) {
    const b = tmpFiles.get(String(p)); if (!b) throw enoent(p);
    const e = typeof enc === "string" ? enc : enc && enc.encoding;
    return e ? b.toString(e) : b;
  },
  writeFileSync(p, data) {
    const b = typeof data === "string" ? Buffer.from(data) : Buffer.from(data);
    tmpFiles.set(String(p), b);
    native("fsWrite", { path: String(p), base64: b.toString("base64") });
  },
  unlinkSync: (p) => { tmpFiles.delete(String(p)); },
  mkdirSync: () => {},
  readFile(p, a, b) { const cb = typeof a === "function" ? a : b; try { cb(null, fsModule.readFileSync(p, typeof a === "function" ? undefined : a)); } catch (e) { cb(e); } },
  writeFile(p, d, a, b) { const cb = typeof a === "function" ? a : b; fsModule.writeFileSync(p, d); cb && cb(null); },
};
fsModule.promises = { readFile: async (p, e) => fsModule.readFileSync(p, e), writeFile: async (p, d) => fsModule.writeFileSync(p, d) };

// child_process: only `osascript -e …`, run by Space as AppleScript.
async function runOsa(args) {
  const parts = [];
  for (let i = 0; i < args.length; i++) if (args[i] === "-e" && i + 1 < args.length) parts.push(args[++i]);
  const r = await native("osascript", { source: parts.join("\n") });
  if (r && r.files) for (const [p, b64] of Object.entries(r.files)) tmpFiles.set(p, Buffer.from(b64, "base64"));
  if (!r || r.error) throw new Error((r && r.error) || "AppleScript не выполнился");
  return String(r.out ?? "") + "\n";
}
function fakeProcess() {
  const handlers = {}; const stdout = { on: (e, f) => ((handlers["out:" + e] = f), stdout) }; const stderr = { on: (e, f) => ((handlers["err:" + e] = f), stderr) };
  const proc = { stdout, stderr, on: (e, f) => ((handlers[e] = f), proc), kill: () => {}, pid: 0 };
  return { proc, handlers };
}
const childProcess = {
  execFile(cmd, args, opts, cb) {
    if (typeof args === "function") { cb = args; args = []; } else if (typeof opts === "function") { cb = opts; }
    const { proc, handlers } = fakeProcess();
    const done = (e, out) => { cb && cb(e, out ?? "", e ? String(e.message) : ""); handlers.close && handlers.close(e ? 1 : 0); handlers.exit && handlers.exit(e ? 1 : 0); };
    if (String(cmd).split("/").pop() !== "osascript") setTimeout(() => done(new Error(`Команда «${cmd}» недоступна в Space: можно только osascript.`)));
    else runOsa(args || []).then((out) => done(null, out), (e) => done(e));
    return proc;
  },
  exec(command, opts, cb) {
    if (typeof opts === "function") cb = opts;
    const m = String(command).match(/^\s*(?:\/usr\/bin\/)?osascript\s+-e\s+(['"])([\s\S]*)\1\s*$/);
    return childProcess.execFile(m ? "osascript" : command, m ? ["-e", m[2]] : [], cb);
  },
  spawn(cmd, args) {
    const { proc, handlers } = fakeProcess();
    const done = (e, out) => { if (out && handlers["out:data"]) handlers["out:data"](Buffer.from(out)); if (e && handlers["err:data"]) handlers["err:data"](Buffer.from(String(e.message))); if (e && handlers.error) handlers.error(e); handlers.close && handlers.close(e ? 1 : 0); handlers.exit && handlers.exit(e ? 1 : 0); };
    if (String(cmd).split("/").pop() !== "osascript") setTimeout(() => done(new Error(`Команда «${cmd}» недоступна в Space: можно только osascript.`)));
    else runOsa(args || []).then((out) => done(null, out), (e) => done(e));
    return proc;
  },
};
childProcess.execFileSync = () => { throw new Error("Синхронный запуск команд недоступен в Space."); };
childProcess.execSync = childProcess.execFileSync;

// https.get / http.get through requestUrl
function httpGet(url, opts, cb) {
  if (typeof opts === "function") cb = opts;
  const u = typeof url === "string" ? url : url.href || `${url.protocol || "https:"}//${url.hostname || url.host}${url.path || "/"}`;
  const reqHandlers = {};
  const req = { on: (e, f) => ((reqHandlers[e] = f), req), end: () => req, setTimeout: () => req, destroy: () => {}, abort: () => {} };
  requestUrl({ url: u, throw: false }).then((r) => {
    const resHandlers = {}; let enc = null;
    const res = { statusCode: r.status, headers: r.headers || {}, on: (e, f) => ((resHandlers[e] = f), res), setEncoding: (e) => { enc = e; }, resume: () => {} };
    cb && cb(res);
    setTimeout(() => { const b = Buffer.from(r.arrayBuffer); resHandlers.data && resHandlers.data(enc ? b.toString(enc) : b); resHandlers.end && resHandlers.end(); });
  }, (e) => reqHandlers.error && reqHandlers.error(e));
  return req;
}
const httpsModule = { get: httpGet, request: (u, o, cb) => httpGet(u, o, cb) };

const nodeModules = { obsidian: obsidianModule, child_process: childProcess, fs: fsModule, os: osModule, path: pathModule, https: httpsModule, http: httpsModule };
window.require = (name) => {
  const m = nodeModules[String(name).replace(/^node:/, "")];
  if (m) return m;
  throw nodeError(name);
};

// System notifications (the web API WebKit doesn't have on the Mac), through Space after the system asks.
class SpaceNotification {
  constructor(title, o = {}) { native("notify", { title: String(title), body: String(o.body || ""), silent: !!o.silent }); }
  static permission = "default";
  static async requestPermission() { SpaceNotification.permission = await native("notifyPermission"); return SpaceNotification.permission; }
  close() {}
}
window.Notification = SpaceNotification;

// ── dv ──────────────────────────────────────────────────────────────────────────────────────────────
const root = document.getElementById("space-root");
function makeDV(container, sourcePath) {
  const dv = {
    container,
    component: { register: () => {}, registerEvent: () => {}, registerInterval: (id) => id, load: () => {}, unload: () => {}, addChild: () => {} },
    app,
    currentFilePath: sourcePath || "",
    luxon: { DateTime, Duration },
    current: () => cur(),
    page: (p) => pageFor(p),
    pages: (src) => wrap(selectPages(src)),
    pagePaths: (src) => wrap(selectPages(src).map((p) => p.file.path)),
    array: (x) => (isDA(x) ? x : wrap(Array.isArray(x) ? x : [x])),
    isArray: (x) => Array.isArray(x) || isDA(x),
    fileLink: (path, embed, display) => new Link(path, display, embed),
    sectionLink: (path, sec, embed, display) => new Link(path + "#" + sec, display, embed),
    date: (s) => (s instanceof DateTime ? s : s === "today" ? DateTime.now().startOf("day") : s === "now" ? DateTime.now() : DateTime.fromISO(s)),
    duration: (s) => s,
    compare,
    equal: (a, b) => compare(a, b) === 0,
    clone: (x) => x,
    parse: (s) => s,
    value: { isArray: (x) => Array.isArray(x) || isDA(x), isLink: (x) => x instanceof Link, isDate: (x) => x instanceof DateTime },
    io: {
      load: (p) => readText(p),
      csv: async (p) => { const t = await readText(p); const [h, ...rows] = t.trim().split(/\r?\n/).map((l) => l.split(",")); return wrap(rows.map((r) => Object.fromEntries(h.map((k, i) => [k.trim(), r[i]])))); },
      normalize: (p) => norm(p),
    },
    el(tag, text, o = {}) {
      const el = container.createEl(tag, o);
      if (text instanceof Node) el.appendChild(text);
      else if (text != null) {
        const tmp = document.createElement("div");
        renderMarkdown(text instanceof Link ? text.markdown() : String(text), tmp);
        // one paragraph is unwrapped into the element, as Obsidian renders inline text
        if (tmp.childNodes.length === 1 && tmp.firstChild.tagName === "P") while (tmp.firstChild.firstChild) el.appendChild(tmp.firstChild.firstChild);
        else while (tmp.firstChild) el.appendChild(tmp.firstChild);
      }
      return el;
    },
    header: (level, text, o) => dv.el("h" + level, text, o),
    paragraph: (text, o) => dv.el("p", text, o),
    span: (text, o) => dv.el("span", text, o),
    list(values) { const ul = container.createEl("ul"); for (const v of (isDA(values) ? values.values : values || [])) { const li = ul.createEl("li"); li.innerHTML = inline(String(v)); } return ul; },
    table(headers, rows) {
      const t = container.createEl("table", { cls: "dataview table-view-table" });
      const hr = t.createEl("thead").createEl("tr"); headers.forEach((h) => hr.createEl("th", { text: h }));
      const tb = t.createEl("tbody");
      for (const r of (isDA(rows) ? rows.values : rows)) { const tr = tb.createEl("tr"); for (const c of r) { const td = tr.createEl("td"); td.innerHTML = inline(c == null ? "" : (isDA(c) ? c.values : c).toString()); } }
      return t;
    },
    taskList(tasks, groupByFile = true) {
      const list = isDA(tasks) ? tasks.values : tasks || [];
      const ul = container.createEl("ul", { cls: "contains-task-list" });
      for (const t of list) {
        const li = ul.createEl("li", { cls: "task-list-item" + (t.completed ? " is-checked" : "") });
        const cb = li.createEl("input", { type: "checkbox", cls: "task-list-item-checkbox" }); cb.checked = !!t.completed;
        cb.addEventListener("click", (e) => { e.preventDefault(); native("toggle", { path: t.path, line: t.line }); });
        li.insertAdjacentHTML("beforeend", " " + inline(t.text));
      }
      return ul;
    },
    async view(path, input) {
      const p = norm(path).replace(/\.js$/, "");
      const candidates = [p + ".js", p + "/view.js"];
      const file = candidates.find((c) => allFiles.has(c)) || candidates[0];
      const code = await readText(file);
      const css = file.endsWith("/view.js") ? file.replace(/view\.js$/, "view.css") : null;
      if (css && allFiles.has(css)) container.createEl("style", { text: await readText(css) });
      return runCode(code, dv, input);
    },
    execute: async () => { container.createEl("p", { cls: "dataview-error", text: "dv.execute() пока не поддерживается в Space" }); },
    executeJs: async () => {},
  };
  return dv;
}

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
async function runCode(code, dv, input) {
  const fn = new AsyncFunction("dv", "input", "app", "luxon", "moment", "require", "Notice", code);
  return fn.call(dv.component, dv, input, app, dv.luxon, undefined, window.require, Notice);
}

function showError(container, e) {
  const box = container.createDiv({ cls: "space-dv-error" });
  box.createDiv({ cls: "space-dv-error-title", text: "Виджет не запустился" });
  box.createEl("pre", { text: String(e && (e.message || e)) });
}

let runID = 0;
async function run() {
  const id = ++runID;
  const container = document.getElementById("space-container");
  container.empty();
  const dv = makeDV(container, S.current);
  try {
    await runCode(S.code, dv);
  } catch (e) {
    if (id === runID) showError(container, e);
    console.error(e);
  }
  reportHeight();
}

// Links inside rendered Markdown open notes in Space; external ones open in the browser.
document.addEventListener("click", (e) => {
  const a = e.target.closest && e.target.closest("a");
  if (!a) return;
  if (a.classList.contains("internal-link")) { e.preventDefault(); native("open", { path: a.getAttribute("data-href") || a.textContent, newTab: e.metaKey || e.ctrlKey }); }
  else if (a.classList.contains("tag")) e.preventDefault();
  else if (/^https?:/.test(a.getAttribute("href") || "")) { e.preventDefault(); native("openURL", { url: a.href }); }
}, true);

// Height for Space, which keeps that much room in the note
let lastHeight = 0;
function reportHeight() {
  const h = Math.ceil(root.getBoundingClientRect().height);
  if (Math.abs(h - lastHeight) > 1) { lastHeight = h; native("height", { h }); }
}
new ResizeObserver(reportHeight).observe(root);

// Space calls this when notes change: fresh data, then the block runs again (as Dataview re-renders).
window.__spaceUpdate = (data) => { Object.assign(S, data); load(S); run(); };
run();
})();
