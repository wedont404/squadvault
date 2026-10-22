// Live multiplayer games for a squad: Tic-Tac-Toe, Connect 4, Rock-Paper-Scissors and a Trivia Race.
// The server is the referee (see supabase/migrations/012_multiplayer.sql). This file only draws what get_room
// returns and asks for moves. While a room is open it asks for fresh state every ~1.5 s; the lobby every 4 s.
import { state, isManagerRole } from "./state.js";
import { rpc } from "./supabase.js";
import { navigate } from "./router.js";
import { html } from "./utils.js";
import { $, mount, on, icon, avatar, freshView, toastError, confirmDialog, loadInto, setBusy, emptyState, skeletonList } from "./ui.js";

export const GAMES = {
  tictactoe: { name: "Tic-Tac-Toe", emoji: "❌⭕", players: "2 players", blurb: "Three in a row wins. Quick and friendly." },
  connect4: { name: "Connect 4", emoji: "🔴🟡", players: "2 players", blurb: "Drop discs and connect four before your friend does." },
  rps: { name: "Rock Paper Scissors", emoji: "✊✋✌️", players: "2 players", blurb: "First to 2 wins. Choices stay hidden until both have picked." },
  trivia: { name: "Trivia Race", emoji: "🧠", players: "2 to 12 players", blurb: "8 questions about Rwanda, Africa and money. Everyone answers at once, faster is better." },
};
const RPS = { 1: ["✊", "Rock"], 2: ["✋", "Paper"], 3: ["✌️", "Scissors"] };
const roomUrl = (id) => `/squad?tab=play&room=${encodeURIComponent(id)}`;
const LOBBY_URL = "/squad?tab=play";
const names = (players) => players.map((p) => (p.user_id === state.user.id ? "You" : p.name)).join(", ");

export async function mountPlay(host, group, isCurrent, roomId) {
  if (roomId) return mountRoom(host, group, isCurrent, roomId);
  return mountLobby(host, group, isCurrent);
}

