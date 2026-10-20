// Squad hub: group chat, photo wall (with hearts) and games (polls + "guess the number").
// Reads go through RLS / read-only RPCs; every write is a SECURITY DEFINER RPC.
import { state, activeGroup, isManagerRole } from "./state.js";
import { fetchMessages, fetchPhotos, fetchGames, fetchEvents, fetchProfile } from "./data.js";
import { sendVerifyEmail } from "./auth.js";
import { rpc, friendlyError } from "./supabase.js";
import { navigate } from "./router.js";
import { uploadGroupImage, removeGroupImage, PHOTO_TYPES } from "./media.js";
import { html, timeAgo, formatNumber } from "./utils.js";
import {
  $, mount, on, icon, avatar, freshView, toast, toastError, openModal, confirmDialog, loadInto, setBusy,
  field, formData, formMessage, formMsgSlot, setFieldError, clearFieldErrors, emptyState, skeletonList,
} from "./ui.js";

const verifyBanner = (what) => html`<div class="form-msg info" role="status" data-verify-banner style="display:grid;gap:8px">
  <div><strong>Confirm your email to ${what}.</strong> It takes one tap: we email you a link to ${state.user.email}. Reading is always open.</div>
  <div class="row wrap" style="gap:8px"><button class="btn sm primary" type="button" data-verify>${icon("send")} Send confirmation email</button>
    <button class="btn sm" type="button" data-verify-recheck>${icon("refresh")} I've confirmed it</button></div></div>`;

const TABS = [["chat", "Chat", "chat"], ["photos", "Photos", "image"], ["games", "Games", "game"]];

export async function renderHub({ outlet, query, isCurrent }) {
  const group = activeGroup();
  if (!group) {
    mount(outlet, html`<div class="page-head"><h1>Squad</h1></div>${emptyState({ iconName: "users", title: "Pick or create a group first", text: "Chat, photos and games live inside a group.", actions: html`<a class="btn primary" href="#/groups">Go to my groups</a>` })}`);
    return;
  }
  const tab = TABS.some(([k]) => k === query.tab) ? query.tab : "chat";
  mount(outlet, html`<div class="page-head"><div><h1>Squad</h1><p class="sub">Chat, photos and games for ${group.name}</p></div></div>
    <div class="tabs" role="tablist" aria-label="Squad sections">${TABS.map(([k, label, ic]) => html`<button class="tab" role="tab" type="button" aria-selected="${k === tab}" data-tab="${k}">${icon(ic)} ${label}</button>`)}</div>
    <div data-pane></div>`);
  on(outlet, "click", "[data-tab]", (_, b) => navigate(`/squad?tab=${b.dataset.tab}`));
  const pane = $("[data-pane]", outlet);
  // Chat and photos need a confirmed email. Fresh read each time, so confirming in another tab shows up here.
  let verified = true;
  if (tab !== "games") {
    try { verified = Boolean((await fetchProfile(state.user.id)).email_verified_at); } catch { verified = true; /* the database still enforces it */ }
  }
  on(outlet, "click", "[data-verify]", async (_, b) => {
    setBusy(b, true, "Sending…");
    const r = await sendVerifyEmail(state.user.email);
    setBusy(b, false);
    if (r.ok) toast(`We sent a link to ${state.user.email}. Open it (check spam too), and you'll come straight back here.`, "success", 9000);
    else if (r.wait) toast(`Please wait ${r.wait} seconds before asking again.`, "info");
    else toastError(r.error);
  });
  on(outlet, "click", "[data-verify-recheck]", () => navigate(`/squad?tab=${tab}&t=${Date.now()}`));
  if (tab === "chat") await mountChat(pane, group, isCurrent, verified);
  else if (tab === "photos") await mountPhotos(pane, group, isCurrent, verified);
  else await mountGames(pane, group, isCurrent);
}

// ---------------------------------------------------------------------------
// Chat
// ---------------------------------------------------------------------------
const clock = (iso) => {
  const d = new Date(iso);
  const t = d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  return d.toDateString() === new Date().toDateString() ? t : `${d.toLocaleDateString([], { day: "numeric", month: "short" })} ${t}`;
};

