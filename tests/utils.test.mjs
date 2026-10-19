// Unit tests for the pure helpers. Run: npm test   (Node 20+, no dependencies)
import test from "node:test";
import assert from "node:assert/strict";
import {
  html, esc, raw, parseRWF, formatRWF, percent, normalizeRwPhone, networkOfPhone, isInviteCode, normalizeInviteCode,
  passwordProblem, isEmail, relativeExpiry, daysUntil, toInt, sum,
} from "../js/utils.js";

test("html`` escapes interpolated values but not raw()", () => {
  const evil = `<img src=x onerror="alert(1)">`;
  assert.equal(String(html`<p>${evil}</p>`), "<p>&lt;img src=x onerror=&quot;alert(1)&quot;&gt;</p>");
  assert.equal(String(html`<b>${raw("<i>ok</i>")}</b>`), "<b><i>ok</i></b>");
  assert.equal(String(html`${[html`<a>${"<"}</a>`, "&"]}`), "<a>&lt;</a>&amp;");
  assert.equal(String(html`${null}${false}${undefined}`), "");
  assert.equal(esc(`'"\``), "&#39;&quot;&#96;");
});

test("parseRWF accepts only positive whole RWF within limits", () => {
  assert.equal(parseRWF("12,500"), 12500);
  assert.equal(parseRWF(" 5 000 "), 5000);
  for (const bad of ["", "0", "-5", "1.5", "1e6", "abc", "12 5a", "1000000000001", "99999999999999999999"]) assert.equal(parseRWF(bad), null, bad);
});

test("money formatting and percentages use integers", () => {
  assert.equal(formatRWF(1350000), "1,350,000 RWF");
  assert.equal(formatRWF("2500"), "2,500 RWF");
  assert.equal(formatRWF(Number.MAX_SAFE_INTEGER + 10), "0 RWF"); // unsafe numbers never render as money
  assert.equal(percent(750000, 2000000), 37);
  assert.equal(percent(1, 3), 33);
  assert.equal(percent(5, 0), 0);
  assert.equal(percent(300, 100), 100);
  assert.equal(sum([{ a: 1 }, { a: "2" }, { a: null }], (r) => r.a), 3);
  assert.equal(toInt(1.5), 0);
});

test("Rwandan phone numbers and networks", () => {
  assert.equal(normalizeRwPhone("0788 123 456"), "250788123456");
  assert.equal(normalizeRwPhone("+250 722 123 456"), "250722123456");
  assert.equal(normalizeRwPhone("250731234567"), "250731234567");
  for (const bad of ["0771234567", "078123", "12345", "", "0688123456"]) assert.equal(normalizeRwPhone(bad), null, bad);
  assert.equal(networkOfPhone("250788123456"), "mtn_momo");
  assert.equal(networkOfPhone("250791234567"), "mtn_momo");
  assert.equal(networkOfPhone("250722123456"), "airtel_money");
  assert.equal(networkOfPhone("250731234567"), "airtel_money");
});

test("invitation code format", () => {
  assert.equal(normalizeInviteCode("  sv-0a1b2c3d4e5f "), "SV-0A1B2C3D4E5F");
  assert.ok(isInviteCode("SV-0A1B2C3D4E5F"));
  for (const bad of ["SV-0A1B2C3D4E5", "SV-0A1B2C3D4E5FF", "XX-0A1B2C3D4E5F", "SV-0A1B2C3D4E5G", ""]) assert.ok(!isInviteCode(bad), bad);
});

test("validation helpers", () => {
  assert.ok(isEmail("pop@example.rw"));
  assert.ok(!isEmail("pop@") && !isEmail("a b@c.de"));
  assert.ok(passwordProblem("short1"));
  assert.ok(passwordProblem("alllettersss"));
  assert.equal(passwordProblem("Passw0rd!"), null);
});

test("date helpers", () => {
  const now = Date.parse("2026-10-18T10:00:00Z");
  assert.equal(relativeExpiry(now - 1, now), "expired");
  assert.equal(relativeExpiry(now + 5 * 864e5, now), "expires in 5 days");
  assert.equal(daysUntil("2026-10-20", new Date(2026, 9, 18)), 2);
  assert.equal(daysUntil(null), null);
});

test("ussdFor builds the MTN dial string and refuses unknown inputs", async () => {
  const { ussdFor, telHref, prettyPhone } = await import("../js/utils.js");
  assert.equal(ussdFor({ provider: "mtn_momo", kind: "number", account: "0788123456", amount: 5000 }), "*182*1*1*0788123456*5000#");
  assert.equal(ussdFor({ provider: "mtn_momo", kind: "number", account: "0788123456" }), "*182*1*1*0788123456#");
  assert.equal(ussdFor({ provider: "mtn_momo", kind: "code", account: "123456", amount: 2000 }), "*182*8*1*123456*2000#");
  assert.equal(ussdFor({ provider: "airtel_money", kind: "number", account: "0721234567", amount: 1000 }), null);
  assert.equal(ussdFor({ provider: "mtn_momo", kind: "number", account: "07*8", amount: 1000 }), null); // no injection into the dial string
  assert.equal(ussdFor({ provider: "mtn_momo", kind: "number", account: "0788123456", amount: 12.5 }), "*182*1*1*0788123456#");
  assert.equal(telHref("*182*1*1*0788123456*5000#"), "tel:*182*1*1*0788123456*5000%23");
  assert.equal(prettyPhone("0788123456"), "0788 123 456");
});