// ---------------------------------------------------------------------------
// Lobby: pick a game, join an open table, see the leaderboard
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
    mount(view, html`
      <p class="muted" style="margin-bottom:var(--s4)">Play live with your squad. Open a table and your friends can join from their phones. Just for fun: no money, only bragging rights.</p>
      <div class="game-grid">${Object.entries(GAMES).map(([k, g]) => html`
        <div class="game-tile"><div class="emo" aria-hidden="true">${g.emoji}</div><h3>${g.name}</h3><p class="faint">${g.blurb}</p>
          <div class="row between wrap"><span class="badge">${g.players}</span><button class="btn sm primary" type="button" data-host="${k}">${icon("plus")} Host</button></div></div>`)}</div>

      <h2 class="h3" style="margin:var(--s5) 0 var(--s3)">Open tables</h2>
      ${live.length ? html`<div class="stack" style="gap:var(--s3)">${live.map((r) => roomRow(r, manager))}</div>`
        : emptyState({ iconName: "game", title: "No tables yet", text: "Host a game above, then tell your squad to open Squad → Play." })}

      ${data.leaderboard?.length ? html`<h2 class="h3" style="margin:var(--s5) 0 var(--s3);display:flex;align-items:center;gap:8px">${icon("trophy")} Squad leaderboard</h2>
        <div class="card" style="padding:0"><table class="table" style="width:100%;text-align:left"><thead><tr><th style="text-align:left">#</th><th style="text-align:left">Player</th><th style="text-align:left">Wins</th><th style="text-align:left">Played</th></tr></thead><tbody>
          ${data.leaderboard.map((p, i) => html`<tr><td>${i + 1}</td><td>${p.user_id === state.user.id ? html`<strong>${p.name} (you)</strong>` : p.name}</td><td><strong>${p.wins}</strong></td><td>${p.played}</td></tr>`)}
        </tbody></table></div>` : ""}

      ${done.length ? html`<h2 class="h3" style="margin:var(--s5) 0 var(--s3)">Recent results</h2>
        <div class="stack" style="gap:var(--s2)">${done.map((r) => html`<div class="room-row"><div><strong>${GAMES[r.kind]?.name ?? r.kind}</strong>
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
    try { const id = await rpc("create_room", { p_group_id: group.id, p_kind: b.dataset.host }); navigate(roomUrl(id)); }
    catch (err) { toastError(err); setBusy(b, false); }
  });
  on(view, "click", "[data-open]", (_, b) => navigate(roomUrl(b.dataset.open)));
  on(view, "click", "[data-join]", async (_, b) => {
    setBusy(b, true, "Joining…");
    try { await rpc("join_room", { p_room_id: b.dataset.join }); navigate(roomUrl(b.dataset.join)); }
    catch (err) { toastError(err); setBusy(b, false); refresh(true); }
  });
  on(view, "click", "[data-del-room]", async (_, b) => {
    if (!(await confirmDialog({ title: "Close this table?", message: "Everyone in it is sent back to the lobby.", confirmLabel: "Close table", danger: true }))) return;
    try { await rpc("delete_room", { p_room_id: b.dataset.delRoom }); refresh(true); } catch (err) { toastError(err); }
  });

  timer = setInterval(() => {
    if (!view.isConnected || !isCurrent()) return clearInterval(timer);
    if (!document.hidden) refresh();
  }, 4000);
}

function roomRow(r, manager) {
  const g = GAMES[r.kind];
  const full = r.players.length >= r.max_players;
  const mine = r.host_id === state.user.id;
  return html`<div class="room-row"><div><strong>${g?.emoji} ${g?.name ?? r.kind}</strong>
      <div class="faint" style="font-size:var(--fs-xs)">${r.players.length}/${r.max_players} · ${names(r.players)}</div></div>
    <div class="row" style="gap:8px"><span class="badge ${r.status === "playing" ? "pending" : "active"}">${r.status === "playing" ? "Playing" : "Waiting"}</span>
      ${r.in_room ? html`<button class="btn sm primary" type="button" data-open="${r.id}">Open</button>`
        : r.status === "lobby" && !full ? html`<button class="btn sm primary" type="button" data-join="${r.id}">Join</button>`
        : html`<button class="btn sm" type="button" data-open="${r.id}">Watch</button>`}
      ${mine || manager ? html`<button class="btn sm danger" type="button" data-del-room="${r.id}" aria-label="Close table">${icon("trash")}</button>` : ""}</div></div>`;
}

// ---------------------------------------------------------------------------
// One room
// ---------------------------------------------------------------------------
async function mountRoom(host, group, isCurrent, roomId) {
  const view = freshView(host);
  const me = state.user.id;
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
        <p>It may have been closed by the host.</p><button class="btn primary" type="button" data-back>Back to games</button></div>`);
    }
  };

  const paint = () => {
    const r = room;
    const g = GAMES[r.kind];
    $("[data-title]", view).textContent = `${g.emoji} ${g.name}`;
    mount($("[data-status]", view), html`<span class="badge ${r.status === "playing" ? "pending" : r.status === "lobby" ? "active" : ""}">${r.status === "lobby" ? "Waiting for players" : r.status === "playing" ? "Playing" : "Finished"}</span>`);
    if (r.status === "lobby") return mount(stage, lobbyView(r));
    mount(stage, html`${seatsView(r)}${r.kind === "tictactoe" ? tttView(r) : r.kind === "connect4" ? c4View(r) : r.kind === "rps" ? rpsView(r) : triviaView(r)}${endView(r)}`);
    tickCountdown();
  };

  // ---- countdown for trivia -------------------------------------------------
  const tickCountdown = () => {
    const r = room;
    if (!r || r.kind !== "trivia" || r.status !== "playing") return;
    const until = Date.parse(r.state.until);
    const left = until - (Date.now() + skew);
    const bar = $("[data-timer]", view);
    if (bar) {
      const total = r.state.phase === "question" ? 15000 : 5000;
      bar.style.width = `${Math.max(0, Math.min(100, (left / total) * 100))}%`;
      const t = $("[data-left]", view);
      if (t) t.textContent = `${Math.max(0, Math.ceil(left / 1000))}s`;
    }
    const key = `${r.state.q}-${r.state.phase}`;
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
    const live = room?.status === "playing" && room.kind !== "trivia";
    if (live && !(await confirmDialog({ title: "Leave this game?", message: "Leaving a live game counts as a loss.", confirmLabel: "Leave game", danger: true }))) return;
    try { await rpc("leave_room", { p_room_id: roomId }); navigate(LOBBY_URL); } catch (err) { toastError(err); }
  });
  on(view, "click", "[data-again]", async (_, b) => {
    setBusy(b, true, "Opening…");
    try { const id = await rpc("create_room", { p_group_id: group.id, p_kind: room.kind }); navigate(roomUrl(id)); }
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

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------
const byId = (r, id) => r.players.find((p) => p.user_id === id);

function lobbyView(r) {
  const me = state.user.id;
  const isHost = r.host_id === me;
  const n = r.players.length;
  return html`<div class="card" style="display:grid;gap:var(--s4)">
    <p class="muted">${GAMES[r.kind].blurb}</p>
    <div class="seats">${r.players.map((p) => html`<span class="seat">${avatar(p.name, p.avatar_path)}<span>${p.user_id === me ? "You" : p.name}${p.user_id === r.host_id ? " · host" : ""}</span></span>`)}</div>
    <p class="faint">${n} of ${r.max_players} players. ${n < 2 ? "Waiting for at least one more player. Tell your squad to open Squad → Play and tap Join." : isHost ? "Ready when you are." : "Waiting for the host to start."}</p>
    <div class="row wrap" style="gap:8px">
      ${!r.in_room ? (n < r.max_players ? html`<button class="btn primary" type="button" data-join-room>Join this game</button>` : html`<span class="badge">Table is full</span>`) : ""}
      ${isHost ? html`<button class="btn primary" type="button" data-start ${n < 2 ? "disabled" : ""}>${icon("game")} Start game</button>` : ""}
      ${r.in_room ? html`<button class="btn" type="button" data-leave>Leave</button>` : ""}
      ${isHost ? html`<button class="btn danger" type="button" data-close-room>${icon("trash")} Close table</button>` : ""}</div></div>`;
}

function seatsView(r) {
  const showScore = r.kind === "trivia" || r.kind === "rps";
  const turn = r.status === "playing" && (r.kind === "tictactoe" || r.kind === "connect4") ? r.state.turn : null;
  const marks = r.kind === "tictactoe" ? ["❌", "⭕"] : r.kind === "connect4" ? ["🔴", "🟡"] : [];
  const sorted = r.kind === "trivia" ? [...r.players].sort((a, b) => b.score - a.score || a.seat - b.seat) : r.players;
  return html`<div class="seats" style="margin-bottom:var(--s4)">${sorted.map((p) => html`
    <span class="seat ${turn === p.seat ? "turn" : ""}">${avatar(p.name, p.avatar_path)}<span>${marks[p.seat] ?? ""} ${p.user_id === state.user.id ? "You" : p.name}</span>
      ${showScore ? html`<span class="pts">${p.score}</span>` : ""}</span>`)}</div>`;
}

function turnLine(r) {
  if (r.status !== "playing") return "";
  const mine = r.in_room && r.state.turn === r.me_seat;
  const who = r.players.find((p) => p.seat === r.state.turn)?.name ?? "your friend";
  if (!r.in_room) return html`<p class="muted" style="text-align:center;margin-bottom:var(--s3)">Watching. It's ${who}'s turn.</p>`;
  return html`<p style="text-align:center;margin-bottom:var(--s3);font-weight:700;${mine ? "color:var(--green)" : "color:var(--muted)"}">${mine ? "Your turn" : `Waiting for ${who}…`}</p>`;
}

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
    const res = last.result === -1 ? "A draw. Go again." : r.in_room ? (last.result === r.me_seat ? "You won that round!" : "You lost that round.") : `${r.players.find((p) => p.seat === last.result)?.name} won that round.`;
    lastLine = html`<p style="text-align:center;margin-top:var(--s3)">${RPS[mine][0]} vs ${RPS[theirs][0]} — <strong>${res}</strong></p>`;
  }
  const waiting = r.status === "playing" && r.my_choice != null;
  return html`<p style="text-align:center;margin-bottom:var(--s3);font-weight:700">${r.status === "playing" ? `Round ${s.round} · first to ${s.target} wins` : "Final score"}</p>
    <div class="rps-row">${[1, 2, 3].map((n) => html`<button class="rps-btn ${r.my_choice === n ? "picked" : ""}" type="button" data-move="${n}" ${can ? "" : "disabled"}>
      <span class="big" aria-hidden="true">${RPS[n][0]}</span><span>${RPS[n][1]}</span></button>`)}</div>
    ${waiting ? html`<p class="muted" style="text-align:center;margin-top:var(--s3)">You picked ${RPS[r.my_choice][1]}. Waiting for your friend…</p>`
      : r.status === "playing" && !r.in_room ? html`<p class="muted" style="text-align:center;margin-top:var(--s3)">Watching. ${s.moved?.length ? "One player has picked." : "Nobody has picked yet."}</p>` : ""}
    ${lastLine}`;
}