async function mountChat(host, group, isCurrent, verified = true) {
  const me = state.user.id;
  const manager = isManagerRole(group.role);
  mount(host, html`<div class="card flush chat">
    <div class="chat-log" data-log tabindex="0" role="log" aria-live="polite" aria-label="Group chat"><div class="skeleton sk-card" style="height:80px;margin:16px"></div></div>
    ${verified ? "" : html`<div style="padding:10px;border-top:1px solid var(--border-soft)">${verifyBanner("chat")}</div>`}
    <form class="chat-form" data-send novalidate>
      <label class="sr-only" for="chat-body">Message</label>
      <textarea class="input" id="chat-body" name="body" rows="1" maxlength="1000" placeholder="${verified ? "Message your squad…" : "Confirm your email to chat"}" autocomplete="off" ${verified ? "" : "disabled"}></textarea>
      <button class="btn primary" type="submit" aria-label="Send message" ${verified ? "" : "disabled"}>${icon("send")}</button></form></div>
    <p class="faint" style="font-size:var(--fs-xs);margin-top:8px">Only members of ${group.name} can read this chat. Never share your MoMo PIN here. Leaders will never ask for it.</p>`);
  const log = $("[data-log]", host);
  const form = $("[data-send]", host);
  const box = $("#chat-body", host);
  let sig = "";
  let first = true;

  const paint = (rows) => {
    const next = rows.map((r) => r.id).join(",");
    if (next === sig) return;
    const nearBottom = first || log.scrollHeight - log.scrollTop - log.clientHeight < 80;
    sig = next;
    mount(log, rows.length
      ? html`${rows.map((r) => html`<div class="msg ${r.user_id === me ? "me" : ""}">
          ${r.user_id === me ? "" : avatar(r.name, r.avatar_path)}
          <div class="bubble"><div class="meta"><strong>${r.user_id === me ? "You" : r.name}</strong><span>${clock(r.created_at)}</span>
            ${r.user_id === me || manager ? html`<button class="x" type="button" data-del-msg="${r.id}" aria-label="Delete this message">${icon("trash")}</button>` : ""}</div>
            <div class="text">${r.body}</div></div></div>`)}`
      : html`<div class="empty" style="border:0"><div class="ico">${icon("chat")}</div><h3>Say hello</h3><p>Plan the party, share updates, cheer each other on.</p></div>`);
    if (nearBottom) log.scrollTop = log.scrollHeight;
    first = false;
  };
  const load = async () => {
    try { paint(await fetchMessages(group.id)); }
    catch (err) { if (first) mount(log, html`<p class="muted" style="padding:16px">${friendlyError(err)}</p>`); }
  };
  await load();

  const timer = setInterval(() => {
    if (!host.isConnected || !isCurrent()) return clearInterval(timer);
    if (!document.hidden) load();
  }, 5000);

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    const body = box.value.trim();
    if (!body) return;
    const btn = $('button[type="submit"]', form);
    btn.disabled = true;
    try {
      await rpc("post_group_message", { p_group_id: group.id, p_body: body });
      box.value = "";
      box.style.height = "";
      await load();
    } catch (err) { toastError(err); }
    btn.disabled = false;
    box.focus();
  });
  box.addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); form.requestSubmit(); } });
  box.addEventListener("input", () => { box.style.height = "auto"; box.style.height = `${Math.min(box.scrollHeight, 140)}px`; });
  on(host, "click", "[data-del-msg]", async (_, b) => {
    try { await rpc("delete_group_message", { p_message_id: b.dataset.delMsg }); await load(); } catch (err) { toastError(err); }
  });
}

