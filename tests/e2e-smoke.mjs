// Browser smoke test: runs the REAL app code in headless Chromium against a FAKE Supabase client
// (served in place of the CDN module), so no network, project or credentials are needed.
// It walks every page on desktop + mobile and checks: no console/page errors, no horizontal
// overflow, XSS-safe rendering, and the simulated contribution flow.
//
//   npm i -g playwright   (or any install of `playwright`), then:  node tests/e2e-smoke.mjs
//   SHOTS=/some/dir node tests/e2e-smoke.mjs     -> also saves screenshots
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { execSync } from "node:child_process";
import { extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
async function loadPlaywright() {
  try { return await import("playwright"); } catch { /* fall through to global install */ }
  const g = execSync("npm root -g").toString().trim();
  return createRequire(join(g, "x.js"))("playwright");
}
const { chromium } = await loadPlaywright();

const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml" };
const server = createServer(async (req, res) => {
  try {
    const p = new URL(req.url, "http://x").pathname;
    const file = join(root, p === "/" ? "index.html" : p);
    res.writeHead(200, { "Content-Type": types[extname(file)] ?? "text/plain" }).end(await readFile(file));
  } catch { res.writeHead(404).end(); }
}).listen(0);
const base = `http://localhost:${server.address().port}`;

// ---------------------------------------------------------------------------
// Fake supabase-js module
// ---------------------------------------------------------------------------
const FAKE = `
const U1='11111111-1111-4111-8111-111111111111', U2='22222222-2222-4222-8222-222222222222';
const G1='aaaaaaaa-0000-4000-8000-000000000001', G2='aaaaaaaa-0000-4000-8000-000000000002';
const E1='eeeeeeee-0000-4000-8000-000000000001', E2='eeeeeeee-0000-4000-8000-000000000002';
const now=Date.now(), iso=(d)=>new Date(now-d*3600e3).toISOString();
const db={
  profiles:[{id:U1,display_name:'Pop Mugisha',avatar_path:null},{id:U2,display_name:'Aline Uwase',avatar_path:null}],
  groups:[{user_id:U1,role:'admin',joined_at:iso(500),savings_groups:{id:G1,name:'Kigali Besties',currency:'RWF',created_at:iso(500)}},
          {user_id:U1,role:'member',joined_at:iso(300),savings_groups:{id:G2,name:'<img src=x onerror="window.__xss=1">',currency:'RWF',created_at:iso(300)}}],
  members:[{group_id:G1,user_id:U1,role:'admin',joined_at:iso(500)},{group_id:G1,user_id:U2,role:'member',joined_at:iso(200)},{group_id:G2,user_id:U1,role:'member',joined_at:iso(300)}],
  events:[{id:E1,group_id:G1,name:'Aline & Eric Wedding',target_amount:2000000,event_date:new Date(now+20*864e5).toISOString().slice(0,10),status:'active',created_at:iso(100),pay_provider:'mtn_momo',pay_kind:'number',pay_account:'0788123456',pay_account_name:'Pop Mugisha',expected_per_member:20000},
          {id:E2,group_id:G1,name:'Weekend in Akagera',target_amount:600000,event_date:null,status:'completed',created_at:iso(900)}],
  event_financials:[{event_id:E1,group_id:G1,target_amount:2000000,event_status:'active',paid_total:750000,pending_total:50000,failed_total:10000,refunded_total:0,expenses_total:200000,available_funds:550000,remaining_amount:1250000},
                    {event_id:E2,group_id:G1,target_amount:600000,event_status:'completed',paid_total:600000,pending_total:0,failed_total:0,refunded_total:0,expenses_total:0,available_funds:600000,remaining_amount:0}],
  contributions:[
    {id:'c1',event_id:E1,user_id:U2,amount:150000,status:'paid',payment_method:'mtn_momo',payment_reference:'SV-PAY-1',is_simulated:false,failure_reason:null,paid_at:iso(5),created_at:iso(5),events:{id:E1,name:'Aline & Eric Wedding',group_id:G1}},
    {id:'c2',event_id:E1,user_id:U1,amount:50000,status:'pending',payment_method:'airtel_money',payment_reference:'SV-PAY-AAAAAAAAAAAAAAAAAAAAAAAA',is_simulated:true,failure_reason:null,paid_at:null,created_at:iso(1),events:{id:E1,name:'Aline & Eric Wedding',group_id:G1}},
    {id:'c3',event_id:E1,user_id:U1,amount:10000,status:'failed',payment_method:'mtn_momo',payment_reference:'SV-PAY-3',is_simulated:false,failure_reason:'insufficient funds',paid_at:null,created_at:iso(30),events:{id:E1,name:'Aline & Eric Wedding',group_id:G1}},
    {id:'c4',event_id:E1,user_id:U2,amount:20000,status:'pending',payment_method:'mtn_momo',provider:'manual',provider_ref:'MP2610ABC123',payment_reference:'SV-M-1',is_simulated:false,failure_reason:null,paid_at:null,created_at:iso(2),events:{id:E1,name:'Aline & Eric Wedding',group_id:G1}}],
  expenses:[{id:'x1',event_id:E1,amount:200000,description:'Venue deposit',receipt_path:G1+'/'+E1+'/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.pdf',recorded_by:U1,created_at:iso(20),events:{id:E1,name:'Aline & Eric Wedding',group_id:G1}}],
};
const get=(o,k)=>k.split('.').reduce((a,p)=>a?.[p],o);
function run(st){
  let rows;
  if(st.table==='group_members'){
    if(st.cols.includes('savings_groups')) rows=db.groups;
    else if(st.cols.includes('user_id')) rows=db.members.filter(m=>m.group_id===st.filters.find(f=>f[1]==='group_id')?.[2]);
    else rows=db.members;
  } else rows=db[st.table]||[];
  for(const [op,k,v] of st.filters){ rows=rows.filter(r=> op==='eq'? get(r,k)===v : v.includes(get(r,k))); }
  return {data: st.single ? (rows[0]??null) : rows, error:null};
}
function builder(table){
  const st={table,cols:'',filters:[],single:false};
  const b={select(c){st.cols=c;return b},eq(k,v){st.filters.push(['eq',k,v]);return b},in(k,v){st.filters.push(['in',k,v]);return b},
    order(){return b},limit(){return b},maybeSingle(){st.single=true;return b},then(res,rej){return Promise.resolve(run(st)).then(res,rej)}};
  return b;
}
export function createClient(){
  const subs=[]; let session=null; try{ session=JSON.parse(localStorage.getItem('fake-session')); }catch{}
  return {
    from:builder,
    rpc: async (name,args)=>{ window.__rpc=(window.__rpc||[]).concat([[name,args]]);
      if(name==='collector_status') return {data:{active:true,created_at:iso(48),last_seen_at:iso(1),receipts_30d:4},error:null};
      if(name==='claim_match_hints') return {data:[{contribution_id:'c4',receipt_id:'r1',strength:'id',receipt_amount:20000,payer_hint:'Aline U',received_at:iso(2),txn_id:'MP2610ABC123'}],error:null};
      if(name==='preview_momo_sms') return {data:{is_receipt:/received/i.test(args.p_message),amount:20000,txn_id:'123456789012',payer_hint:'John Doe'},error:null};
      if(name==='create_collector_token') return {data:'SVC-0123456789ABCDEF0123456789ABCDEF',error:null};
      if(name==='submit_payment_claim') return {data:'c-new',error:null};
      if(name==='event_member_progress') return {data:[{user_id:U1,role:'admin',paid_total:0,paid_count:0,pending_total:0,pending_count:0,last_paid_at:null},{user_id:U2,role:'member',paid_total:150000,paid_count:1,pending_total:20000,pending_count:1,last_paid_at:iso(5)}],error:null};
      if(name==='list_invitations') return {data:[{id:'i1',created_by:U1,created_at:iso(24),expires_at:new Date(now+5*864e5).toISOString(),max_uses:10,use_count:3,revoked_at:null,status:'active'}],error:null};
      if(name==='create_invitation_code') return {data:{id:'i2',code:'SV-0123456789AB',expires_at:new Date(now+7*864e5).toISOString(),max_uses:10},error:null};
      if(name==='join_group_with_code') return {data:{ok:false,error:'invalid_code'},error:null};
      if(name==='create_savings_group') return {data:G1,error:null};
      return {data:null,error:null}; },
    functions:{ invoke: async (name,{body})=>{ window.__fn=(window.__fn||[]).concat([[name,body]]);
      if(name==='create-payment') return {data:{mode:'simulated',simulated:true,reference:'SV-PAY-BBBBBBBBBBBBBBBBBBBBBBBB',status:'pending'},error:null};
      return {data:{status: body.simulate==='success'?'paid':'failed'},error:null}; } },
    storage:{from:()=>({createSignedUrl:async()=>({data:{signedUrl:'about:blank#receipt'},error:null}),upload:async()=>({error:null})})},
    auth:{
      getSession: async()=>({data:{session},error:null}),
      onAuthStateChange(cb){ subs.push(cb); setTimeout(()=>cb('INITIAL_SESSION',session),0); return {data:{subscription:{unsubscribe(){}}}}; },
      signInWithPassword: async()=>{ session={user:{id:U1,email:'pop@example.rw'},access_token:'t'}; localStorage.setItem('fake-session',JSON.stringify(session)); subs.forEach(cb=>cb('SIGNED_IN',session)); return {data:{session},error:null}; },
      verifyOtp: async ({token_hash})=>{ if(token_hash==='bad') return {data:{},error:{message:'Token has expired or is invalid'}}; session={user:{id:U1,email:'pop@example.rw'},access_token:'t'}; localStorage.setItem('fake-session',JSON.stringify(session)); subs.forEach(cb=>cb('SIGNED_IN',session)); return {data:{session},error:null}; },
      signUp: async(a)=>{ window.__signup=a; return {data:{session:null},error:null}; }, resetPasswordForEmail: async()=>({error:null}), updateUser: async()=>({error:null}),
      signOut: async()=>{ session=null; localStorage.removeItem('fake-session'); subs.forEach(cb=>cb('SIGNED_OUT',null)); return {error:null}; },
    },
  };
}`;

const G1 = "aaaaaaaa-0000-4000-8000-000000000001";
const E1 = "eeeeeeee-0000-4000-8000-000000000001";
const ROUTES = [
  ["/dashboard", "Pop, let's save."], ["/groups", "My Groups"], [`/groups/${G1}`, "Kigali Besties"], ["/events", "Events"],
  [`/events/${E1}`, "Aline & Eric Wedding"], ["/contributions", "Contributions"], ["/expenses", "Expenses"],
  ["/invitations", "Invitations"], ["/profile", "Profile"], ["/settings", "Settings"],
];

let failures = 0;
const ok = (cond, msg) => { console.log(`${cond ? "PASS" : "FAIL"}  ${msg}`); if (!cond) failures++; };

const browser = await chromium.launch();
async function newPage(viewport) {
  const ctx = await browser.newContext({ viewport });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => { errors.push(`pageerror: ${e.message}`); if (process.env.DEBUG) console.log("  [pageerror]", e.message); });
  page.on("console", (m) => { if (m.type() === "error" && !/Failed to load resource/.test(m.text())) { errors.push(`console: ${m.text()}`); if (process.env.DEBUG) console.log("  [console]", m.text().slice(0, 300)); } });
  await page.route("**/cdn.jsdelivr.net/**", (r) => r.fulfill({ contentType: "text/javascript", body: FAKE }));
  await page.route("**/js/config.js", async (r) => {
    const body = (await readFile(join(root, "js/config.js"), "utf8")).replace('supabasePublishableKey: ""', 'supabasePublishableKey: "sb_publishable_testtesttesttest"');
    r.fulfill({ contentType: "text/javascript", body });
  });
  return { page, errors };
}
const shot = async (page, name) => { if (process.env.SHOTS) await page.screenshot({ path: join(process.env.SHOTS, `${name}.png`) }); };