function triviaView(r) {
  const s = r.state;
  const q = s.q + 1;
  if (r.status === "finished" && !s.question) return "";
  const reveal = s.phase === "reveal" || s.phase === "done";
  const answered = (s.answered ?? []).length;
  const mine = r.my_answer;
  const myRes = reveal ? s.results?.find((x) => x.user_id === state.user.id) : null;
  return html`<div class="card" style="display:grid;gap:var(--s3)">
    <div class="row between wrap"><span class="badge">Question ${q} of ${s.total}</span><span class="faint">${s.topic}</span></div>
    ${s.phase === "question" ? html`<div class="timer" aria-hidden="true"><i data-timer style="width:100%"></i></div>
      <div class="row between"><span class="faint">${answered} of ${r.players.length} answered</span><strong data-left>15s</strong></div>` : ""}
    <p class="quiz-q">${s.question}</p>
    <div class="stack" style="gap:var(--s2)">${s.options.map((o, i) => html`
      <button class="opt ${reveal ? (i === s.correct ? "right" : myRes?.choice === i ? "wrong" : "") : mine === i ? "picked" : ""}" type="button" data-move="${i}"
        ${s.phase === "question" && r.in_room && mine == null ? "" : "disabled"}><span class="label">${"ABCD"[i]}. ${o}</span>
        ${reveal && i === s.correct ? html`<span class="n">${icon("check")}</span>` : ""}</button>`)}</div>
    ${s.phase === "question" ? (mine != null ? html`<p class="muted">Locked in. Waiting for the others…</p>` : r.in_room ? html`<p class="faint">Answer fast: quicker correct answers score more (100 to 150 points).</p>` : html`<p class="muted">Watching.</p>`) : ""}
    ${reveal ? html`<p><strong>${myRes ? (myRes.points > 0 ? `Correct! +${myRes.points} points` : myRes.choice == null ? "Too slow this time." : "Not this time.") : "Answer revealed."}</strong>
      ${s.phase === "reveal" ? html`<span class="faint"> Next question in a moment…</span>` : ""}</p>` : ""}
    ${s.phase === "reveal" ? html`<div class="timer" aria-hidden="true"><i data-timer style="width:100%"></i></div><span hidden data-left></span>` : ""}</div>`;
}

