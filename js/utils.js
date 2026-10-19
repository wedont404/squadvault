// Pure helpers: escaping, safe HTML templating, money, dates, validation.
// No DOM or network access here, so everything is unit-testable in Node.

// ---------------------------------------------------------------------------
// XSS-safe templating. Every interpolated value is escaped unless it is a Raw
// produced by html``/raw(). User data therefore can never inject markup.
// ---------------------------------------------------------------------------
class Raw {
  constructor(s) { this.s = s; }
  toString() { return this.s; }
}
export const raw = (s) => new Raw(String(s));
const ESC = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;", "`": "&#96;" };
export const esc = (v) => String(v ?? "").replace(/[&<>"'`]/g, (c) => ESC[c]);
const part = (v) => {
  if (v instanceof Raw) return v.s;
  if (Array.isArray(v)) return v.map(part).join("");
  if (v === false || v === null || v === undefined) return "";
  return esc(v);
};
export function html(strings, ...vals) {
  let out = strings[0];
  for (let i = 0; i < vals.length; i++) out += part(vals[i]) + strings[i + 1];
  return new Raw(out);
}
export const str = (v) => (v instanceof Raw ? v.s : String(v ?? ""));

// ---------------------------------------------------------------------------
// Money: integer RWF only. Never floats.
// ---------------------------------------------------------------------------
const MAX_MONEY = 1_000_000_000_000;
export function toInt(v) {
  const n = typeof v === "string" ? Number(v) : v;
  return Number.isSafeInteger(n) ? n : 0;
}
const nf = new Intl.NumberFormat("en-US", { maximumFractionDigits: 0 });
export function formatRWF(v) {
  return `${nf.format(toInt(v))} RWF`;
}
export function formatNumber(v) {
  return nf.format(toInt(v));
}
/** "12,500" / "12 500" / "12500" -> 12500, or null if not a positive whole number within limits. */
export function parseRWF(input) {
  const s = String(input ?? "").replace(/[\s,_]/g, "");
  if (!/^\d{1,13}$/.test(s)) return null;
  const n = Number(s);
  return Number.isSafeInteger(n) && n > 0 && n <= MAX_MONEY ? n : null;
}
/** Whole-number percentage, integer math, clamped to 0..100. */
export function percent(part_, total) {
  const p = toInt(part_), t = toInt(total);
  if (t <= 0 || p <= 0) return 0;
  return Math.min(100, Math.floor((p * 100) / t));
}
export const sum = (rows, pick) => rows.reduce((a, r) => a + toInt(pick(r)), 0);

// ---------------------------------------------------------------------------
// Dates
// ---------------------------------------------------------------------------
const dfmt = new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", year: "numeric" });
export function formatDate(d) {
  if (!d) return "No date set";
  const dt = new Date(/^\d{4}-\d{2}-\d{2}$/.test(d) ? `${d}T00:00:00` : d);
  return Number.isNaN(dt.getTime()) ? "—" : dfmt.format(dt);
}
export function timeAgo(ts, now = Date.now()) {
  const t = new Date(ts).getTime();
  if (Number.isNaN(t)) return "";
  const s = Math.max(0, Math.floor((now - t) / 1000));
  if (s < 45) return "just now";
  if (s < 3600) return `${Math.floor(s / 60) || 1} min ago`;
  if (s < 86400) return `${Math.floor(s / 3600)} h ago`;
  if (s < 86400 * 7) return `${Math.floor(s / 86400)} d ago`;
  return formatDate(ts);
}
export function daysUntil(dateStr, now = new Date()) {
  if (!dateStr) return null;
  const target = new Date(`${dateStr}T00:00:00`);
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  return Math.round((target - today) / 86400000);
}
export function relativeExpiry(ts, now = Date.now()) {
  const ms = new Date(ts).getTime() - now;
  if (ms <= 0) return "expired";
  const h = Math.floor(ms / 3600000);
  if (h < 1) return "expires in under an hour";
  if (h < 48) return `expires in ${h} h`;
  return `expires in ${Math.floor(h / 24)} days`;
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------
export const isEmail = (s) => /^[^\s@]{1,64}@[^\s@]{1,255}\.[^\s@]{2,}$/.test(String(s ?? "").trim());
export function passwordProblem(pw) {
  const s = String(pw ?? "");
  if (s.length < 8) return "Use at least 8 characters.";
  if (!/[A-Za-z]/.test(s) || !/\d/.test(s)) return "Include at least one letter and one number.";
  return null;
}
export const isUuid = (s) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(String(s ?? ""));
export const normalizeInviteCode = (s) => String(s ?? "").trim().toUpperCase().replace(/\s+/g, "");
export const isInviteCode = (s) => /^SV-[0-9A-F]{12}$/.test(s);

/** USSD shortcut for paying a MoMo number or merchant code. Only MTN is known; Airtel returns null. */
export function ussdFor({ provider, kind, account, amount }) {
  if (provider !== "mtn_momo" || !/^\d{4,10}$/.test(String(account ?? ""))) return null;
  const amt = Number.isInteger(amount) && amount > 0 ? `*${amount}` : "";
  return kind === "code" ? `*182*8*1*${account}${amt}#` : `*182*1*1*${account}${amt}#`;
}
/** tel: link that opens the phone dialer with the USSD string filled in (# must be encoded). */
export const telHref = (ussd) => `tel:${String(ussd).replace(/#/g, "%23")}`;
/** "0788123456" -> "0788 123 456" */
export const prettyPhone = (p) => String(p).replace(/^(\d{4})(\d{3})(\d{3})$/, "$1 $2 $3");

/** Rwanda mobile numbers -> "2507XXXXXXXX" or null. MTN: 078/079. Airtel: 072/073. */
export function normalizeRwPhone(input) {
  const digits = String(input ?? "").replace(/[\s\-().]/g, "");
  const m = digits.match(/^(?:\+?250|0)(7[2389]\d{7})$/);
  return m ? `250${m[1]}` : null;
}
export function networkOfPhone(phone) {
  const p = String(phone).slice(3, 5);
  if (p === "78" || p === "79") return "mtn_momo";
  if (p === "72" || p === "73") return "airtel_money";
  return null;
}

export const initials = (name) =>
  String(name || "?").trim().split(/\s+/).slice(0, 2).map((w) => w[0]?.toUpperCase() ?? "").join("") || "?";

export const debounce = (fn, ms = 250) => {
  let t;
  return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); };
};

export async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.style.cssText = "position:fixed;opacity:0";
    document.body.appendChild(ta);
    ta.select();
    let ok = false;
    try { ok = document.execCommand("copy"); } catch { /* ignore */ }
    ta.remove();
    return ok;
  }
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export function safeStorage() {
  try {
    const k = "__sv_probe";
    localStorage.setItem(k, "1");
    localStorage.removeItem(k);
    return localStorage;
  } catch {
    return null;
  }
}