// ----------------------------- desktop -----------------------------
{
  const { page, errors } = await newPage({ width: 1366, height: 860 });
  const t0 = Date.now();
  await page.goto(base);
  await page.waitForSelector(".auth-card h1");
  ok((await page.textContent(".auth-card h1")).includes("Sign in"), `auth screen renders (${Date.now() - t0} ms to first heading)`);
  await shot(page, "01-auth-desktop");

  await page.fill("#f-email", "bad");
  await page.click('button[type="submit"]');
  ok((await page.textContent("#err-email")).includes("valid email"), "email validation message shows");
  ok((await page.textContent(".auth-panel")).includes("This website was happily made by Tresor"), "auth screen footer credits Tresor");
  await page.click("[data-go=signup]");
  await page.fill("#f-display_name", "Test User");
  await page.fill("#f-email", "t@example.rw");
  await page.fill("#f-password", "Passw0rd!");
  await page.click('button[type="submit"]');
  ok((await page.textContent("#err-agree")).includes("accept the Terms"), "sign-up requires accepting the Terms");
  await shot(page, "08-signup");
  await page.click(".auth-panel [data-terms]");
  await page.waitForSelector(".dialog .terms");
  const tx = await page.textContent(".dialog");
  ok(tx.includes("not a bank") && tx.includes("PIN") && tx.includes("Automatic payment checking"), "Terms dialog opens with the key clauses");
  await page.keyboard.press("Escape");
  await page.check("#f-agree");
  await page.click('button[type="submit"]');
  await page.waitForSelector(".form-msg.ok");
  const su = await page.evaluate(() => window.__signup);
  ok(su.options.data.terms_version && su.options.data.terms_accepted_at && su.options.emailRedirectTo.startsWith("http"), "sign-up records which Terms version was accepted");
  await page.click("[data-go=forgot]").catch(() => {});
  await page.waitForSelector("form[data-form]");
  if (await page.$("[data-go=signin]")) await page.click("[data-go=signin]");
  await page.waitForSelector("#f-password");

  await page.fill("#f-email", "pop@example.rw");
  await page.fill("#f-password", "Passw0rd!");
  await page.click('button[type="submit"]');
  await page.waitForSelector(".app-shell");
  await page.waitForFunction(() => document.querySelector("#outlet h1")?.textContent.includes("let's save"));
  ok(true, "sign in -> dashboard shell");
  await page.waitForTimeout(1300); // let progress bars animate
  await shot(page, "02-dashboard-desktop");

  const dash = await page.textContent("#outlet");
  ok(dash.includes("1,350,000 RWF"), "verified savings sums paid only (750,000 + 600,000 = 1,350,000 RWF; pending/failed excluded)");
  ok(dash.includes("50,000 RWF") && dash.includes("Not counted"), "pending shown separately and labelled not counted");

  for (const [path, text] of ROUTES) {
    await page.evaluate((p) => { location.hash = p; }, path);
    await page.waitForFunction((t) => document.querySelector("#outlet h1")?.textContent.includes(t), text, { timeout: 5000 }).catch(() => {});
    const h1 = (await page.textContent("#outlet h1").catch(() => "")) ?? "";
    ok(h1.includes(text), `route ${path.replace(G1, ":g").replace(E1, ":e")} renders "${text}"`);
    await page.waitForTimeout(150);
  }

  // event detail numbers
  await page.evaluate((p) => { location.hash = p; }, `/events/${E1}`);
  await page.waitForSelector(".progress");
  await page.waitForTimeout(1300);
  const ev = await page.textContent("#outlet");
  ok(ev.includes("750,000 RWF") && ev.includes("1,250,000 RWF remaining") && ev.includes("37%"), "event detail: verified 750,000, remaining 1,250,000, 37%");
  ok(ev.includes("550,000 RWF"), "event detail: available funds = verified - expenses");
  await shot(page, "03-event-desktop");

  // XSS: hostile group name is rendered as text, never executed
  await page.evaluate(() => { location.hash = "/groups"; });
  await page.waitForSelector(".card.link");
  ok(await page.evaluate(() => window.__xss === undefined), "hostile group name did not execute script");
  ok((await page.textContent("#outlet")).includes('<img src=x onerror="window.__xss=1">'), "hostile group name shown literally as text");
  ok(await page.evaluate(() => document.querySelectorAll("#outlet img[src='x']").length === 0), "no injected <img> element in DOM");

  // event detail: how to pay, progress, claims queue (leader view)
  await page.evaluate((p) => { location.hash = p; }, `/events/${E1}`);
  await page.waitForSelector("[data-review]");
  const ed = await page.textContent("#outlet");
  ok(ed.includes("How to pay") && ed.includes("0788 123 456") && ed.includes("Pop Mugisha"), "event page shows the leader's MoMo number and account name");
  ok(ed.includes("1 of 2 paid") && ed.includes("Still to pay (1)") && ed.includes("Paid (1)"), "progress: 1 of 2 members paid, with unpaid/paid lists");
  ok(ed.includes("Waiting for your confirmation") && ed.includes("MP2610ABC123"), "leader sees the pending claim with its transaction ID");
  ok(ed.includes("Matching MoMo message found") && ed.includes("MP2610ABC123"), "leader sees the matching MoMo message for the waiting claim");
  ok((await page.textContent("#main")).includes("This website was happily made by Tresor"), "app footer credits Tresor");
  await page.click("[data-confirm-receipt]");
  await page.click("[data-ok]");
  await page.waitForTimeout(200);
  const cr = await page.evaluate(() => window.__rpc.find((r) => r[0] === "confirm_with_receipt")?.[1]);
  ok(cr?.p_contribution_id === "c4" && cr?.p_receipt_id === "r1", "confirm-with-message sends the claim and the receipt ids");
  await page.click('[data-review="paid"]');
  await page.click("[data-ok]");
  await page.waitForTimeout(200);
  const rv = await page.evaluate(() => window.__rpc.find((r) => r[0] === "review_contribution")?.[1]);
  ok(rv?.p_contribution_id === "c4" && rv?.p_decision === "paid", "confirming sends review_contribution(paid) for that claim");
  await page.click("[data-record]");
  await page.fill("#f-amount", "20,000");
  await page.click('.dialog button[type="submit"]');
  await page.waitForTimeout(200);
  const rec = await page.evaluate(() => window.__rpc.find((r) => r[0] === "record_manual_contribution")?.[1]);
  ok(rec?.p_amount === 20000 && rec?.p_user_id === "11111111-1111-4111-8111-111111111111", "leader can record a payment for an unpaid member");
  // edit dialog validates the MoMo number against the chosen network
  await page.click("[data-edit]");
  await page.fill("#f-pay_account", "0721234567");
  await page.click('.dialog button[type="submit"]');
  ok((await page.textContent("#err-pay_account")).includes("isn't on"), "payment details: Airtel number rejected for MTN");
  await page.fill("#f-pay_account", "07881");
  await page.click('.dialog button[type="submit"]');
  ok((await page.textContent("#err-pay_account")).includes("valid"), "payment details: short number rejected");
  await page.keyboard.press("Escape");

  // member pay flow: instructions, USSD shortcut, PIN notice, "I've paid"
  await page.evaluate(() => { location.hash = "/contributions"; });
  await page.waitForSelector("form[data-claim]");
  const cp = await page.textContent("[data-pay-panel]");
  ok(cp.includes("0788 123 456") && cp.includes("*182*1*1*0788123456*20000#"), "pay page shows the number and the dial string with the member's share");
  await page.fill("#f-amount", "5,000");
  ok((await page.textContent("[data-ussd]")) === "*182*1*1*0788123456*5000#", "dial string follows the amount typed");
  ok((await page.getAttribute("[data-copy-ussd]", "data-copy")) === "*182*1*1*0788123456*5000#", "copy button copies the updated dial string");
  await page.click("[data-dial]");
  const dlg = await page.textContent(".dialog");
  ok(dlg.includes("PIN") && dlg.includes("never sees"), "tapping pay explains the network asks for the PIN on its own screen");
  await page.click(".dialog [data-cancel]");
  await page.fill("#f-amount", "50");
  await page.click('form[data-claim] button[type="submit"]');
  ok((await page.textContent("#err-amount")).includes("Enter between"), "claim rejects an amount below the minimum");
  await page.fill("#f-amount", "5,000");
  await page.fill("#f-txn", "bad id!");
  await page.click('form[data-claim] button[type="submit"]');
  ok((await page.textContent("#err-txn")).includes("6 to 20"), "claim rejects a malformed transaction ID");
  await page.fill("#f-txn", "mp2610xyz999");
  await shot(page, "04-contribute-manual");
  await page.click('form[data-claim] button[type="submit"]');
  await page.waitForSelector("text=Sent to your group leader");
  const claim = await page.evaluate(() => window.__rpc.find((r) => r[0] === "submit_payment_claim")[1]);
  ok(claim.p_amount === 5000 && claim.p_txn_ref === "mp2610xyz999" && !("p_status" in claim) && !("p_user_id" in claim), "claim sends integer amount + txn ref, never a status or user id");

  // group page: leader can add a member by email
  await page.evaluate((p) => { location.hash = p; }, `/groups/${G1}`);
  await page.waitForSelector("[data-add-member]");
  await page.click("[data-add-member]");
  await page.fill("#f-email", "not-an-email");
  await page.click('.dialog button[type="submit"]');
  ok((await page.textContent("#err-email")).includes("valid"), "add member: bad email rejected client-side");
  await page.fill("#f-email", "friend@example.rw");
  await page.click('.dialog button[type="submit"]');
  await page.waitForTimeout(200);
  const am = await page.evaluate(() => window.__rpc.find((r) => r[0] === "add_member_by_email")?.[1]);
  ok(am?.p_email === "friend@example.rw" && am?.p_group_id === G1, "add member calls add_member_by_email");
  ok((await page.$$("[data-remove]")).length >= 1, "leader sees a remove button for other members");
  await page.waitForSelector("[data-autocheck] .card");
  const ac = await page.textContent("[data-autocheck]");
  ok(ac.includes("Automatic payment checking") && ac.includes("Last MoMo message received") && ac.includes("4 payment messages"), "group page shows automatic checking status");
  await page.fill("#sms-test", "You have received 20,000 RWF from John Doe. Financial Transaction Id: 123456789012.");
  await page.click("[data-test]");
  await page.waitForSelector("[data-test-result] .form-msg");
  ok((await page.textContent("[data-test-result]")).includes("123456789012"), "sample SMS check shows amount and transaction ID");
  await page.click("[data-new-token]");
  await page.click("[data-ok]");
  await page.waitForSelector("[data-copy-value][data-secret]");
  await page.locator("[data-autocheck]").scrollIntoViewIfNeeded();
  await shot(page, "07-autocheck");
  ok((await page.textContent("[data-autocheck]")).includes("/rest/v1/rpc/ingest_momo_sms") && (await page.textContent("[data-autocheck]")).includes("SVC-0123456789ABCDEF0123456789ABCDEF"), "new secret and the forwarder settings are shown once");

  // invitations
  await page.evaluate(() => { location.hash = "/invitations"; });
  await page.waitForSelector("[data-gen]");
  await page.click('[data-gen] button[type="submit"]');
  await page.waitForSelector(".code-box");
  ok((await page.textContent(".code-box")).includes("SV-0123456789AB"), "new invitation code shown once in a dialog");
  await page.keyboard.press("Escape");
  ok((await page.textContent("#outlet")).includes("codes are hidden after creation"), "listed invitations never show codes");

  ok(errors.length === 0, `no console/page errors on desktop ${errors.length ? JSON.stringify(errors.slice(0, 3)) : ""}`);

  await page.click("[data-signout]");
  await page.waitForSelector('form[data-form="signin"]');
  ok(true, "sign out returns to sign-in");
  await page.context().close();
}