// ---------------------------------------------------------------------------
// Photos
// ---------------------------------------------------------------------------
async function mountPhotos(host, group, isCurrent, verified = true) {
  const me = state.user.id;
  const manager = isManagerRole(group.role);
  const view = freshView(host);
  await loadInto(view, {
    isCurrent,
    skeleton: skeletonList(3),
    load: async () => ({ photos: await fetchPhotos(group.id), events: await fetchEvents([group.id]) }),
    render: ({ photos, events }) => {
      mount(view, html`<div class="row between wrap" style="margin-bottom:var(--s4)"><p class="muted">Share moments with your squad. Tap the heart on the ones you love.</p>
        ${verified ? html`<label class="btn primary" for="photo-file" style="cursor:pointer">${icon("upload")} Add a photo</label>
        <input class="sr-only" id="photo-file" type="file" accept="${PHOTO_TYPES.join(",")}" data-file>` : ""}</div>
        ${verified ? "" : html`<div style="margin-bottom:var(--s4)">${verifyBanner("share photos")}</div>`}
        ${photos.length
          ? html`<div class="photo-grid">${photos.map((p) => html`<figure class="ph">
              <button class="ph-img" type="button" data-open="${p.id}" aria-label="Open photo${p.caption ? `: ${p.caption}` : ""}"><img data-sbimg="${p.path}" alt="${p.caption || `Photo by ${p.name}`}" loading="lazy"></button>
              <figcaption><span class="who">${p.name}</span>
                <button class="like ${p.liked_by_me ? "on" : ""}" type="button" data-like="${p.id}" aria-pressed="${p.liked_by_me}" aria-label="Heart this photo">${icon("heart")}<span>${p.like_count}</span></button></figcaption></figure>`)}</div>`
          : emptyState({ iconName: "image", title: "No photos yet", text: "Be the first to share a moment from your squad." })}`);

      const redraw = () => mountPhotos(host, group, isCurrent, verified);
      $("[data-file]", view)?.addEventListener("change", (e) => {
        const file = e.target.files?.[0];
        e.target.value = "";
        if (file) openUploadDialog({ file, group, events, onDone: redraw });
      });
      on(view, "click", "[data-like]", async (_, b) => {
        try {
          const r = await rpc("toggle_photo_like", { p_photo_id: b.dataset.like });
          b.classList.toggle("on", r.liked);
          b.setAttribute("aria-pressed", String(r.liked));
          $("span", b).textContent = String(r.count);
        } catch (err) { toastError(err); }
      });
      on(view, "click", "[data-open]", (_, b) => {
        const p = photos.find((x) => x.id === b.dataset.open);
        if (p) openLightbox(p, { canDelete: p.user_id === me || manager, onDeleted: redraw, events });
      });
    },
  });
}

function openUploadDialog({ file, group, events, onDone }) {
  const preview = URL.createObjectURL(file);
  const m = openModal({
    title: "Share a photo",
    content: html`<form class="form" novalidate>
      <img class="upload-preview" src="${preview}" alt="Preview of your photo">
      ${field({ name: "caption", label: "Caption (optional)", required: false, attrs: 'maxlength="140"', placeholder: "What's happening?" })}
      <div class="field"><label for="f-event">Link to an event (optional)</label>
        <select class="select" id="f-event" name="event"><option value="">No event</option>${events.map((e) => html`<option value="${e.id}">${e.name}</option>`)}</select></div>
      ${formMsgSlot()}
      <div class="foot"><button class="btn ghost" type="button" data-cancel>Cancel</button><button class="btn primary" type="submit">Post photo</button></div></form>`,
    onClose: () => URL.revokeObjectURL(preview),
  });
  const form = $("form", m.el);
  $("[data-cancel]", m.el).addEventListener("click", () => m.close());
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    const v = formData(form);
    const btn = $('button[type="submit"]', form);
    setBusy(btn, true, "Uploading…");
    let path = null;
    try {
      path = await uploadGroupImage(group.id, state.user.id, file);
      await rpc("add_group_photo", { p_group_id: group.id, p_path: path, p_caption: v.caption?.trim() || null, p_event_id: v.event || null });
      toast("Photo shared.", "success");
      m.close();
      onDone();
    } catch (err) {
      if (path) removeGroupImage(path);
      formMessage(form, "error", friendlyError(err));
      setBusy(btn, false);
    }
  });
}

