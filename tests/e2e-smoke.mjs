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
const E1='eeeeeeee-0000-4000-8000-000000000001', E2='eeeeeeee-0000-4000-8000-000000000002', E3='eeeeeeee-0000-4000-8000-000000000003';
const now=Date.now(), iso=(d)=>new Date(now-d*3600e3).toISOString();
const db={
  profiles:[{id:U1,display_name:'Pop Mugisha',avatar_path:null,email_verified_at:iso(100)},{id:U2,display_name:'Aline Uwase',avatar_path:null}],
  groups:[{user_id:U1,role:'admin',joined_at:iso(500),savings_groups:{id:G1,name:'Kigali Besties',currency:'RWF',created_at:iso(500)}},
          {user_id:U1,role:'member',joined_at:iso(300),savings_groups:{id:G2,name:'<img src=x onerror="window.__xss=1">',currency:'RWF',created_at:iso(300)}}],
  members:[{group_id:G1,user_id:U1,role:'admin',joined_at:iso(500)},{group_id:G1,user_id:U2,role:'member',joined_at:iso(200)},{group_id:G2,user_id:U1,role:'member',joined_at:iso(300)}],
  events:[{id:E1,group_id:G1,name:'Aline & Eric Wedding',target_amount:2000000,event_date:new Date(now+20*864e5).toISOString().slice(0,10),status:'active',created_at:iso(100),pay_provider:'mtn_momo',pay_kind:'number',pay_account:'0788123456',pay_account_name:'Pop Mugisha',expected_per_member:20000},
          {id:E2,group_id:G1,name:'Weekend in Akagera',target_amount:600000,event_date:null,status:'completed',created_at:iso(900)},
          {id:E3,group_id:G1,name:'Cancelled Picnic',target_amount:100000,event_date:null,status:'cancelled',created_at:iso(700),cover_path:G1+'/'+U1+'/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.jpg'}],
  event_financials:[{event_id:E1,group_id:G1,target_amount:2000000,event_status:'active',paid_total:750000,pending_total:50000,failed_total:10000,refunded_total:0,expenses_total:200000,available_funds:550000,remaining_amount:1250000},
                    {event_id:E2,group_id:G1,target_amount:600000,event_status:'completed',paid_total:600000,pending_total:0,failed_total:0,refunded_total:0,expenses_total:0,available_funds:600000,remaining_amount:0},
                    {event_id:E3,group_id:G1,target_amount:100000,event_status:'cancelled',paid_total:40000,pending_total:0,failed_total:0,refunded_total:0,expenses_total:0,available_funds:40000,remaining_amount:60000}],
  group_messages:[{id:'m1',group_id:G1,user_id:U2,body:'Hello <b>squad</b>',created_at:iso(1)},{id:'m2',group_id:G1,user_id:U1,body:'Welcome!',created_at:iso(0.5)}],
  contributions:[
    {id:'c1',event_id:E1,user_id:U2,amount:150000,status:'paid',payment_method:'mtn_momo',payment_reference:'SV-PAY-1',is_simulated:false,failure_reason:null,paid_at:iso(5),created_at:iso(5),events:{id:E1,name:'Aline & Eric Wedding',group_id:G1}},
    {id:'c2',event_id:E1,user_id:U1,amount:50000,status:'pending',payment_method:'airtel_money',payment_reference:'SV-PAY-AAAAAAAAAAAAAAAAAAAAAAAA',is_simulated:true,failure_reason:null,paid_at:null,created_at:iso(1),events:{id:E1,name:'Aline & Eric Wedding',group_id:G1}},
    {id:'c3',event_id:E1,user_id:U1,amount:10000,status:'failed',payment_method:'mtn_momo',payment_reference:'SV-PAY-3',is_simulated:false,failure_reason:'insufficient funds',paid_at:null,created_at:iso(30),events:{id:E1,name:'Aline & Eric Wedding',group_id:G1}},
    {id:'c4',event_id:E1,user_id:U2,amount:20000,status:'pending',payment_method:'mtn_momo',provider:'manual',provider_ref:'MP2610ABC123',sender_name:'Aline Uwase',payment_reference:'SV-M-1',is_simulated:false,failure_reason:null,paid_at:null,created_at:iso(2),events:{id:E1,name:'Aline & Eric Wedding',group_id:G1}},
    {id:'c5',event_id:E3,user_id:U2,amount:30000,status:'paid',payment_method:'mtn_momo',provider:'manual',provider_ref:'MP2610PAID01',sender_name:'Aline Uwase',payment_reference:'SV-M-5',is_simulated:false,failure_reason:null,paid_at:iso(60),created_at:iso(61),events:{id:E3,name:'Cancelled Picnic',group_id:G1}},
    {id:'c6',event_id:E3,user_id:U1,amount:10000,status:'paid',payment_method:'mtn_momo',provider:'manual',payment_reference:'SV-M-6',is_simulated:false,failure_reason:null,paid_at:iso(59),created_at:iso(60),events:{id:E3,name:'Cancelled Picnic',group_id:G1}}],
  _more:0,
  expenses:[{id:'x1',event_id:E1,amount:200000,description:'Venue deposit',receipt_path:G1+'/'+E1+'/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.pdf',recorded_by:U1,created_at:iso(20),events:{id:E1,name:'Aline & Eric Wedding',group_id:G1}}],
};
window.__db=db;
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
      if(name==='collector_status') return {data:{active:!window.__free,created_at:iso(48),last_seen_at:iso(1),receipts_30d:4,auto_by_name:true},error:null};
      if(name==='claim_match_hints') return {data:[{contribution_id:'c4',receipt_id:'r1',strength:'id',receipt_amount:20000,payer_hint:'Aline U',received_at:iso(2),txn_id:'MP2610ABC123',name_score:100}],error:null};
      if(name==='preview_momo_sms') return {data:{is_receipt:/received/i.test(args.p_message),amount:20000,txn_id:'123456789012',payer_hint:'John Doe'},error:null};
      if(name==='create_collector_token') return {data:'SVC-0123456789ABCDEF0123456789ABCDEF',error:null};
      if(name==='submit_payment_claim') return {data:'c-new',error:null};
      if(name==='event_member_progress') return {data:[{user_id:U1,role:'admin',paid_total:0,paid_count:0,pending_total:0,pending_count:0,last_paid_at:null},{user_id:U2,role:'member',paid_total:150000,paid_count:1,pending_total:20000,pending_count:1,last_paid_at:iso(5)}],error:null};
      if(name==='list_invitations') return {data:[{id:'i1',created_by:U1,created_at:iso(24),expires_at:new Date(now+5*864e5).toISOString(),max_uses:10,use_count:3,revoked_at:null,status:'active',code:'SV-AABBCCDDEEFF'},{id:'i0',created_by:U1,created_at:iso(240),expires_at:new Date(now+2*864e5).toISOString(),max_uses:10,use_count:1,revoked_at:null,status:'active',code:null}],error:null};
      if(name==='list_group_photos') return {data:[{id:'p1',user_id:U2,path:G1+'/'+U2+'/cccccccc-cccc-4ccc-8ccc-cccccccccccc.jpg',caption:'Planning night',event_id:null,created_at:iso(3),like_count:2,liked_by_me:false}],error:null};
      if(name==='toggle_photo_like') return {data:{liked:true,count:3},error:null};
      if(name==='list_games') return {data:[
        {id:'gm1',kind:'poll',title:'Where do we celebrate?',options:['Kigali','Musanze'],status:'open',answer:null,created_by:U2,created_at:iso(2),entries:3,my_choice:null,my_guess:null,counts:[2,1],top:null},
        {id:'gm2',kind:'guess',title:'How much by Friday?',options:null,status:'open',answer:null,created_by:U1,created_at:iso(1),entries:2,my_choice:null,my_guess:480000,counts:null,top:null},
        {id:'gm3',kind:'guess',title:'Guests who come?',options:null,status:'closed',answer:120,created_by:U2,created_at:iso(30),entries:2,my_choice:null,my_guess:100,counts:null,top:[{user_id:U2,guess:118,diff:2},{user_id:U1,guess:100,diff:20}]}],error:null};
      if(name==='list_rooms') return {data:{rooms:[{id:'rm1',kind:'trivia',status:'lobby',host_id:U2,winner_id:null,created_at:iso(1),max_players:12,abandoned:false,in_room:false,players:[{user_id:U2,seat:0,score:0,name:'Aline <b>U</b>'}]}],leaderboard:[{user_id:U2,name:'Aline U',wins:3,played:5},{user_id:U1,name:'Pop Mugisha',wins:1,played:2}]},error:null};
      if(name==='create_room') { window.__room={id:'rmNew',kind:args.p_kind,status:'lobby',host_id:U1,winner_id:null,max_players:2,state:{},me_seat:0,in_room:true,my_answer:null,my_choice:null,players:[{user_id:U1,seat:0,score:0,name:'Pop Mugisha',avatar_path:null}]}; return {data:'rmNew',error:null}; }
      if(name==='get_room') return window.__room ? {data:{...window.__room,server_now:new Date().toISOString()},error:null} : {data:null,error:{message:'not_allowed',code:'42501'}};
      if(['make_move','start_room','join_room','leave_room','delete_room'].includes(name)) return {data:null,error:null};
      if(name==='add_group_photo') return {data:'p-new',error:null};
      if(name==='plan_overview') { const free=!!window.__free; return {data:{plan:free?'free':'plus',plan_name:free?'Free':'Plus',booked_plan:free?'free':'plus',until:free?null:new Date(now+20*864e5).toISOString(),expired:false,
        limits:{members:free?15:150,events:free?2:null,photos:free?30:500,auto_check:!free},usage:{members:2,events:1,photos:1},is_admin:true,pending:window.__pend||null,last_rejected:null,
        plans:[{code:'free',name:'Free',members:15,events:2,photos:30,auto_check:false,price_month:0,price_year:0},{code:'plus',name:'Plus',members:150,events:null,photos:500,auto_check:true,price_month:2000,price_year:20000},{code:'pro',name:'Pro',members:1000,events:null,photos:5000,auto_check:true,price_month:10000,price_year:100000}]},error:null}; }
      if(name==='request_plan_upgrade') { window.__pend={id:'rq1',plan:args.p_plan,period:args.p_period,amount:args.p_period==='year'?20000:2000,txn_ref:args.p_txn_ref.toUpperCase(),created_at:iso(0)}; return {data:'rq1',error:null}; }
      if(name==='owner_summary') return {data:{is_owner:true,pending:1},error:null};
      if(name==='owner_list_plan_requests') return {data:[{id:'rq9',group_id:G1,group_name:'Kigali Besties',plan:'plus',period:'year',amount:20000,txn_ref:'MP26PLUS001',status:'pending',created_at:iso(2),requester_name:'Pop Mugisha',requester_email:'pop@example.rw',reviewed_at:null,note:null}],error:null};
      if(name==='create_invitation_code') return {data:{id:'i2',code:'SV-0123456789AB',expires_at:new Date(now+7*864e5).toISOString(),max_uses:10},error:null};
      if(name==='join_group_with_code') return {data:{ok:false,error:'invalid_code'},error:null};
      if(name==='create_savings_group') return {data:G1,error:null};
      return {data:null,error:null}; },
    functions:{ invoke: async (name,{body})=>{ window.__fn=(window.__fn||[]).concat([[name,body]]);
      if(name==='create-payment') return {data:{mode:'simulated',simulated:true,reference:'SV-PAY-BBBBBBBBBBBBBBBBBBBBBBBB',status:'pending'},error:null};
      return {data:{status: body.simulate==='success'?'paid':'failed'},error:null}; } },
    storage:{from:(bucket)=>({createSignedUrl:async()=>({data:{signedUrl:'about:blank#receipt'},error:null}),
      upload:async(path)=>{ window.__uploads=(window.__uploads||[]).concat([[bucket,path]]); return {error:null}; },
      createSignedUrls:async(paths)=>({data:paths.map(p=>({path:p,signedUrl:'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7'})),error:null}),
      remove:async()=>({data:[],error:null})})},
    auth:{
      getSession: async()=>({data:{session},error:null}),
      onAuthStateChange(cb){ subs.push(cb); setTimeout(()=>cb('INITIAL_SESSION',session),0); return {data:{subscription:{unsubscribe(){}}}}; },
      signInWithPassword: async()=>{ session={user:{id:U1,email:'pop@example.rw'},access_token:'t'}; localStorage.setItem('fake-session',JSON.stringify(session)); subs.forEach(cb=>cb('SIGNED_IN',session)); return {data:{session},error:null}; },
      verifyOtp: async ({token_hash})=>{ if(token_hash==='bad') return {data:{},error:{message:'Token has expired or is invalid'}}; session={user:{id:U1,email:'pop@example.rw'},access_token:'t'}; localStorage.setItem('fake-session',JSON.stringify(session)); subs.forEach(cb=>cb('SIGNED_IN',session)); return {data:{session},error:null}; },
      signUp: async(a)=>{ window.__signup=a;
        if(a.email==='exists@example.rw') return {data:{session:null,user:{id:'x',identities:[]}},error:null};
        if(a.email==='busy@example.rw') return {data:{session:null},error:{code:'over_email_send_rate_limit',status:429,message:'email rate limit exceeded'}};
        return {data:{session:null,user:{id:'x',identities:[{id:'i'}]}},error:null}; },
      signInWithOtp: async(a)=>{ window.__otp=a; return {error:null}; },
      resend: async(a)=>{ window.__resend=a; return {error:null}; }, resetPasswordForEmail: async()=>({error:null}), updateUser: async()=>({error:null}),
      signOut: async()=>{ session=null; localStorage.removeItem('fake-session'); subs.forEach(cb=>cb('SIGNED_OUT',null)); return {error:null}; },
    },
  };
}`;

const G1 = "aaaaaaaa-0000-4000-8000-000000000001";
const E1 = "eeeeeeee-0000-4000-8000-000000000001";
const E3 = "eeeeeeee-0000-4000-8000-000000000003";
const ROUTES = [
  ["/dashboard", "Pop, let's save."], ["/groups", "My Groups"], [`/groups/${G1}`, "Kigali Besties"], ["/events", "Events"],
  [`/events/${E1}`, "Aline & Eric Wedding"], ["/contributions", "Contributions"], ["/expenses", "Expenses"],
  ["/invitations", "Invitations"], ["/squad", "Squad"], ["/owner", "Owner"], ["/profile", "Profile"], ["/settings", "Settings"],
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
    const body = (await readFile(join(root, "js/config.js"), "utf8")).replace('supabasePublishableKey: ""', 'supabasePublishableKey: "sb_publishable_testtesttesttest"').replace('momoNumber: ""', 'momoNumber: "0788000000"');
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
  // an already-registered email must not pretend an email was sent
  await page.click("[data-go=signin]").catch(() => {});
  await page.click("[data-go=signup]");
  await page.fill("#f-display_name", "Dup");
  await page.fill("#f-email", "exists@example.rw");
  await page.fill("#f-password", "Passw0rd!");
  await page.check("#f-agree");
  await page.click('button[type="submit"]');
  await page.waitForSelector(".form-msg.warn");
  ok((await page.textContent(".auth-card")).includes("already has a SquadVault account") && (await page.inputValue("#f-email")) === "exists@example.rw", "existing email: told plainly, address kept, no fake 'check your inbox'");
  // email service busy: a clear message, a cooldown, and an account-may-exist hint
  await page.click("[data-go=signup]");
  await page.fill("#f-display_name", "Busy");
  await page.fill("#f-email", "busy@example.rw");
  await page.fill("#f-password", "Passw0rd!");
  await page.check("#f-agree");
  await page.click('button[type="submit"]');
  await page.waitForSelector(".form-msg.error");
  ok((await page.textContent(".form-msg.error")).includes("email service is busy"), "email-limit error explains the service is busy, not that the person did something wrong");
  await page.click('button[type="submit"]');
  ok((await page.textContent("[data-msg]")).includes("Please wait"), "a second tap during the cooldown doesn't hit the service again");
  await page.click("[data-go=signin]");
  await page.fill("#f-email", "t@example.rw");
  await page.fill("#f-password", "x");
  await page.click("[data-go=signup]");
  await page.fill("#f-display_name", "Fresh");
  await page.fill("#f-email", "fresh@example.rw");
  await page.fill("#f-password", "Passw0rd!");
  await page.check("#f-agree");
  await page.evaluate(() => { window.__t0 = true; });
  await page.click("[data-go=signin]");
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
  ok(dash.includes("1,390,000 RWF"), "verified savings sums paid only (750,000 + 600,000 + 40,000 = 1,390,000 RWF; pending/failed excluded)");
  ok(dash.includes("A cancelled event still holds money") && dash.includes("Cancelled Picnic"), "dashboard alerts the leader to a cancelled event that still holds money");
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
  ok((await page.inputValue("#f-sender")) === "Pop Mugisha", "claim form asks for the MoMo name, pre-filled with the profile name");
  await page.fill("#f-sender", "Pop M.");
  await page.fill("#f-txn", "mp2610xyz999");
  await shot(page, "04-contribute-manual");
  await page.click('form[data-claim] button[type="submit"]');
  await page.waitForSelector("text=Sent to your group leader");
  const claim = await page.evaluate(() => window.__rpc.find((r) => r[0] === "submit_payment_claim")[1]);
  ok(claim.p_amount === 5000 && claim.p_txn_ref === "mp2610xyz999" && claim.p_sender_name === "Pop M." && !("p_status" in claim) && !("p_user_id" in claim), "claim sends integer amount, txn ref and MoMo name, never a status or user id");

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

  // plans: usage, upgrade request, locked feature on Free
  await page.waitForSelector("[data-plan] .card");
  const pl = await page.textContent("[data-plan]");
  ok(pl.includes("Plus plan") && pl.includes("Active until") && pl.includes("Members") && pl.includes("2 of 150"), "group page shows the plan, its end date and usage against the limits");
  await page.click("[data-upgrade]");
  await page.waitForSelector(".dialog [data-amount]");
  ok((await page.textContent(".dialog")).includes("0788000000") && (await page.textContent("[data-amount]")).includes("2,000"), "upgrade dialog shows the owner's MoMo number and the monthly price");
  await page.check('input[name="period"][value="year"]');
  ok((await page.textContent("[data-amount]")).includes("20,000"), "yearly choice updates the amount");
  await page.click('.dialog button[type="submit"]');
  ok((await page.textContent("#err-txn")).includes("6 to 20"), "upgrade needs a transaction ID");
  await page.fill("#f-txn", "mp26plus001");
  await page.click('.dialog button[type="submit"]');
  await page.waitForSelector("[data-cancel-req]");
  const up2 = await page.evaluate(() => window.__rpc.find((r) => r[0] === "request_plan_upgrade")?.[1]);
  ok(up2?.p_plan === "plus" && up2?.p_period === "year" && up2?.p_txn_ref === "mp26plus001" && !("p_amount" in up2), "request sends plan, period and ID only. The price is decided by the server");
  ok((await page.textContent("[data-plan]")).includes("waiting for approval"), "pending request is shown to the group admin");
  await page.evaluate(() => { window.__free = true; window.__pend = null; location.hash = "/dashboard"; });
  await page.waitForSelector("#outlet h1");
  await page.evaluate((p) => { location.hash = p; }, `/groups/${G1}`);
  await page.waitForSelector("[data-go-upgrade]");
  ok((await page.textContent("[data-autocheck]")).includes("Included in the Plus and Pro plans"), "automatic checking shows as a locked Plus feature on the Free plan");
  await page.evaluate(() => { window.__free = false; });

  // owner: approve upgrade requests
  await page.evaluate(() => { location.hash = "/owner"; });
  await page.waitForSelector("[data-ok]");
  const ow = await page.textContent("#outlet");
  ok(ow.includes("Kigali Besties") && ow.includes("MP26PLUS001") && ow.includes("pop@example.rw"), "owner sees the request with the group, payment ID and who asked");
  await page.click("[data-ok]");
  await page.click(".dialog [data-ok]");
  await page.waitForTimeout(250);
  ok(await page.evaluate(() => window.__rpc.some((r) => r[0] === "owner_decide_plan_request" && r[1].p_approve === true && r[1].p_request_id === "rq9")), "approving calls owner_decide_plan_request");

  // invitations: the active code stays visible, so nobody has to generate extra codes
  await page.evaluate(() => { location.hash = "/invitations"; });
  await page.waitForSelector(".code-box");
  ok((await page.textContent(".code-box")).includes("SV-AABBCCDDEEFF"), "the current invitation code is shown again without generating a new one");
  ok((await page.textContent("#outlet")).includes("made before codes could be viewed"), "older codes that can't be shown are explained");
  ok((await page.getAttribute("[data-wa]", "href")).includes("wa.me") , "share-on-WhatsApp link is offered");
  await page.click("details.more summary");
  await page.click('[data-gen] button[type="submit"]');
  await page.waitForTimeout(250);
  ok(await page.evaluate(() => window.__rpc.some((r) => r[0] === "create_invitation_code")), "a new code is only made when the leader asks for one");

  // squad hub: chat, photos, games
  await page.evaluate(() => { location.hash = "/squad"; });
  await page.waitForSelector(".chat .msg");
  const chat = await page.textContent(".chat-log");
  ok(chat.includes("Hello <b>squad</b>") && chat.includes("Welcome!"), "chat shows messages as plain text (no HTML injection)");
  await page.fill("#chat-body", "See you at the party");
  await page.press("#chat-body", "Enter");
  await page.waitForTimeout(300);
  ok(await page.evaluate(() => window.__rpc.some((r) => r[0] === "post_group_message" && r[1].p_body === "See you at the party" && r[1].p_group_id)), "pressing Enter sends the message through post_group_message");
  await shot(page, "09-chat");
  // unconfirmed email: chat and photos are read-only until the person confirms
  await page.evaluate(() => { window.__db.profiles[0].email_verified_at = null; });
  await page.evaluate(() => { location.hash = "/squad?tab=chat&x=1"; });
  await page.waitForSelector("[data-verify-banner]");
  ok(await page.isDisabled("#chat-body") && (await page.textContent(".chat-log")).includes("Welcome!"), "unconfirmed email: chat can be read but not written");
  await page.click("[data-verify]");
  await page.waitForTimeout(200);
  const otp = await page.evaluate(() => window.__otp);
  ok(otp?.email === "pop@example.rw" && otp.options.shouldCreateUser === false && otp.options.emailRedirectTo.startsWith("http"), "confirmation email is a one-time link to the person's own address and never creates accounts");
  await page.click("[data-verify]");
  await page.waitForTimeout(150);
  ok((await page.textContent("body")).includes("Please wait"), "asking again straight away is paused, so the email limit isn't hit");
  await page.evaluate(() => { location.hash = "/squad?tab=photos&x=2"; });
  await page.waitForSelector("[data-verify-banner]");
  ok((await page.$("#photo-file")) === null, "unconfirmed email: no photo upload button");
  await page.evaluate(() => { window.__db.profiles[0].email_verified_at = new Date().toISOString(); location.hash = "/squad?tab=chat&x=3"; });
  await page.waitForSelector("#chat-body:not([disabled])");
  ok(true, "once confirmed, the chat box unlocks");
  await page.click('[data-tab="photos"]');
  await page.waitForSelector(".photo-grid");
  await page.waitForFunction(() => document.querySelector(".ph-img img")?.getAttribute("src")?.startsWith("data:"));
  ok(true, "photo wall loads pictures through signed URLs");
  await page.click("[data-like]");
  await page.waitForTimeout(150);
  ok((await page.textContent("[data-like]")).trim() === "3" && (await page.getAttribute("[data-like]", "aria-pressed")) === "true", "heart toggles and shows the new count");
  const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==", "base64");
  await page.setInputFiles("#photo-file", { name: "a.png", mimeType: "image/png", buffer: png });
  await page.waitForSelector(".upload-preview");
  await page.fill("#f-caption", "Fun times");
  await page.click('.dialog button[type="submit"]');
  await page.waitForTimeout(500);
  const up = await page.evaluate(() => ({ u: window.__uploads, r: window.__rpc.find((r) => r[0] === "add_group_photo")?.[1] }));
  ok(up.u?.[0]?.[0] === "group-photos" && /^[0-9a-f-]{36}\/[0-9a-f-]{36}\/[0-9a-f-]{36}\.(jpg|png)$/.test(up.u[0][1]) && up.r?.p_caption === "Fun times", "photo upload goes to <group>/<me>/<file> in the private bucket, then is registered");
  await page.click('[data-tab="games"]');
  await page.waitForSelector(".opt");
  const games = await page.textContent("#outlet");
  ok(games.includes("Where do we celebrate?") && games.includes("2 · 67%") && games.includes("Your guess"), "games: poll results and a guess box are shown");
  ok(games.includes("The answer was") && games.includes("off by 2") && games.includes("Exact!") === false, "games: a revealed guess game shows the answer and the closest guess");
  await page.click('[data-vote="2"]');
  await page.waitForTimeout(200);
  ok(await page.evaluate(() => window.__rpc.some((r) => r[0] === "play_game" && r[1].p_choice === 2 && r[1].p_game_id === "gm1")), "voting calls play_game with the chosen option");
  await page.fill('form[data-guess="gm2"] input', "5x");
  await page.click('form[data-guess="gm2"] button[type="submit"]');
  ok((await page.textContent("#err-guess")).includes("whole number"), "a guess must be a whole number");
  await page.click("[data-new-game]");
  await page.fill("#f-title", "Ok?");
  await page.fill("#f-options", "only one");
  await page.click('.dialog button[type="submit"]');
  ok((await page.textContent("#err-options")).includes("between 2 and 6"), "a poll needs 2 to 6 options");
  await page.fill("#f-options", "Yes\nNo");
  await page.click('.dialog button[type="submit"]');
  await page.waitForTimeout(250);
  ok(await page.evaluate(() => window.__rpc.some((r) => r[0] === "create_game" && r[1].p_kind === "poll" && r[1].p_options?.length === 2)), "creating a poll calls create_game");
  await page.click('[data-close="gm2"]');
  await page.fill("#f-answer", "500,000");
  await page.click('.dialog button[type="submit"]');
  await page.waitForTimeout(250);
  ok(await page.evaluate(() => window.__rpc.some((r) => r[0] === "close_game" && r[1].p_answer === 500000)), "revealing a guess game sends the real answer");


  // live games: lobby, boards, hidden answers, win screen
  await page.evaluate(() => { location.hash = "/squad?tab=play&y=1"; });
  await page.waitForSelector(".game-grid");
  const play = await page.textContent("#outlet");
  ok(["Tic-Tac-Toe", "Connect 4", "Rock Paper Scissors", "Trivia Race"].every((n) => play.includes(n)), "play: all four games can be hosted");
  ok(play.includes("Open tables") && play.includes("Aline <b>U</b>") && (await page.$('[data-join="rm1"]')) !== null, "play: an open table shows with a Join button, names as plain text");
  ok(play.includes("Squad leaderboard") && play.includes("Aline U"), "play: leaderboard is shown");
  if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}/play-lobby.png` });
  const U1 = "11111111-1111-4111-8111-111111111111", U2 = "22222222-2222-4222-8222-222222222222";
  const mk = (o) => ({ id: "rmNew", kind: "tictactoe", status: "lobby", host_id: U1, winner_id: null, max_players: 2, state: {}, me_seat: 0, in_room: true, my_answer: null, my_choice: null,
    players: [{ user_id: U1, seat: 0, score: 0, name: "Pop Mugisha", avatar_path: null }, { user_id: U2, seat: 1, score: 0, name: "Aline <b>U</b>", avatar_path: null }], ...o });
  await page.click('[data-host="tictactoe"]');
  await page.waitForSelector("[data-start]");
  ok(await page.evaluate(() => window.__rpc.some((r) => r[0] === "create_room" && r[1].p_kind === "tictactoe")) && (await page.isDisabled("[data-start]")), "hosting opens a lobby; Start waits for a second player");
  await page.evaluate((r) => { window.__room = r; }, mk({ status: "playing", state: { board: ".........", turn: 0 } }));
  await page.waitForSelector(".ttt .cell:not([disabled])", { timeout: 4000 });
  ok(((await page.textContent("[data-stage]")).includes("Your turn")), "tic-tac-toe: it says when it is your turn");
  if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}/play-ttt.png` });
  await page.click('.ttt [data-move="4"]');
  await page.waitForTimeout(250);
  ok(await page.evaluate(() => window.__rpc.some((r) => r[0] === "make_move" && r[1].p_move === 4 && r[1].p_room_id === "rmNew")), "tic-tac-toe: tapping a square sends the move");
  await page.evaluate((r) => { window.__room = r; }, mk({ status: "playing", state: { board: "....X....", turn: 1 } }));
  await page.waitForFunction(() => document.querySelectorAll(".ttt .cell:not([disabled])").length === 0, null, { timeout: 4000 });
  ok((await page.textContent("[data-stage]")).includes("Waiting for Aline <b>U</b>"), "tic-tac-toe: squares lock while it is the other player's turn");
  await page.evaluate((r) => { window.__room = r; }, mk({ kind: "connect4", status: "playing", state: { board: ".".repeat(42), turn: 0 } }));
  await page.waitForSelector(".c4col:not([disabled])", { timeout: 4000 });
  ok((await page.$$(".c4col")).length === 7 && (await page.$$(".disc")).length === 42, "connect 4: seven columns, forty-two discs");
  if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}/play-c4.png` });
  await page.click('.c4col[data-move="3"]');
  await page.waitForTimeout(250);
  ok(await page.evaluate(() => window.__rpc.some((r) => r[0] === "make_move" && r[1].p_move === 3)), "connect 4: tapping a column drops a disc there");
  await page.evaluate((r) => { window.__room = r; }, mk({ kind: "rps", status: "playing", my_choice: 2, state: { round: 2, wins: [1, 0], target: 2, moved: [0], last: { c: [1, 3], result: 0 } } }));
  await page.waitForSelector(".rps-row", { timeout: 4000 });
  const rps = await page.textContent("[data-stage]");
  ok(rps.includes("You picked Paper") && rps.includes("You won that round") && (await page.$$(".rps-btn:not([disabled])")).length === 0, "rock-paper-scissors: your hidden pick is locked and the last round is explained");
  if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}/play-rps.png` });
  await page.evaluate((r) => { window.__room = r; }, mk({ kind: "trivia", status: "playing", max_players: 12, state: { q: 0, total: 8, phase: "question", topic: "Rwanda", question: "Capital of Rwanda?", options: ["Huye", "Musanze", "Kigali", "Rubavu"], until: new Date(Date.now() + 12000).toISOString(), answered: [U2] } }));
  await page.waitForSelector(".quiz-q", { timeout: 4000 });
  const tq = await page.textContent("[data-stage]");
  ok(tq.includes("Question 1 of 8") && tq.includes("1 of 2 answered") && (await page.$$(".opt.right")).length === 0, "trivia: question, answer count and no hint about the right answer");
  if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}/play-trivia.png` });
  await page.click('.opt[data-move="2"]');
  await page.waitForTimeout(250);
  ok(await page.evaluate(() => window.__rpc.some((r) => r[0] === "make_move" && r[1].p_move === 2)), "trivia: tapping an option sends the answer");
  await page.evaluate((r) => { window.__room = r; }, mk({ kind: "trivia", status: "playing", max_players: 12, state: { q: 0, total: 8, phase: "reveal", topic: "Rwanda", question: "Capital of Rwanda?", options: ["Huye", "Musanze", "Kigali", "Rubavu"], correct: 2, results: [{ user_id: U1, choice: 2, points: 142 }, { user_id: U2, choice: 0, points: 0 }], until: new Date(Date.now() + 4000).toISOString(), answered: [U1, U2] }, players: [{ user_id: U1, seat: 0, score: 142, name: "Pop Mugisha" }, { user_id: U2, seat: 1, score: 0, name: "Aline <b>U</b>" }] }));
  await page.waitForSelector(".opt.right", { timeout: 4000 });
  ok((await page.textContent("[data-stage]")).includes("+142 points"), "trivia: the reveal shows the right answer and your points");
  await page.evaluate((r) => { window.__room = r; }, mk({ status: "finished", winner_id: U1, state: { board: "XXXOO....", turn: 0, line: [0, 1, 2] } }));
  await page.waitForSelector(".win-banner", { timeout: 4000 });
  ok((await page.textContent(".win-banner")).includes("You won!") && (await page.$("[data-again]")) !== null, "a win is celebrated and offers Play again");
  if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}/play-win.png` });
  await page.evaluate((r) => { window.__room = r; }, mk({ status: "finished", winner_id: U2, state: { board: "OOOXX....", turn: 1, forfeit: U1 } }));
  await page.evaluate(() => { location.hash = "/squad?tab=play&room=rmNew&z=1"; });
  await page.waitForFunction(() => document.querySelector(".win-banner")?.textContent.includes("won!") && !document.querySelector(".win-banner").textContent.includes("You won"), null, { timeout: 4000 });
  ok((await page.textContent(".win-banner")).includes("You left the game") && !(await page.innerHTML(".win-banner")).includes("<b>U</b>"), "a loss and a forfeit are explained, names stay plain text");
  await page.evaluate(() => { window.__room = null; });
  await page.evaluate(() => { location.hash = "/squad?tab=play&room=gone"; });
  await page.waitForSelector("[data-stage] .empty", { timeout: 4000 });
  ok((await page.textContent("[data-stage]")).includes("isn't available any more"), "a closed table shows a friendly message");
  errors.length = 0; // the deliberate not_allowed above is logged by the client on purpose

  // cancelled event: the page automatically offers to return the money
  await page.evaluate((p) => { location.hash = p; }, `/events/${E3}`);
  await page.waitForSelector("[data-return]");
  const rt = await page.textContent("#outlet");
  ok(rt.includes("This event was cancelled. Return the money to your members?") && rt.includes("40,000 RWF") && (await page.$$("[data-return]")).length === 2, "cancelled event with money: leader is prompted to return it, one row per payment");
  ok(rt.includes("MoMo name “Aline Uwase”") && rt.includes("MP2610PAID01"), "return rows show who paid and the transaction ID");
  ok(await page.isVisible(".cover.hero"), "event picture shows on the event page");
  await page.click("[data-return]");
  await page.click('.dialog button[type="submit"]');
  ok((await page.textContent("#err-sent")).includes("Tick this"), "returning requires confirming the money was really sent back");
  await page.check("#f-sent");
  await page.click('.dialog button[type="submit"]');
  await page.waitForTimeout(250);
  const rf = await page.evaluate(() => window.__rpc.filter((r) => r[0] === "review_contribution").pop()?.[1]);
  ok(rf?.p_decision === "refunded" && /^Returned: /.test(rf.p_reason), "marking returned calls review_contribution(refunded) with a reason");
  await page.click("[data-return-all]");
  await page.click("[data-ok]");
  await page.waitForTimeout(300);
  ok((await page.evaluate(() => window.__rpc.filter((r) => r[0] === "review_contribution" && r[1].p_decision === "refunded").length)) >= 3, "\"I've returned everything\" records each remaining payment");
  // event form has a picture field and uploads it
  await page.evaluate((p) => { location.hash = p; }, `/events/${E1}`);
  await page.waitForSelector("[data-edit]");
  await page.click("[data-edit]");
  await page.fill("#f-pay_account", "0788123456");
  await page.setInputFiles("#f-cover", { name: "c.png", mimeType: "image/png", buffer: png });
  await page.click('.dialog button[type="submit"]');
  await page.waitForTimeout(500);
  const cv = await page.evaluate(() => window.__rpc.find((r) => r[0] === "set_event_cover")?.[1]);
  ok(cv?.p_event_id && /^[0-9a-f-]{36}\/[0-9a-f-]{36}\/[0-9a-f-]{36}\.(jpg|png)$/.test(cv.p_path ?? ""), "choosing an event picture uploads it and attaches it with set_event_cover");

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
  await page.goto(`${base}/?token_hash=goodtoken&type=magiclink`);
  await page.waitForSelector(".app-shell");
  await page.waitForTimeout(300);
  ok(await page.evaluate(() => window.__rpc?.some((r) => r[0] === "confirm_my_email")) !== false, "confirmation link signs in and records the confirmed email");
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
