// Live multiplayer games for a squad. The server is the referee (supabase/migrations/012 + 013): it rolls the dice,
// keeps picks secret until the reveal and checks every move. This file only draws what get_room returns and asks for
// moves. While a room is open it asks for fresh state every ~1.5 s; the lobby every 4 s.
//
// Squad coins are pretend points. No real money, no Mobile Money, nothing can be cashed out.
import { state, isManagerRole } from "./state.js";
import { rpc } from "./supabase.js";
import { navigate } from "./router.js";
import { html } from "./utils.js";
import { $, mount, on, icon, avatar, freshView, toast, toastError, confirmDialog, loadInto, setBusy, emptyState, skeletonList } from "./ui.js";

export const GAMES = {
  clash: { name: "Clash", emoji: "⚔️", players: "2 players", blurb: "1v1 duel. Strike, heavy, guard, heal. Pick in secret, read your opponent, don't get cooked." },
  penalty: { name: "Penalty Kings", emoji: "⚽", players: "2 players", blurb: "Shootout time. Aim a corner or guess where they shoot. Five kicks each, no VAR." },
  race: { name: "Street Race", emoji: "🏎️", players: "2 to 10 players", blurb: "Cruise safe or boost and risk a spin-out. First to the finish line wins." },
  likely: { name: "Main Character", emoji: "👑", players: "3 to 12 players", blurb: "Who's most likely to…? Vote for someone in the squad. Most votes wears the crown." },
  rather: { name: "Hot Takes", emoji: "🔥", players: "2 to 12 players", blurb: "Would you rather? Pick a side. Run with the majority to score." },
  emoji: { name: "Emoji Decode", emoji: "🧩", players: "2 to 12 players", blurb: "Guess the movie or the meaning from the emojis. Fastest brain wins." },
  trivia: { name: "Trivia Race", emoji: "🧠", players: "2 to 12 players", blurb: "8 questions: Rwanda, slang, football and money sense. Everyone answers at once." },
  tictactoe: { name: "Tic-Tac-Toe", emoji: "❌⭕", players: "2 players", blurb: "Three in a row. Classic, quick, zero excuses." },
  connect4: { name: "Connect 4", emoji: "🔴🟡", players: "2 players", blurb: "Drop discs, connect four, humble your friend." },
  rps: { name: "Rock Paper Scissors", emoji: "✊✋✌️", players: "2 players", blurb: "First to 2. Picks stay hidden until you both lock in." },
  pot: { name: "Risk It", emoji: "🎲", players: "2 to 10 players", blurb: "Everyone puts coins in the pot and rolls two dice. Hold or re-roll (final, no cap). Highest total takes it all." },
};
const SECTIONS = [
  ["⚔️ Battle & sport", ["clash", "penalty", "race"]],
  ["💅 Girlies & vibes", ["likely", "rather", "emoji"]],
  ["🧠 Big brain", ["trivia", "tictactoe", "connect4", "rps"]],
  ["🎰 High stakes (squad coins)", ["pot"]],
];
const STAKES = [10, 25, 50, 100];
const RPS = { 1: ["✊", "Rock"], 2: ["✋", "Paper"], 3: ["✌️", "Scissors"] };
const CLASH = { 1: ["⚔️", "Strike"], 2: ["🔨", "Heavy"], 3: ["🛡️", "Guard"], 4: ["💚", "Heal"] };
const DICE = "⚀⚁⚂⚃⚄⚅";
const roomUrl = (id) => `/squad?tab=play&room=${encodeURIComponent(id)}`;
const LOBBY_URL = "/squad?tab=play";
const names = (players) => players.map((p) => (p.user_id === state.user.id ? "You" : p.name)).join(", ");
const coins = (n) => html`🪙 ${Number(n).toLocaleString("en-US")}`;

export async function mountPlay(host, group, isCurrent, roomId) {
  if (roomId) return mountRoom(host, group, isCurrent, roomId);
  return mountLobby(host, group, isCurrent);
}