function openLightbox(p, { canDelete, onDeleted, events }) {
  const ev = events.find((e) => e.id === p.event_id);
  const m = openModal({
    title: p.caption || "Photo",
    content: html`<div class="stack"><img class="lightbox" data-sbimg="${p.path}" alt="${p.caption || `Photo by ${p.name}`}">
      <p class="muted" style="font-size:var(--fs-sm)">Shared by <strong style="color:var(--text)">${p.name}</strong> · ${timeAgo(p.created_at)}${ev ? html` · ${ev.name}` : ""}</p></div>`,
    footer: canDelete ? html`<button class="btn danger" type="button" data-del>${icon("trash")} Delete photo</button>` : "",
  });
  $("[data-del]", m.el)?.addEventListener("click", async () => {
    if (!(await confirmDialog({ title: "Delete this photo?", message: "It will disappear for everyone in the group.", confirmLabel: "Delete", danger: true }))) return;
    try { const path = await rpc("delete_group_photo", { p_photo_id: p.id }); await removeGroupImage(path); m.close(); toast("Photo deleted.", "success"); onDeleted(); }
    catch (err) { toastError(err); }
  });
}

// ---------------------------------------------------------------------------
// Games
// ---------------------------------------------------------------------------
const IDEAS = {
  poll: ["Where should we celebrate?", "Who will arrive first?", "Best colour for our group shirts?"],
  guess: ["How much will we have saved by the event date?", "How many guests will come?", "What will the total bill be?"],
};

async function mountGames(host, group, isCurrent) {
  const me = state.user.id;
  const manager = isManagerRole(group.role);
  const view = freshView(host);
  await loadInto(view, {
    isCurrent,
    skeleton: skeletonList(3),
    load: () => fetchGames(group.id),
    render: (games) => {
      mount(view, html`<div class="row between wrap" style="margin-bottom:var(--s4)"><p class="muted">Quick polls and “guess the number” rounds. The closest guess wins bragging rights.</p>
        <button class="btn primary" type="button" data-new-game>${icon("plus")} New game</button></div>
        ${games.length ? html`<div class="stack">${games.map((g) => gameCard(g, { me, manager }))}</div>`
          : emptyState({ iconName: "game", title: "No games yet", text: "Start a poll or a guessing round and get everyone playing.", actions: html`<button class="btn primary" type="button" data-new-game>${icon("plus")} Start a game</button>` })}`);
      const redraw = () => mountGames(host, group, isCurrent);
      on(view, "click", "[data-new-game]", () => openNewGame(group, redraw));
      on(view, "click", "[data-vote]", async (_, b) => {
        try { await rpc("play_game", { p_game_id: b.dataset.game, p_choice: Number(b.dataset.vote), p_guess: null }); redraw(); } catch (err) { toastError(err); }
      });
      view.addEventListener("submit", async (e) => {
        const f = e.target.closest("form[data-guess]");
        if (!f) return;
        e.preventDefault();
        const n = parseWhole(new FormData(f).get("guess"));
        if (n === null) return setFieldError(f, "guess", "Enter a whole number.");
        const btn = $('button[type="submit"]', f);
        setBusy(btn, true, "Saving…");
        try { await rpc("play_game", { p_game_id: f.dataset.guess, p_choice: null, p_guess: n }); toast("Guess locked in.", "success"); redraw(); }
        catch (err) { toastError(err); setBusy(btn, false); }
      });
      on(view, "click", "[data-close]", async (_, b) => {
        if (b.dataset.kind === "guess") return openRevealDialog(b.dataset.close, redraw);
        if (!(await confirmDialog({ title: "Close this poll?", message: "Nobody can vote any more. Results stay visible.", confirmLabel: "Close poll" }))) return;
        try { await rpc("close_game", { p_game_id: b.dataset.close, p_answer: null }); redraw(); } catch (err) { toastError(err); }
      });
      on(view, "click", "[data-del-game]", async (_, b) => {
        if (!(await confirmDialog({ title: "Delete this game?", message: "Votes and guesses are removed too.", confirmLabel: "Delete", danger: true }))) return;
        try { await rpc("delete_game", { p_game_id: b.dataset.delGame }); redraw(); } catch (err) { toastError(err); }
      });
    },
  });
}