// ----------------------------- mobile -----------------------------
{
  const { page, errors } = await newPage({ width: 390, height: 844 });
  await page.addInitScript(() => localStorage.setItem("fake-session", JSON.stringify({ user: { id: "11111111-1111-4111-8111-111111111111", email: "pop@example.rw" }, access_token: "t" })));
  await page.goto(base);
  await page.waitForSelector(".app-shell");
  await page.waitForFunction(() => document.querySelector("#outlet h1")?.textContent.includes("let's save"));
  await page.waitForTimeout(1300);
  await shot(page, "05-dashboard-mobile");
  ok(await page.isVisible(".bottom-nav") && !(await page.isVisible(".sidebar")), "mobile: bottom nav visible, sidebar hidden");
  for (const [path] of ROUTES) {
    await page.evaluate((p) => { location.hash = p; }, path);
    await page.waitForTimeout(350);
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    ok(overflow <= 0, `mobile: no horizontal overflow on ${path.replace(G1, ":g").replace(E1, ":e")} (${overflow}px)`);
  }
  await page.evaluate((p) => { location.hash = p; }, `/events/${E1}`);
  await page.waitForTimeout(1400);
  await shot(page, "06-event-mobile");
  await page.click("[data-more]");
  ok(await page.isVisible(".sheet"), "mobile: More sheet opens");
  ok(errors.length === 0, `no console/page errors on mobile ${errors.length ? JSON.stringify(errors.slice(0, 3)) : ""}`);
  await page.context().close();
}