// ---------------------------------------------------------------------------
// Lobby: coins, pick a game, join an open table, leaderboards
// ---------------------------------------------------------------------------
async function mountLobby(host, group, isCurrent) {
  const view = freshView(host);
  const manager = isManagerRole(group.role);
  let sig = "";
  let timer = null;

  const paint = (data) => {
    const rooms = data.rooms ?? [];
    const live = rooms.filter((r) => r.status !== "finished");
    const done = rooms.filter((r) => r.status === "finished" && !r.abandoned);
    const w = data.wallet ?? { balance: 0, can_claim: false };
    mount(view, html`
      <div class="wallet-bar"><div><div class="faint" style="font-size:var(--fs-xs)">Your squad coins</div><strong style="font-size:1.3rem">${coins(w.balance)}</strong></div>
        ${w.can_claim ? html`<button class="btn sm primary" type="button" data-claim>${icon("plus")} Claim +50 daily</button>` : html`<span class="badge">Daily coins claimed ✅</span>`}</div>
      <p class="muted" style="margin:var(--s3) 0 var(--s4)">Game night, but make it your squad. Host a table, tell the group chat, and let the games begin. Bragging rights only: squad coins are pretend, no real money ever.</p>

      ${SECTIONS.map(([title, kinds]) => html`<h2 class="h3" style="margin:var(--s5) 0 var(--s3)">${title}</h2>
        <div class="game-grid">${kinds.map((k) => tile(k))}</div>`)}

      <h2 class="h3" style="margin:var(--s5) 0 var(--s3)">Open tables</h2>
      ${live.length ? html`<div class="stack" style="gap:var(--s3)">${live.map((r) => roomRow(r, manager))}</div>`
        : emptyState({ iconName: "game", title: "No tables yet", text: "Host a game above, then tell your squad to open Squad → Play. It's giving empty lobby right now." })}

      ${data.leaderboard?.length ? html`<h2 class="h3" style="margin:var(--s5) 0 var(--s3);display:flex;align-items:center;gap:8px">${icon("trophy")} Squad leaderboard</h2>
        <div class="card" style="padding:0"><table class="table" style="width:100%;text-align:left"><thead><tr><th style="text-align:left">#</th><th style="text-align:left">Player</th><th style="text-align:left">Wins</th><th style="text-align:left">Played</th></tr></thead><tbody>
          ${data.leaderboard.map((p, i) => html`<tr><td>${i + 1}</td><td>${p.user_id === state.user.id ? html`<strong>${p.name} (you)</strong>` : p.name}</td><td><strong>${p.wins}</strong></td><td>${p.played}</td></tr>`)}
        </tbody></table></div>` : ""}

      ${data.rich?.length > 1 ? html`<h2 class="h3" style="margin:var(--s5) 0 var(--s3)">💰 Rich list</h2>
        <div class="card" style="padding:0"><table class="table" style="width:100%;text-align:left"><tbody>
          ${data.rich.map((p, i) => html`<tr><td>${i + 1}</td><td>${p.user_id === state.user.id ? html`<strong>${p.name} (you)</strong>` : p.name}</td><td style="text-align:right"><strong>${coins(p.balance)}</strong></td></tr>`)}
        </tbody></table></div><p class="faint" style="margin-top:var(--s2);font-size:var(--fs-xs)">Squad coins are pretend points for fun. They can't be bought, sold or cashed out.</p>` : ""}

      ${done.length ? html`<h2 class="h3" style="margin:var(--s5) 0 var(--s3)">Recent results</h2>
        <div class="stack" style="gap:var(--s2)">${done.map((r) => html`<div class="room-row"><div><strong>${GAMES[r.kind]?.emoji ?? ""} ${GAMES[r.kind]?.name ?? r.kind}</strong>
          <div class="faint" style="font-size:var(--fs-xs)">${names(r.players)}</div></div>
          <span class="badge ${r.winner_id ? "paid" : ""}">${r.winner_id ? `${r.winner_id === state.user.id ? "You" : r.players.find((p) => p.user_id === r.winner_id)?.name ?? "Someone"} won` : "Draw"}</span></div>`)}</div>` : ""}`);
  };

  const refresh = async (force = false) => {
    try {
      const data = await rpc("list_rooms", { p_group_id: group.id });
      const next = JSON.stringify(data);
      if (!force && next === sig) return;
      sig = next;
      if (isCurrent() && view.isConnected) paint(data);
    } catch { /* keep the last picture; the next poll tries again */ }
  };

  await loadInto(view, {
    isCurrent,
    skeleton: skeletonList(3),
    load: () => rpc("list_rooms", { p_group_id: group.id }),
    render: (data) => { sig = JSON.stringify(data); paint(data); },
  });

  on(view, "click", "[data-host]", async (_, b) => {
    setBusy(b, true, "Opening…");
    try {
      const id = await rpc("create_room", { p_group_id: group.id, p_kind: b.dataset.host, p_stake: Number(b.dataset.stake || 0) });
      navigate(roomUrl(id));
    } catch (err) { toastError(err); setBusy(b, false); }
  });
  on(view, "click", "[data-claim]", async (_, b) => {
    setBusy(b, true, "Claiming…");
    try { await rpc("claim_daily_coins", { p_group_id: group.id }); toast("+50 coins. Stack that bag 💰", "success"); refresh(true); }
    catch (err) { toastError(err); setBusy(b, false); refresh(true); }
  });
  on(view, "click", "[data-open]", (_, b) => navigate(roomUrl(b.dataset.open)));
  on(view, "click", "[data-join]", async (_, b) => {
    setBusy(b, true, "Joining…");
    try { await rpc("join_room", { p_room_id: b.dataset.join }); navigate(roomUrl(b.dataset.join)); }
    catch (err) { toastError(err); setBusy(b, false); refresh(true); }
  });
  on(view, "click", "[data-del-room]", async (_, b) => {
    if (!(await confirmDialog({ title: "Close this table?", message: "Everyone gets sent back to the lobby. Any coins already in a lobby pot go back to their owners.", confirmLabel: "Close table", danger: true }))) return;
    try { await rpc("delete_room", { p_room_id: b.dataset.delRoom }); refresh(true); } catch (err) { toastError(err); }
  });

  timer = setInterval(() => {
    if (!view.isConnected || !isCurrent()) return clearInterval(timer);
    if (!document.hidden) refresh();
  }, 4000);
}

function tile(k) {
  const g = GAMES[k];
  return html`<div class="game-tile"><div class="emo" aria-hidden="true">${g.emoji}</div><h3>${g.name}</h3><p class="faint">${g.blurb}</p>
    <div class="row between wrap"><span class="badge">${g.players}</span>
      ${k === "pot" ? html`<div class="row wrap" style="gap:6px">${STAKES.map((s) => html`<button class="btn sm primary" type="button" data-host="pot" data-stake="${s}" aria-label="Host with a ${s} coin stake">🪙 ${s}</button>`)}</div>`
        : html`<button class="btn sm primary" type="button" data-host="${k}">${icon("plus")} Host</button>`}</div></div>`;
}

function roomRow(r, manager) {
  const g = GAMES[r.kind];
  const full = r.players.length >= r.max_players;
  const mine = r.host_id === state.user.id;
  return html`<div class="room-row"><div><strong>${g?.emoji} ${g?.name ?? r.kind}</strong>${r.stake ? html` <span class="badge">🪙 ${r.stake} to play</span>` : ""}
      <div class="faint" style="font-size:var(--fs-xs)">${r.players.length}/${r.max_players} · ${names(r.players)}</div></div>
    <div class="row" style="gap:8px"><span class="badge ${r.status === "playing" ? "pending" : "active"}">${r.status === "playing" ? "Playing" : "Waiting"}</span>
      ${r.in_room ? html`<button class="btn sm primary" type="button" data-open="${r.id}">Open</button>`
        : r.status === "lobby" && !full ? html`<button class="btn sm primary" type="button" data-join="${r.id}">Join</button>`
        : html`<button class="btn sm" type="button" data-open="${r.id}">Watch</button>`}
      ${(mine || manager) && !(r.kind === "pot" && r.status === "playing") ? html`<button class="btn sm danger" type="button" data-del-room="${r.id}" aria-label="Close table">${icon("trash")}</button>` : ""}</div></div>`;
}

// ---------------------------------------------------------------------------
// One room
// ---------------------------------------------------------------------------
async function mountRoom(host, group, isCurrent, roomId) {
  const view = freshView(host);
  let room = null;
  let sig = "";
  let skew = 0;       // server clock minus this phone's clock, so countdowns agree
  let busy = false;
  let gone = false;
  let asked = "";     // remembers which phase we already nudged the server about

  mount(view, html`<div class="row between wrap" style="margin-bottom:var(--s3)">
      <button class="btn sm ghost" type="button" data-back><span style="display:inline-flex;transform:scaleX(-1)">${icon("arrow")}</span> <span style="margin-left:4px">All games</span></button><span data-status></span></div>
    <h2 class="h3" data-title></h2><div data-stage>${skeletonList(2)}</div>`);
  const stage = $("[data-stage]", view);

  const alive = () => view.isConnected && isCurrent() && !gone;
  const fetchRoom = async () => {
    const r = await rpc("get_room", { p_room_id: roomId });
    skew = Date.parse(r.server_now) - Date.now();
    return r;
  };
  const refresh = async () => {
    if (!alive()) return;
    try {
      const r = await fetchRoom();
      if (!alive()) return;
      const s = JSON.stringify({ ...r, server_now: 0 });
      if (s === sig) return;
      sig = s; room = r;
      paint();
    } catch {
      if (!alive()) return;
      gone = true;
      mount(stage, html`<div class="empty"><div class="ico">${icon("game")}</div><h3>This game isn't available any more</h3>
        <p>Looks like the host closed it.</p><button class="btn primary" type="button" data-back>Back to games</button></div>`);
    }
  };

  const paint = () => {
    const r = room;
    const g = GAMES[r.kind];
    $("[data-title]", view).textContent = `${g.emoji} ${g.name}`;
    mount($("[data-status]", view), html`<span class="badge ${r.status === "playing" ? "pending" : r.status === "lobby" ? "active" : ""}">${r.status === "lobby" ? "Waiting for players" : r.status === "playing" ? "Playing" : "Finished"}</span>`);
    if (r.status === "lobby") return mount(stage, lobbyView(r));
    mount(stage, html`${seatsView(r)}${BOARDS[r.kind](r)}${endView(r)}`);
    tickCountdown();
  };

  // ---- countdowns for the timed games ---------------------------------------
  const tickCountdown = () => {
    const r = room;
    const total = r && timedMs(r);
    if (!total) return;
    const left = Date.parse(r.state.until) - (Date.now() + skew);
    const bar = $("[data-timer]", view);
    if (bar) {
      bar.style.width = `${Math.max(0, Math.min(100, (left / total) * 100))}%`;
      const t = $("[data-left]", view);
      if (t) t.textContent = `${Math.max(0, Math.ceil(left / 1000))}s`;
    }
    const key = `${r.kind}-${r.state.q ?? r.state.round ?? 0}-${r.state.phase}`;
    if (left <= 0 && asked !== key) { asked = key; refresh(); }
  };

  await refresh();

  // ---- actions --------------------------------------------------------------
  const act = async (fn) => {
    if (busy) return;
    busy = true;
    try { await fn(); } catch (err) { toastError(err); }
    busy = false;
    sig = "";
    await refresh();
  };
  on(view, "click", "[data-back]", () => navigate(LOBBY_URL));
  on(view, "click", "[data-start]", (_, b) => act(async () => { setBusy(b, true, "Starting…"); await rpc("start_room", { p_room_id: roomId }); }));
  on(view, "click", "[data-join-room]", (_, b) => act(async () => { setBusy(b, true, "Joining…"); await rpc("join_room", { p_room_id: roomId }); }));
  on(view, "click", "[data-move]", (_, b) => act(() => rpc("make_move", { p_room_id: roomId, p_move: Number(b.dataset.move) })));
  on(view, "click", "[data-leave]", async () => {
    const live = room?.status === "playing" && ["tictactoe", "connect4", "rps", "clash", "penalty"].includes(room.kind);
    if (live && !(await confirmDialog({ title: "Leave this game?", message: "Leaving a live game counts as a loss. You sure?", confirmLabel: "Leave game", danger: true }))) return;
    try { await rpc("leave_room", { p_room_id: roomId }); navigate(LOBBY_URL); } catch (err) { toastError(err); }
  });
  on(view, "click", "[data-again]", async (_, b) => {
    setBusy(b, true, "Opening…");
    try { const id = await rpc("create_room", { p_group_id: group.id, p_kind: room.kind, p_stake: room.stake ?? 0 }); navigate(roomUrl(id)); }
    catch (err) { toastError(err); setBusy(b, false); }
  });
  on(view, "click", "[data-close-room]", async () => {
    if (!(await confirmDialog({ title: "Close this table?", message: "It disappears for everyone.", confirmLabel: "Close table", danger: true }))) return;
    try { await rpc("delete_room", { p_room_id: roomId }); navigate(LOBBY_URL); } catch (err) { toastError(err); }
  });

  const poll = setInterval(() => {
    if (!alive()) return clearInterval(poll);
    if (!document.hidden && room?.status !== "finished") refresh();
  }, 1500);
  const clock = setInterval(() => { if (!alive()) return clearInterval(clock); tickCountdown(); }, 250);
}

/** Length in ms of the current timed phase, or 0 when this game has no clock right now. */
function timedMs(r) {
  const s = r.state;
  if (r.status !== "playing" || !s?.until) return 0;
  if (r.kind === "trivia" || r.kind === "emoji") return s.phase === "question" ? 15000 : 5000;
  if (r.kind === "likely" || r.kind === "rather") return s.phase === "question" ? 20000 : 5000;
  if (r.kind === "race") return 10000;
  if (r.kind === "pot") return 20000;
  return 0;
}

// ---------------------------------------------------------------------------
// Shared pieces
// ---------------------------------------------------------------------------
const byId = (r, id) => r.players.find((p) => p.user_id === id);
const bySeat = (r, seat) => r.players.find((p) => p.seat === seat);
const who = (p) => (p?.user_id === state.user.id ? "You" : p?.name ?? "Someone");

function timerBlock(r, label = "locked in") {
  const n = r.players.length;
  const answered = (r.state.answered ?? []).length;
  return html`<div class="timer" aria-hidden="true"><i data-timer style="width:100%"></i></div>
    <div class="row between"><span class="faint">${label === "" ? "" : `${answered} of ${n} ${label}`}</span><strong data-left>…</strong></div>`;
}

function lobbyView(r) {
  const me = state.user.id;
  const isHost = r.host_id === me;
  const n = r.players.length;
  const min = r.min_players ?? 2;
  return html`<div class="card" style="display:grid;gap:var(--s4)">
    <p class="muted">${GAMES[r.kind].blurb}</p>
    ${r.stake ? html`<div class="form-msg info" role="status"><strong>🪙 ${r.stake} coins to play.</strong> Everyone puts ${r.stake} in the pot. Highest roll takes all. Leave before it starts and you get your coins back. Pretend coins only, no real money.</div>` : ""}
    <div class="seats">${r.players.map((p) => html`<span class="seat">${avatar(p.name, p.avatar_path)}<span>${p.user_id === me ? "You" : p.name}${p.user_id === r.host_id ? " · host" : ""}</span></span>`)}</div>
    <p class="faint">${n} of ${r.max_players} players. ${n < min ? `Need ${min - n} more to start. Tell your squad to open Squad → Play and tap Join.` : isHost ? "Squad's here. Start whenever you're ready." : "Waiting for the host to start."}</p>
    <div class="row wrap" style="gap:8px">
      ${!r.in_room ? (n < r.max_players ? html`<button class="btn primary" type="button" data-join-room>Join this game${r.stake ? ` (🪙 ${r.stake})` : ""}</button>` : html`<span class="badge">Table is full</span>`) : ""}
      ${isHost ? html`<button class="btn primary" type="button" data-start ${n < min ? "disabled" : ""}>${icon("game")} Start game</button>` : ""}
      ${r.in_room ? html`<button class="btn" type="button" data-leave>Leave</button>` : ""}
      ${isHost ? html`<button class="btn danger" type="button" data-close-room>${icon("trash")} Close table</button>` : ""}</div></div>`;
}

function seatsView(r) {
  const showScore = ["trivia", "emoji", "likely", "rather", "rps", "pot"].includes(r.kind);
  const turn = r.status === "playing" && (r.kind === "tictactoe" || r.kind === "connect4") ? r.state.turn : null;
  const marks = r.kind === "tictactoe" ? ["❌", "⭕"] : r.kind === "connect4" ? ["🔴", "🟡"] : r.kind === "penalty" ? ["⚽", "🧤"] : [];
  const sorted = ["trivia", "emoji", "likely", "rather"].includes(r.kind) ? [...r.players].sort((a, b) => b.score - a.score || a.seat - b.seat) : r.players;
  return html`<div class="seats" style="margin-bottom:var(--s4)">${sorted.map((p) => html`
    <span class="seat ${turn === p.seat ? "turn" : ""}">${avatar(p.name, p.avatar_path)}<span>${marks[p.seat] ?? ""} ${p.user_id === state.user.id ? "You" : p.name}</span>
      ${showScore && r.kind !== "pot" ? html`<span class="pts">${p.score}</span>` : ""}</span>`)}</div>`;
}

function turnLine(r) {
  if (r.status !== "playing") return "";
  const mine = r.in_room && r.state.turn === r.me_seat;
  const name = bySeat(r, r.state.turn)?.name ?? "your friend";
  if (!r.in_room) return html`<p class="muted" style="text-align:center;margin-bottom:var(--s3)">Just watching. It's ${name}'s turn.</p>`;
  return html`<p style="text-align:center;margin-bottom:var(--s3);font-weight:700;${mine ? "color:var(--green)" : "color:var(--muted)"}">${mine ? "Your turn 🫵" : `Waiting for ${name}…`}</p>`;
}

// ---------------------------------------------------------------------------
// Boards
// ---------------------------------------------------------------------------
function tttView(r) {
  const cells = [...r.state.board];
  const line = r.state.line ?? [];
  const can = r.status === "playing" && r.in_room && r.state.turn === r.me_seat;
  return html`${turnLine(r)}<div class="ttt" role="grid" aria-label="Tic-Tac-Toe board">${cells.map((c, i) => html`
    <button class="cell ${c === "X" ? "x" : c === "O" ? "o" : ""} ${line.includes(i) ? "win" : ""}" type="button" role="gridcell" data-move="${i}" ${can && c === "." ? "" : "disabled"}
      aria-label="Cell ${i + 1}: ${c === "." ? "empty" : c}">${c === "." ? "" : c === "X" ? "✕" : "◯"}</button>`)}</div>`;
}

function c4View(r) {
  const b = r.state.board;
  const line = r.state.line ?? [];
  const can = r.status === "playing" && r.in_room && r.state.turn === r.me_seat;
  const cols = [0, 1, 2, 3, 4, 5, 6];
  const rows = [0, 1, 2, 3, 4, 5];
  return html`${turnLine(r)}<div class="c4" role="group" aria-label="Connect 4 board">${cols.map((col) => html`
    <button class="c4col" type="button" data-move="${col}" ${can ? "" : "disabled"} aria-label="Drop a disc in column ${col + 1}">${rows.map((row) => {
      const i = row * 7 + col;
      const c = b[i];
      return html`<span class="disc ${c === "R" ? "r" : c === "Y" ? "y" : ""} ${line.includes(i) ? "win" : ""}"></span>`;
    })}</button>`)}</div>`;
}

function rpsView(r) {
  const s = r.state;
  const can = r.status === "playing" && r.in_room && r.my_choice == null;
  const last = s.last;
  let lastLine = "";
  if (last) {
    const mine = r.in_room ? last.c[r.me_seat] : last.c[0];
    const theirs = r.in_room ? last.c[1 - r.me_seat] : last.c[1];
    const res = last.result === -1 ? "Draw. Run it back." : r.in_room ? (last.result === r.me_seat ? "You won that round!" : "You lost that round.") : `${bySeat(r, last.result)?.name} won that round.`;
    lastLine = html`<p style="text-align:center;margin-top:var(--s3)">${RPS[mine][0]} vs ${RPS[theirs][0]} — <strong>${res}</strong></p>`;
  }
  const waiting = r.status === "playing" && r.my_choice != null;
  return html`<p style="text-align:center;margin-bottom:var(--s3);font-weight:700">${r.status === "playing" ? `Round ${s.round} · first to ${s.target} wins` : "Final score"}</p>
    <div class="rps-row">${[1, 2, 3].map((n) => html`<button class="rps-btn ${r.my_choice === n ? "picked" : ""}" type="button" data-move="${n}" ${can ? "" : "disabled"}>
      <span class="big" aria-hidden="true">${RPS[n][0]}</span><span>${RPS[n][1]}</span></button>`)}</div>
    ${waiting ? html`<p class="muted" style="text-align:center;margin-top:var(--s3)">You picked ${RPS[r.my_choice][1]}. Waiting for your friend…</p>`
      : r.status === "playing" && !r.in_room ? html`<p class="muted" style="text-align:center;margin-top:var(--s3)">Just watching. ${s.moved?.length ? "One player has picked." : "Nobody has picked yet."}</p>` : ""}
    ${lastLine}`;
}

function clashView(r) {
  const s = r.state;
  const me = r.in_room ? r.me_seat : 0;
  const you = bySeat(r, me), them = bySeat(r, 1 - me);
  const can = r.status === "playing" && r.in_room && r.my_choice == null;
  const bar = (p, seat) => html`<div class="hpbox"><div class="row between"><strong>${who(p)}</strong><span>${s.hp[seat]} HP${r.status === "playing" ? html` · 💚 x${s.heals[seat]}` : ""}</span></div>
    <div class="hp"><i style="width:${Math.max(0, Math.min(100, s.hp[seat]))}%"></i></div></div>`;
  const last = s.last;
  const recap = last ? html`<p style="text-align:center;margin-top:var(--s3)">${CLASH[last.m[me]][0]} ${who(you)} vs ${CLASH[last.m[1 - me]][0]} ${who(them)}<br>
    <strong>${last.dmg[me] ? `${r.in_room ? "You took" : who(you) + " took"} ${last.dmg[me]}` : "No damage taken"}</strong> · <strong>${last.dmg[1 - me] ? `${who(them)} took ${last.dmg[1 - me]}` : `${who(them)} took 0`}</strong>
    ${last.heal[me] || last.heal[1 - me] ? html`<br><span class="faint">💚 healed ${last.heal[me] ? `${who(you)} +${last.heal[me]}` : ""} ${last.heal[1 - me] ? `${who(them)} +${last.heal[1 - me]}` : ""}</span>` : ""}</p>` : "";
  return html`<div class="stack" style="gap:var(--s3)">${bar(you, me)}${bar(them, 1 - me)}</div>
    <p style="text-align:center;margin:var(--s4) 0 var(--s3);font-weight:700">${r.status === "playing" ? `Round ${s.round} of 12` : "Final round"}</p>
    <div class="clash-row">${[1, 2, 3, 4].map((n) => html`<button class="rps-btn ${r.my_choice === n ? "picked" : ""}" type="button" data-move="${n}"
        ${can && !(n === 4 && s.heals[me] <= 0) ? "" : "disabled"}><span class="big" aria-hidden="true">${CLASH[n][0]}</span><span>${CLASH[n][1]}</span></button>`)}</div>
    <p class="faint" style="text-align:center;margin-top:var(--s2);font-size:var(--fs-xs)">Strike beats Heavy · Heavy breaks Guard · Guard beats Strike (and counters)</p>
    ${r.status === "playing" ? (r.my_choice != null ? html`<p class="muted" style="text-align:center;margin-top:var(--s3)">Locked in ${CLASH[r.my_choice][1]}. Waiting for your opponent…</p>`
      : !r.in_room ? html`<p class="muted" style="text-align:center;margin-top:var(--s3)">Just watching.</p>` : "") : ""}
    ${recap}`;
}

function penaltyView(r) {
  const s = r.state;
  const hist = s.hist ?? [];
  const shooter = s.kick % 2;
  const iShoot = r.in_room && r.me_seat === shooter;
  const can = r.status === "playing" && r.in_room && r.my_choice == null;
  const ICON = { goal: "⚽", saved: "🧤", missed: "❌" };
  const row = (seat) => {
    const mine = hist.filter((h) => h.s === seat).map((h) => ICON[h.r]);
    const slots = Math.max(5, mine.length);
    return html`<div class="row between"><strong>${who(bySeat(r, seat))}</strong><span class="kicks">${Array.from({ length: slots }, (_, i) => mine[i] ?? "○").join(" ")}</span><strong>${s.scores[seat]}</strong></div>`;
  };
  const last = hist.at(-1);
  const lastLine = last ? html`<p style="text-align:center;margin-top:var(--s3)">${last.r === "goal" ? "⚽ GOAL!" : last.r === "saved" ? "🧤 Saved!" : "❌ Missed wide"} ${who(bySeat(r, last.s))} shot ${["left", "middle", "right"][last.shot]}, keeper went ${["left", "middle", "right"][last.dive]}.</p>` : "";
  return html`<div class="card" style="display:grid;gap:var(--s2)">${row(0)}${row(1)}${s.kick >= 10 && r.status === "playing" ? html`<p class="faint" style="text-align:center">Sudden death 💀</p>` : ""}</div>
    ${r.status === "playing" ? html`<p style="text-align:center;margin:var(--s4) 0 var(--s3);font-weight:700;color:var(--green)">${r.in_room ? (iShoot ? "You're shooting. Pick a corner 🎯" : "You're in goal. Guess where it's going 🧤") : `${who(bySeat(r, shooter))} is shooting`}</p>
      <div class="rps-row">${[0, 1, 2].map((n) => html`<button class="rps-btn ${r.my_choice === n ? "picked" : ""}" type="button" data-move="${n}" ${can ? "" : "disabled"}>
        <span class="big" aria-hidden="true">${["⬅️", "⬆️", "➡️"][n]}</span><span>${["Left", "Middle", "Right"][n]}</span></button>`)}</div>
      ${r.my_choice != null ? html`<p class="muted" style="text-align:center;margin-top:var(--s3)">Locked in. Waiting for the other side…</p>` : ""}` : ""}
    ${lastLine}`;
}

function raceView(r) {
  const s = r.state;
  const can = r.status === "playing" && r.in_room && r.my_choice == null;
  const usedNitro = r.in_room && s.used && s.used[String(r.me_seat)];
  const lane = (p) => {
    const pos = s.pos[String(p.seat)] ?? 0;
    const pct = Math.min(100, (pos / s.goal) * 100);
    return html`<div class="lane"><div class="row between" style="font-size:var(--fs-sm)"><span>${who(p)}</span><strong>${pos}/${s.goal}</strong></div>
      <div class="track"><i style="width:${pct}%"></i><span class="car" style="left:calc(${pct}% - ${pct > 90 ? 22 : 0}px)">🏎️</span><span class="flag">🏁</span></div></div>`;
  };
  const last = s.last ?? [];
  const GEAR = { 1: "cruised", 2: "boosted", 3: "hit nitro" };
  return html`<div class="stack" style="gap:var(--s3)">${r.players.map(lane)}</div>
    ${r.status === "playing" ? html`<div style="margin-top:var(--s4)">${timerBlock(r, "locked in")}</div>
      <p style="text-align:center;margin:var(--s3) 0;font-weight:700">Round ${s.round}. Pick your gear</p>
      <div class="rps-row">
        <button class="rps-btn ${r.my_choice === 1 ? "picked" : ""}" type="button" data-move="1" ${can ? "" : "disabled"}><span class="big" aria-hidden="true">🚗</span><span>Cruise</span><small class="faint">+3 safe</small></button>
        <button class="rps-btn ${r.my_choice === 2 ? "picked" : ""}" type="button" data-move="2" ${can ? "" : "disabled"}><span class="big" aria-hidden="true">🔥</span><span>Boost</span><small class="faint">+7 or spin-out</small></button>
        <button class="rps-btn ${r.my_choice === 3 ? "picked" : ""}" type="button" data-move="3" ${can && !usedNitro ? "" : "disabled"}><span class="big" aria-hidden="true">🚀</span><span>Nitro</span><small class="faint">${usedNitro ? "used up" : "+9, once"}</small></button></div>
      ${r.my_choice != null ? html`<p class="muted" style="text-align:center;margin-top:var(--s3)">Locked in. Waiting for the other drivers… no pick means cruise.</p>` : ""}` : ""}
    ${last.length ? html`<div class="faint" style="margin-top:var(--s3);font-size:var(--fs-sm)"><strong>Last round:</strong> ${last.map((l) => `${who(bySeat(r, l.seat))} ${GEAR[l.gear]}${l.crashed ? " and spun out 💥" : ""} (${l.delta >= 0 ? "+" : ""}${l.delta})`).join(" · ")}</div>` : ""}`;
}

function triviaView(r) {
  const s = r.state;
  const q = s.q + 1;
  const reveal = s.phase === "reveal" || s.phase === "done";
  const mine = r.my_answer;
  const myRes = reveal ? s.results?.find((x) => x.user_id === state.user.id) : null;
  return html`<div class="card" style="display:grid;gap:var(--s3)">
    <div class="row between wrap"><span class="badge">Question ${q} of ${s.total}</span><span class="faint">${s.topic}</span></div>
    ${r.status === "playing" ? timerBlock(r, s.phase === "question" ? "answered" : "") : ""}
    <p class="quiz-q">${s.question}</p>
    <div class="stack" style="gap:var(--s2)">${s.options.map((o, i) => html`
      <button class="opt ${reveal ? (i === s.correct ? "right" : myRes?.choice === i ? "wrong" : "") : mine === i ? "picked" : ""}" type="button" data-move="${i}"
        ${s.phase === "question" && r.in_room && mine == null ? "" : "disabled"}><span class="label">${"ABCD"[i]}. ${o}</span>
        ${reveal && i === s.correct ? html`<span class="n">${icon("check")}</span>` : ""}</button>`)}</div>
    ${s.phase === "question" ? (mine != null ? html`<p class="muted">Locked in. Waiting for the others…</p>` : r.in_room ? html`<p class="faint">Answer fast: quicker correct answers score more (100 to 150 points).</p>` : html`<p class="muted">Just watching.</p>`) : ""}
    ${reveal ? html`<p><strong>${myRes ? (myRes.points > 0 ? `Correct! +${myRes.points} points 🔥` : myRes.choice == null ? "Too slow 🐌" : "Not this time 💀") : "Answer revealed."}</strong>
      ${s.phase === "reveal" ? html`<span class="faint"> Next one loading…</span>` : ""}</p>` : ""}</div>`;
}

function likelyView(r) {
  const s = r.state;
  const reveal = s.phase === "reveal" || s.phase === "done";
  const mine = r.my_answer;
  const votes = new Map((s.votes ?? []).map((v) => [v.seat, v.n]));
  const top = s.top ?? 0;
  return html`<div class="card" style="display:grid;gap:var(--s3)">
    <div class="row between wrap"><span class="badge">Round ${s.q + 1} of ${s.total}</span><span class="faint">Be honest</span></div>
    ${r.status === "playing" ? timerBlock(r, s.phase === "question" ? "voted" : "") : ""}
    <p class="quiz-q">${s.prompt}</p>
    <div class="stack" style="gap:var(--s2)">${r.players.map((p) => {
      const n = votes.get(p.seat) ?? 0;
      const pct = reveal && top ? Math.round((n / Math.max(top, 1)) * 100) : 0;
      return html`<button class="opt ${reveal ? (n === top && top > 0 ? "right" : "") : mine === p.seat ? "picked" : ""}" type="button" data-move="${p.seat}"
        ${s.phase === "question" && r.in_room && mine == null ? "" : "disabled"}>${reveal ? html`<span class="bar" style="width:${pct}%"></span>` : ""}
        <span class="label">${avatar(p.name, p.avatar_path)} ${who(p)} ${reveal && n === top && top > 0 ? "👑" : ""}</span>${reveal ? html`<span class="n">${n} vote${n === 1 ? "" : "s"}</span>` : ""}</button>`;
    })}</div>
    ${s.phase === "question" ? (mine != null ? html`<p class="muted">Vote locked. Nobody knows who you picked 🤫</p>` : r.in_room ? html`<p class="faint">Tap who it sounds like. You can vote for yourself, no judgement.</p>` : html`<p class="muted">Just watching.</p>`) : ""}
    ${reveal ? html`<p class="faint">Most votes gets a 👑 point. Votes stay anonymous.</p>` : ""}</div>`;
}

function ratherView(r) {
  const s = r.state;
  const reveal = s.phase === "reveal" || s.phase === "done";
  const mine = r.my_answer;
  const total = (s.a ?? 0) + (s.b ?? 0);
  const side = (i, label) => {
    const n = i === 0 ? s.a : s.b;
    const pct = total ? Math.round((n / total) * 100) : 0;
    return html`<button class="opt big-opt ${reveal ? (s.majority === i ? "right" : "") : mine === i ? "picked" : ""}" type="button" data-move="${i}"
      ${s.phase === "question" && r.in_room && mine == null ? "" : "disabled"}>${reveal ? html`<span class="bar" style="width:${pct}%"></span>` : ""}
      <span class="label">${i === 0 ? "🅰️" : "🅱️"} ${label}${reveal && mine === i ? " (you)" : ""}</span>${reveal ? html`<span class="n">${n} · ${pct}%</span>` : ""}</button>`;
  };
  return html`<div class="card" style="display:grid;gap:var(--s3)">
    <div class="row between wrap"><span class="badge">Round ${s.q + 1} of ${s.total}</span><span class="faint">No wrong answers (okay, some wrong answers)</span></div>
    ${r.status === "playing" ? timerBlock(r, s.phase === "question" ? "picked" : "") : ""}
    <p class="quiz-q">${s.prompt}</p>
    <div class="stack" style="gap:var(--s2)">${side(0, s.option_a)}${side(1, s.option_b)}</div>
    ${s.phase === "question" ? (mine != null ? html`<p class="muted">Locked in. Waiting for the squad…</p>` : r.in_room ? html`<p class="faint">Pick the side most of the squad will pick. Majority scores a point.</p>` : html`<p class="muted">Just watching.</p>`) : ""}
    ${reveal ? html`<p><strong>${s.majority == null ? "Split down the middle. Nobody scores 😮" : mine === s.majority ? "You ran with the majority +1 🔥" : "You picked the minority. Bold."}</strong></p>` : ""}</div>`;
}

const dieFace = (n) => DICE[Math.max(1, Math.min(6, n)) - 1];
const diceNote = (d) => (d[0] === 6 && d[1] === 6 ? "Double six! Counts 13 🔥" : d[0] === 1 && d[1] === 1 ? "Snake eyes. Counts 0 😬" : `Total ${d[0] + d[1]}`);

function potView(r) {
  const s = r.state;
  const d = r.my_dice?.d;
  const decided = Boolean(r.my_dice?.decided);
  const pot = s.pot ?? r.stake * r.players.length;
  const head = html`<div class="pot-head"><div class="faint">The pot</div><strong style="font-size:1.6rem">${coins(pot)}</strong><div class="faint" style="font-size:var(--fs-xs)">${r.stake} each · ${r.players.length} players</div></div>`;
  if (r.status === "finished" && s.results) {
    const winners = (s.winners ?? []).map((id) => byId(r, id));
    return html`${head}<div class="card" style="padding:0;margin-top:var(--s3)"><table class="table" style="width:100%;text-align:left"><tbody>
      ${s.results.map((x) => html`<tr class="${(s.winners ?? []).includes(x.user_id) ? "win-row" : ""}"><td>${who(byId(r, x.user_id))}${x.rerolled ? html` <span class="badge">re-rolled</span>` : ""}</td>
        <td class="dice-cell">${dieFace(x.dice[0])} ${dieFace(x.dice[1])}</td><td style="text-align:right"><strong>${x.total}</strong></td></tr>`)}</tbody></table></div>
      <p style="text-align:center;margin-top:var(--s3);font-weight:700">${winners.length === 1 ? `${who(winners[0])} took the whole pot: ${pot} coins 🪙` : `Tie! Pot split between ${winners.map(who).join(" & ")} 🤝`}</p>`;
  }
  return html`${head}
    <div style="margin-top:var(--s4)">${timerBlock(r, "decided")}</div>
    ${r.in_room && d ? html`<div class="dice-big" aria-label="Your dice">${dieFace(d[0])} ${dieFace(d[1])}</div>
      <p style="text-align:center;font-weight:700">${diceNote(d)}${r.my_dice.rerolled ? " (re-rolled, final)" : ""}</p>
      ${decided ? html`<p class="muted" style="text-align:center">Locked in. Waiting for everyone to decide…</p>`
        : html`<div class="row" style="justify-content:center;gap:10px;margin-top:var(--s3)"><button class="btn primary" type="button" data-move="0">🧊 Hold</button>
          <button class="btn" type="button" data-move="1">🎲 Re-roll (final, no cap)</button></div>
          <p class="faint" style="text-align:center;margin-top:var(--s2);font-size:var(--fs-xs)">Highest total takes the pot. Double six counts 13, snake eyes counts 0. Re-rolling replaces your dice, even if the new ones are worse.</p>`}`
      : html`<p class="muted" style="text-align:center;margin-top:var(--s3)">Just watching. Dice stay secret until the reveal.</p>`}`;
}

const BOARDS = {
  tictactoe: tttView, connect4: c4View, rps: rpsView, clash: clashView, penalty: penaltyView, race: raceView,
  trivia: triviaView, emoji: triviaView, likely: likelyView, rather: ratherView, pot: potView,
};

function endView(r) {
  if (r.status !== "finished") {
    const canLeave = r.in_room && !(r.kind === "pot");
    return canLeave ? html`<div class="row" style="margin-top:var(--s4);justify-content:center"><button class="btn" type="button" data-leave>Leave game</button></div>` : "";
  }
  const me = state.user.id;
  const w = r.winner_id ? byId(r, r.winner_id) : null;
  const forfeit = r.state.forfeit ? byId(r, r.state.forfeit) : null;
  const split = r.kind === "pot" && (r.state.winners ?? []).length > 1;
  const title = r.state.abandoned ? "⏰ This game timed out"
    : w ? (w.user_id === me ? "🏆 You won! Absolute W." : r.in_room ? `💀 ${w.name} won. Take the L.` : `🎉 ${w.name} won!`)
    : split ? "🤝 Pot split. Nobody ate alone." : "🤝 It's a draw. Nobody ate.";
  return html`<div class="card win-banner" style="margin-top:var(--s4);text-align:center;display:grid;gap:var(--s3)">
    <h3 style="font-size:1.4rem">${title}</h3>
    ${forfeit ? html`<p class="muted">${forfeit.user_id === me ? "You" : forfeit.name} left the game 🏃</p>` : ""}
    <div class="row wrap" style="justify-content:center;gap:8px">
      ${r.in_room ? html`<button class="btn primary" type="button" data-again>${icon("refresh")} Run it back${r.stake ? ` (🪙 ${r.stake})` : ""}</button>` : ""}
      <button class="btn" type="button" data-back>All games</button>
      ${r.host_id === me ? html`<button class="btn danger" type="button" data-close-room>${icon("trash")} Close table</button>` : ""}</div></div>`;
}