const parseWhole = (v) => {
  const s = String(v ?? "").replace(/[\s,]/g, "");
  if (!/^\d{1,13}$/.test(s)) return null;
  const n = Number(s);
  return Number.isSafeInteger(n) ? n : null;
};

function gameCard(g, { me, manager }) {
  const open = g.status === "open";
  const mine = g.created_by === me;
  const total = (g.counts ?? []).reduce((a, b) => a + b, 0);
  const body = g.kind === "poll"
    ? html`<div class="stack" style="gap:8px">${g.options.map((o, i) => {
        const n = g.counts?.[i] ?? 0;
        const pct = total ? Math.round((n / total) * 100) : 0;
        const picked = g.my_choice === i + 1;
        return html`<button class="opt ${picked ? "picked" : ""}" type="button" ${open ? "" : "disabled"} data-vote="${i + 1}" data-game="${g.id}" aria-pressed="${picked}">
          <span class="bar" style="width:${pct}%"></span><span class="label">${o}${picked ? html` ${icon("check")}` : ""}</span><span class="n">${n} · ${pct}%</span></button>`;
      })}<p class="faint" style="font-size:var(--fs-xs)">${total} vote${total === 1 ? "" : "s"}${open ? (g.my_choice ? ". Tap another option to change yours." : ". Tap an option to vote.") : ". Closed."}</p></div>`
    : open
      ? html`<form class="row wrap" data-guess="${g.id}" novalidate style="align-items:flex-end;gap:10px">
          <div class="field" data-field="guess" style="flex:1;min-width:160px"><label for="gs-${g.id}">${g.my_guess != null ? "Your guess (tap to change)" : "Your guess"}</label>
            <input class="input" id="gs-${g.id}" name="guess" inputmode="numeric" value="${g.my_guess ?? ""}" placeholder="e.g. 500000" aria-describedby="err-guess"><div class="error" id="err-guess" role="alert"></div></div>
          <button class="btn primary" type="submit">${g.my_guess != null ? "Update guess" : "Lock in guess"}</button></form>
        <p class="faint" style="font-size:var(--fs-xs)">${g.entries} guess${g.entries === 1 ? "" : "es"} so far. Everyone's numbers stay hidden until the game is revealed.</p>`
      : html`<div class="stack" style="gap:8px"><div class="form-msg ok">The answer was <strong>${formatNumber(g.answer)}</strong>.</div>
          ${g.top.length ? html`<div class="list">${g.top.slice(0, 3).map((t, i) => html`<div class="list-item"><span class="avatar" aria-hidden="true" style="background:var(--surface-3);color:${i === 0 ? "var(--green)" : "var(--muted)"}">${i === 0 ? icon("trophy") : i + 1}</span>
              <div class="grow"><div class="title">${t.name}${t.user_id === me ? " (you)" : ""}</div><div class="sub">guessed ${formatNumber(t.guess)}</div></div>
              <div class="amount" style="font-size:var(--fs-sm)">${t.diff === 0 ? "Exact!" : `off by ${formatNumber(t.diff)}`}</div></div>`)}</div>` : html`<p class="muted">Nobody guessed.</p>`}</div>`;
  return html`<div class="card stack" style="gap:12px">
    <div class="row between wrap" style="gap:8px"><div><h3 style="margin:0">${g.title}</h3><div class="faint" style="font-size:var(--fs-xs);margin-top:2px">${g.kind === "poll" ? "Poll" : "Guess the number"} · by ${g.creator} · ${timeAgo(g.created_at)}</div></div>
      <span class="badge ${open ? "active" : ""}">${open ? "Open" : "Closed"}</span></div>
    ${body}
    ${(mine || manager) ? html`<div class="row" style="gap:8px;justify-content:flex-end">
      ${open ? html`<button class="btn sm" type="button" data-close="${g.id}" data-kind="${g.kind}">${icon("check")} ${g.kind === "guess" ? "Reveal answer" : "Close poll"}</button>` : ""}
      <button class="btn sm danger" type="button" data-del-game="${g.id}" aria-label="Delete game">${icon("trash")}</button></div>` : ""}</div>`;
}