// ----------------------------- email links -----------------------------
{
  const { page, errors } = await newPage({ width: 420, height: 800 });
  await page.goto(`${base}/?token_hash=goodtoken&type=recovery`);
  await page.waitForSelector("form[data-form=recovery]");
  ok(true, "reset link (token_hash) opens the new-password form, even without a prior session in this browser");
  ok(!(await page.evaluate(() => location.search)), "token is removed from the address bar");
  ok(errors.length === 0, `no errors on reset link ${JSON.stringify(errors.slice(0, 2))}`);
  await page.context().close();
}
{
  const { page } = await newPage({ width: 420, height: 800 });
  await page.goto(`${base}/?token_hash=bad&type=recovery`);
  await page.waitForSelector(".form-msg.warn");
  ok((await page.textContent(".auth-card")).includes("expired") && (await page.$("form[data-form=forgot]")) !== null, "expired reset link shows a clear message and the request-new-link form");
  await page.context().close();
}
{
  const { page } = await newPage({ width: 420, height: 800 });
  await page.goto(`${base}/?token_hash=goodtoken&type=signup`);
  await page.waitForSelector(".app-shell");
  ok(true, "confirm-email link signs the person in");
  await page.context().close();
}
{
  const { page } = await newPage({ width: 420, height: 800 });
  await page.goto(`${base}/?code=abc123`);
  await page.waitForSelector(".form-msg.warn");
  ok((await page.textContent(".auth-card")).includes("same browser"), "old-style link opened in the wrong browser explains what to do");
  await page.context().close();
}

await browser.close();
server.close();
console.log(failures ? `\n${failures} CHECK(S) FAILED` : "\nALL SMOKE CHECKS PASSED");
process.exit(failures ? 1 : 0);