function endView(r) {
  if (r.status !== "finished") {
    return r.in_room ? html`<div class="row" style="margin-top:var(--s4);justify-content:center"><button class="btn" type="button" data-leave>Leave game</button></div>` : "";
  }
  const me = state.user.id;
  const w = r.winner_id ? byId(r, r.winner_id) : null;
  const forfeit = r.state.forfeit ? byId(r, r.state.forfeit) : null;
  const title = r.state.abandoned ? "This game timed out" : w ? (w.user_id === me ? "🏆 You won!" : `🎉 ${w.name} won!`) : "🤝 It's a draw";
  return html`<div class="card win-banner" style="margin-top:var(--s4);text-align:center;display:grid;gap:var(--s3)">
    <h3 style="font-size:1.4rem">${title}</h3>
    ${forfeit ? html`<p class="muted">${forfeit.user_id === me ? "You" : forfeit.name} left the game.</p>` : ""}
    <div class="row wrap" style="justify-content:center;gap:8px">
      ${r.in_room ? html`<button class="btn primary" type="button" data-again>${icon("refresh")} Play again</button>` : ""}
      <button class="btn" type="button" data-back>All games</button>
      ${r.host_id === me ? html`<button class="btn danger" type="button" data-close-room>${icon("trash")} Close table</button>` : ""}</div></div>`;
}