function openNewGame(group, onDone) {
  const m = openModal({
    title: "New game",
    content: html`<form class="form" novalidate>
      <div class="radio-cards">
        <label class="radio-card"><input type="radio" name="kind" value="poll" checked><span class="face"><strong>Poll</strong><span>Everyone votes</span></span></label>
        <label class="radio-card"><input type="radio" name="kind" value="guess"><span class="face"><strong>Guess the number</strong><span>Closest wins</span></span></label></div>
      ${field({ name: "title", label: "Question", attrs: 'maxlength="120"', placeholder: IDEAS.poll[0] })}
      <div class="row wrap" data-ideas style="gap:6px">${IDEAS.poll.map((t) => html`<button class="tab" type="button" data-idea="${t}">${t}</button>`)}</div>
      <div class="field" data-field="options" data-opts><label for="f-options">Options (one per line, 2 to 6)</label>
        <textarea class="input" id="f-options" name="options" rows="4" maxlength="400" placeholder="Kigali&#10;Musanze&#10;Rubavu"></textarea><div class="error" id="err-options" role="alert"></div></div>
      ${formMsgSlot()}
      <div class="foot"><button class="btn ghost" type="button" data-cancel>Cancel</button><button class="btn primary" type="submit">Start game</button></div></form>`,
  });
  const form = $("form", m.el);
  $("[data-cancel]", m.el).addEventListener("click", () => m.close());
  const kind = () => formData(form).kind;
  const sync = () => {
    $("[data-opts]", form).hidden = kind() !== "poll";
    $("[data-ideas]", form).innerHTML = IDEAS[kind()].map((t) => `<button class="tab" type="button" data-idea="${t.replace(/"/g, "&quot;")}">${t}</button>`).join("");
    $("#f-title", form).placeholder = IDEAS[kind()][0];
  };
  form.addEventListener("change", (e) => { if (e.target.name === "kind") sync(); });
  on(form, "click", "[data-idea]", (_, b) => { $("#f-title", form).value = b.dataset.idea; });
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    clearFieldErrors(form);
    const v = formData(form);
    const title = v.title.trim();
    if (title.length < 3) return setFieldError(form, "title", "Write a short question (3+ characters).");
    const options = v.kind === "poll" ? String(v.options ?? "").split("\n").map((x) => x.trim()).filter(Boolean) : null;
    if (v.kind === "poll" && (options.length < 2 || options.length > 6)) return setFieldError(form, "options", "Add between 2 and 6 options, one per line.");
    const btn = $('button[type="submit"]', form);
    setBusy(btn, true, "Starting…");
    try {
      await rpc("create_game", { p_group_id: group.id, p_kind: v.kind, p_title: title, p_options: options });
      m.close();
      toast("Game started.", "success");
      onDone();
    } catch (err) { formMessage(form, "error", friendlyError(err)); setBusy(btn, false); }
  });
}

function openRevealDialog(gameId, onDone) {
  const m = openModal({
    title: "Reveal the answer",
    content: html`<form class="form" novalidate><p class="muted">Enter the real number. The closest guess wins and everyone's guesses become visible.</p>
      ${field({ name: "answer", label: "The answer", attrs: 'inputmode="numeric" autofocus', placeholder: "e.g. 520000" })}${formMsgSlot()}
      <div class="foot"><button class="btn ghost" type="button" data-cancel>Cancel</button><button class="btn primary" type="submit">Reveal</button></div></form>`,
  });
  const form = $("form", m.el);
  $("[data-cancel]", m.el).addEventListener("click", () => m.close());
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    clearFieldErrors(form);
    const n = parseWhole(formData(form).answer);
    if (n === null) return setFieldError(form, "answer", "Enter a whole number.");
    const btn = $('button[type="submit"]', form);
    setBusy(btn, true, "Revealing…");
    try { await rpc("close_game", { p_game_id: gameId, p_answer: n }); m.close(); onDone(); }
    catch (err) { formMessage(form, "error", friendlyError(err)); setBusy(btn, false); }
  });
}
