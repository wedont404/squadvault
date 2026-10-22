-- SQUADVAULT UPDATE 012: live multiplayer games (Tic-Tac-Toe, Connect 4, Rock-Paper-Scissors, Trivia Race). Needs UPDATES 007-011 first.
-- Paste the WHOLE file into Supabase -> SQL Editor -> Run. Safe to run again. Never deletes your data.

-- 012_multiplayer.sql
-- 012_multiplayer.sql
-- Live multiplayer games inside a squad: Tic-Tac-Toe, Connect 4, Rock-Paper-Scissors (first to 2) and a Trivia Race
-- where everyone answers the same question at the same time (faster correct answers score more).
--
-- Rules of the house: the SERVER is the referee. Browsers only ask to join, start or make a move; every move is
-- checked (is it your turn, is the cell free, is the time up) inside SECURITY DEFINER functions. Hidden information
-- (a Rock-Paper-Scissors choice before both players have chosen, trivia answers before the reveal) lives in a column
-- nobody can read directly. No money is involved: the app keeps wins and a squad leaderboard, nothing else.
--
-- Trivia has no background worker: the room moves on whenever somebody asks for its state (the screens do that every
-- second or two), which is enough for a live game and needs no extra infrastructure.
-- Safe to re-run. Prerequisites: 001-011.

begin;

-- ---------------------------------------------------------------------------
-- Tables (no direct access for browsers)
-- ---------------------------------------------------------------------------
create table if not exists public.trivia_questions (
  id serial primary key,
  topic text not null,
  question text not null unique,
  options text[] not null check (array_length(options, 1) = 4),
  answer smallint not null check (answer between 0 and 3)
);

create table if not exists public.game_rooms (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.savings_groups (id) on delete cascade,
  kind text not null check (kind in ('tictactoe', 'connect4', 'rps', 'trivia')),
  status text not null default 'lobby' check (status in ('lobby', 'playing', 'finished')),
  host_id uuid not null references auth.users (id) on delete cascade,
  state jsonb not null default '{}'::jsonb,
  secret jsonb not null default '{}'::jsonb,
  winner_id uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  finished_at timestamptz
);
create index if not exists game_rooms_group_idx on public.game_rooms (group_id, created_at desc);

create table if not exists public.game_room_players (
  room_id uuid not null references public.game_rooms (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  seat smallint not null check (seat >= 0),
  score integer not null default 0,
  joined_at timestamptz not null default now(),
  primary key (room_id, user_id),
  unique (room_id, seat)
);
create index if not exists game_room_players_user_idx on public.game_room_players (user_id);

alter table public.trivia_questions enable row level security;
alter table public.game_rooms enable row level security;
alter table public.game_room_players enable row level security;
revoke all on public.trivia_questions, public.game_rooms, public.game_room_players from anon, authenticated;
grant select, insert, update, delete on public.trivia_questions, public.game_rooms, public.game_room_players to service_role;
revoke all on sequence public.trivia_questions_id_seq from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Question bank (Rwanda, Africa, general knowledge, money sense)
-- ---------------------------------------------------------------------------
insert into public.trivia_questions (topic, question, options, answer) values
 ('Rwanda', 'What is the capital city of Rwanda?', array['Huye', 'Musanze', 'Kigali', 'Rubavu'], 2),
 ('Rwanda', 'Which is the largest lake inside Rwanda''s borders?', array['Lake Kivu', 'Lake Muhazi', 'Lake Ruhondo', 'Lake Burera'], 0),
 ('Rwanda', 'Which animals do visitors trek to see in Volcanoes National Park?', array['Lions', 'Mountain gorillas', 'Elephants', 'Giraffes'], 1),
 ('Rwanda', 'What is the currency of Rwanda?', array['Rwandan franc', 'Rwandan shilling', 'Rwandan dollar', 'Rwandan birr'], 0),
 ('Rwanda', 'Umuganda, the national community work day, happens on which day?', array['Every Friday', 'The first Monday of the month', 'Every Sunday', 'The last Saturday of the month'], 3),
 ('Rwanda', 'On which date is Rwanda''s Independence Day celebrated?', array['4 July', '1 July', '1 January', '1 August'], 1),
 ('Rwanda', 'Which is the highest volcano in Rwanda?', array['Bisoke', 'Sabyinyo', 'Karisimbi', 'Muhabura'], 2),
 ('Rwanda', 'In which part of Rwanda is Akagera National Park?', array['East', 'West', 'North', 'South-west'], 0),
 ('Rwanda', 'Which national park has a canopy walkway and is home to chimpanzees?', array['Akagera', 'Nyungwe', 'Volcanoes', 'Gishwati'], 1),
 ('Rwanda', 'What is an "ikimina"?', array['A traditional dance', 'A cooking pot', 'A savings group', 'A school uniform'], 2),
 ('Rwanda', 'Which of these is a traditional Rwandan dance?', array['Salsa', 'Intore', 'Flamenco', 'Tango'], 1),
 ('Rwanda', 'What is an "agaseke"?', array['A woven basket', 'A drum', 'A river', 'A type of bean'], 0),
 ('Rwanda', 'Umuganura is a celebration of what?', array['A wedding', 'Independence', 'The harvest', 'A new school year'], 2),
 ('Rwanda', 'Which country does NOT share a border with Rwanda?', array['Uganda', 'Tanzania', 'Burundi', 'Kenya'], 3),
 ('Rwanda', 'Which of these is NOT an official language of Rwanda?', array['Kinyarwanda', 'English', 'Spanish', 'French'], 2),
 ('Rwanda', 'What is the nickname of Rwanda''s national football team?', array['Amavubi', 'Harambee Stars', 'Cranes', 'Taifa Stars'], 0),
 ('Rwanda', 'Inyambo, famous in Rwandan culture, are cattle known for their...', array['Short tails', 'Spotted coats', 'Long horns', 'No horns'], 2),
 ('Africa', 'Which city is the capital of Kenya?', array['Mombasa', 'Nairobi', 'Kisumu', 'Nakuru'], 1),
 ('Africa', 'Which city is the capital of Uganda?', array['Kampala', 'Entebbe', 'Jinja', 'Gulu'], 0),
 ('Africa', 'Which city is the official capital of Tanzania?', array['Dar es Salaam', 'Arusha', 'Dodoma', 'Mwanza'], 2),
 ('Africa', 'What is the longest river in Africa?', array['Congo', 'Niger', 'Zambezi', 'Nile'], 3),
 ('Africa', 'What is the highest mountain in Africa?', array['Mount Kenya', 'Kilimanjaro', 'Karisimbi', 'Mount Stanley'], 1),
 ('Africa', 'What is the largest lake in Africa?', array['Lake Victoria', 'Lake Tanganyika', 'Lake Malawi', 'Lake Kivu'], 0),
 ('General', 'Which is the largest planet in our solar system?', array['Saturn', 'Earth', 'Jupiter', 'Neptune'], 2),
 ('General', 'What is the chemical formula of water?', array['CO2', 'H2O', 'O2', 'NaCl'], 1),
 ('General', 'What is 12 x 12?', array['124', '122', '134', '144'], 3),
 ('General', 'How many bones does an adult human body have?', array['206', '186', '256', '306'], 0),
 ('General', 'Which is the fastest land animal?', array['Lion', 'Horse', 'Cheetah', 'Antelope'], 2),
 ('General', 'Which is the largest ocean on Earth?', array['Atlantic', 'Indian', 'Arctic', 'Pacific'], 3),
 ('General', 'How many continents are there?', array['5', '6', '7', '8'], 2),
 ('General', 'Which country won the 2022 FIFA World Cup?', array['Argentina', 'France', 'Brazil', 'Croatia'], 0),
 ('General', 'Which gas do plants take in from the air?', array['Oxygen', 'Carbon dioxide', 'Nitrogen', 'Hydrogen'], 1),
 ('General', 'What is the square root of 81?', array['7', '8', '9', '11'], 2),
 ('General', 'What is the smallest prime number?', array['0', '1', '3', '2'], 3),
 ('General', 'Which organ pumps blood around the body?', array['Heart', 'Liver', 'Lungs', 'Kidney'], 0),
 ('General', 'How many days are there in a leap year?', array['365', '366', '364', '367'], 1),
 ('General', 'What is the hardest natural material?', array['Gold', 'Iron', 'Diamond', 'Granite'], 2),
 ('General', 'The Sun is a...', array['Planet', 'Moon', 'Comet', 'Star'], 3),
 ('Money sense', 'You save 2,000 RWF every week. How much do you have after 10 weeks?', array['20,000 RWF', '12,000 RWF', '22,000 RWF', '2,000 RWF'], 0),
 ('Money sense', 'What is 10% of 50,000 RWF?', array['500 RWF', '50 RWF', '5,000 RWF', '10,000 RWF'], 2),
 ('Money sense', '5 members each put in 3,000 RWF. What is the total?', array['8,000 RWF', '15,000 RWF', '12,000 RWF', '18,000 RWF'], 1),
 ('Money sense', 'A goal costs 120,000 RWF and 12 people share it equally. How much does each person pay?', array['1,000 RWF', '12,000 RWF', '20,000 RWF', '10,000 RWF'], 3),
 ('Money sense', 'Which of these is a "want" and not a "need"?', array['A new game console', 'Clean water', 'School fees', 'Food'], 0),
 ('Money sense', 'What is a budget?', array['A kind of loan', 'A plan for how you will spend and save', 'A bank account', 'A tax'], 1)
on conflict (question) do nothing;

-- ---------------------------------------------------------------------------
-- Private helpers
-- ---------------------------------------------------------------------------
create or replace function private.room_max_players(p_kind text)
returns integer language sql immutable set search_path = '' as $$
  select case p_kind when 'trivia' then 12 else 2 end
$$;

-- the three cells that make a line, or null
create or replace function private.ttt_line(p_board text, p_mark text)
returns integer[] language plpgsql immutable set search_path = '' as $$
declare
  v_lines integer[] := array[0,1,2, 3,4,5, 6,7,8, 0,3,6, 1,4,7, 2,5,8, 0,4,8, 2,4,6];
  i integer;
begin
  for i in 0..7 loop
    if substr(p_board, v_lines[i*3+1] + 1, 1) = p_mark
       and substr(p_board, v_lines[i*3+2] + 1, 1) = p_mark
       and substr(p_board, v_lines[i*3+3] + 1, 1) = p_mark then
      return array[v_lines[i*3+1], v_lines[i*3+2], v_lines[i*3+3]];
    end if;
  end loop;
  return null;
end;
$$;

-- the four cells that make a line on a 6 rows x 7 columns board (row 0 is the top), or null
create or replace function private.c4_line(p_board text, p_mark text)
returns integer[] language plpgsql immutable set search_path = '' as $$
declare
  v_dr integer[] := array[0, 1, 1, 1];
  v_dc integer[] := array[1, 0, 1, -1];
  r integer; c integer; d integer; k integer; rr integer; cc integer; v_ok boolean;
begin
  for r in 0..5 loop
    for c in 0..6 loop
      if substr(p_board, r*7 + c + 1, 1) = p_mark then
        for d in 1..4 loop
          v_ok := true;
          for k in 1..3 loop
            rr := r + v_dr[d]*k; cc := c + v_dc[d]*k;
            if rr < 0 or rr > 5 or cc < 0 or cc > 6 or substr(p_board, rr*7 + cc + 1, 1) <> p_mark then v_ok := false; exit; end if;
          end loop;
          if v_ok then
            return array[r*7 + c, (r + v_dr[d])*7 + c + v_dc[d], (r + 2*v_dr[d])*7 + c + 2*v_dc[d], (r + 3*v_dr[d])*7 + c + 3*v_dc[d]];
          end if;
        end loop;
      end if;
    end loop;
  end loop;
  return null;
end;
$$;

create or replace function private.room_finish(p_room uuid, p_winner uuid, p_state jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.game_rooms
     set status = 'finished', winner_id = p_winner, state = p_state, finished_at = now(), updated_at = now()
   where id = p_room;
end;
$$;

-- Opens trivia question number p_idx (0-based). Stores who may answer and a fifteen second clock.
create or replace function private.trivia_open(p_room uuid, p_idx integer)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.game_rooms%rowtype;
  q public.trivia_questions%rowtype;
begin
  select * into r from public.game_rooms where id = p_room;
  select * into q from public.trivia_questions where id = (r.secret -> 'ids' ->> p_idx)::integer;
  update public.game_rooms
     set state = jsonb_build_object(
           'q', p_idx, 'total', jsonb_array_length(r.secret -> 'ids'), 'phase', 'question', 'topic', q.topic,
           'question', q.question, 'options', to_jsonb(q.options),
           'until', now() + interval '15 seconds', 'answered', '[]'::jsonb),
         secret = jsonb_set(r.secret, '{answers}', '{}'::jsonb),
         updated_at = now()
   where id = p_room;
end;
$$;

-- Moves a trivia room forward when it is time: question -> reveal (everyone answered or time is up),
-- reveal -> next question (or the end). The caller must already hold the row lock.
create or replace function private.trivia_tick(p_room uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.game_rooms%rowtype;
  v_idx integer; v_total integer; v_correct integer; v_results jsonb; v_winner uuid; v_top integer;
begin
  select * into r from public.game_rooms where id = p_room;
  if r.id is null or r.kind <> 'trivia' or r.status <> 'playing' then return; end if;
  v_idx := (r.state ->> 'q')::integer;
  v_total := (r.state ->> 'total')::integer;

  if r.state ->> 'phase' = 'question' then
    if now() >= (r.state ->> 'until')::timestamptz
       or (select count(*) from jsonb_object_keys(r.secret -> 'answers')) >= (select count(*) from public.game_room_players where room_id = p_room) then
      select answer into v_correct from public.trivia_questions where id = (r.secret -> 'ids' ->> v_idx)::integer;
      select coalesce(jsonb_agg(jsonb_build_object('user_id', x.user_id, 'choice', x.c, 'points', x.p) order by x.seat), '[]'::jsonb)
        into v_results
        from (select pl.user_id, pl.seat,
                     (r.secret -> 'answers' -> pl.user_id::text ->> 'c')::integer as c,
                     case when (r.secret -> 'answers' -> pl.user_id::text ->> 'c')::integer = v_correct then
                       100 + floor(50 * greatest(0, extract(epoch from ((r.state ->> 'until')::timestamptz - (r.secret -> 'answers' -> pl.user_id::text ->> 'at')::timestamptz))) / 15)::integer
                     else 0 end as p
                from public.game_room_players pl where pl.room_id = p_room) x;
      update public.game_room_players gp
         set score = gp.score + (e ->> 'points')::integer
        from jsonb_array_elements(v_results) e
       where gp.room_id = p_room and gp.user_id = (e ->> 'user_id')::uuid;
      update public.game_rooms
         set state = r.state || jsonb_build_object('phase', 'reveal', 'correct', v_correct, 'results', v_results, 'until', now() + interval '5 seconds'),
             updated_at = now()
       where id = p_room;
    end if;
  elsif r.state ->> 'phase' = 'reveal' and now() >= (r.state ->> 'until')::timestamptz then
    if v_idx + 1 < v_total then
      perform private.trivia_open(p_room, v_idx + 1);
    else
      select max(score) into v_top from public.game_room_players where room_id = p_room;
      if v_top > 0 and (select count(*) from public.game_room_players where room_id = p_room and score = v_top) = 1 then
        select user_id into v_winner from public.game_room_players where room_id = p_room and score = v_top;
      end if;
      perform private.room_finish(p_room, v_winner, r.state || jsonb_build_object('phase', 'done'));
    end if;
  end if;
end;
$$;

revoke all on function private.room_max_players(text), private.ttt_line(text, text), private.c4_line(text, text),
  private.room_finish(uuid, uuid, jsonb), private.trivia_open(uuid, integer), private.trivia_tick(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Lobby: create, join, leave, start, delete
-- ---------------------------------------------------------------------------
create or replace function public.create_room(p_group_id uuid, p_kind text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or not private.is_group_member(p_group_id) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if p_kind is null or p_kind not in ('tictactoe', 'connect4', 'rps', 'trivia') then
    raise exception 'invalid_game' using errcode = '22023';
  end if;
  if (select count(*) from public.game_rooms where group_id = p_group_id and host_id = v_uid and status <> 'finished') >= 3 then
    raise exception 'too_many_games' using errcode = 'P0001';
  end if;
  insert into public.game_rooms (group_id, kind, host_id) values (p_group_id, p_kind, v_uid) returning id into v_id;
  insert into public.game_room_players (room_id, user_id, seat) values (v_id, v_uid, 0);
  return v_id;
end;
$$;

create or replace function public.join_room(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  r public.game_rooms%rowtype;
  v_seat integer;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into r from public.game_rooms where id = p_room_id for update;
  if r.id is null or not private.is_group_member(r.group_id) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if exists (select 1 from public.game_room_players where room_id = p_room_id and user_id = v_uid) then return; end if;
  if r.status <> 'lobby' then raise exception 'game_started' using errcode = 'P0001'; end if;
  select min(s) into v_seat from generate_series(0, private.room_max_players(r.kind) - 1) s
   where not exists (select 1 from public.game_room_players where room_id = p_room_id and seat = s);
  if v_seat is null then raise exception 'game_full' using errcode = 'P0001'; end if;
  insert into public.game_room_players (room_id, user_id, seat) values (p_room_id, v_uid, v_seat);
  update public.game_rooms set updated_at = now() where id = p_room_id;
end;
$$;

-- In the lobby: step out (the host passes the room on, or it closes when empty).
-- During a two-player game: leaving forfeits, so the other person wins.
create or replace function public.leave_room(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  r public.game_rooms%rowtype;
  v_other uuid;
  v_next uuid;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into r from public.game_rooms where id = p_room_id for update;
  if r.id is null or not exists (select 1 from public.game_room_players where room_id = p_room_id and user_id = v_uid) then return; end if;
  if r.status = 'lobby' then
    delete from public.game_room_players where room_id = p_room_id and user_id = v_uid;
    select user_id into v_next from public.game_room_players where room_id = p_room_id order by seat limit 1;
    if v_next is null then
      delete from public.game_rooms where id = p_room_id;
    elsif r.host_id = v_uid then
      update public.game_rooms set host_id = v_next, updated_at = now() where id = p_room_id;
    end if;
  elsif r.status = 'playing' and r.kind <> 'trivia' then
    select user_id into v_other from public.game_room_players where room_id = p_room_id and user_id <> v_uid limit 1;
    perform private.room_finish(p_room_id, v_other, r.state || jsonb_build_object('forfeit', v_uid));
  end if;
end;
$$;

create or replace function public.start_room(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  r public.game_rooms%rowtype;
  v_ids jsonb;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into r from public.game_rooms where id = p_room_id for update;
  if r.id is null or not private.is_group_member(r.group_id) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if r.host_id <> v_uid then raise exception 'not_allowed' using errcode = '42501'; end if;
  if r.status <> 'lobby' then raise exception 'game_started' using errcode = 'P0001'; end if;
  if (select count(*) from public.game_room_players where room_id = p_room_id) < 2 then
    raise exception 'not_enough_players' using errcode = 'P0001';
  end if;

  if r.kind = 'tictactoe' then
    update public.game_rooms set status = 'playing', state = jsonb_build_object('board', '.........', 'turn', 0), updated_at = now() where id = p_room_id;
  elsif r.kind = 'connect4' then
    update public.game_rooms set status = 'playing', state = jsonb_build_object('board', repeat('.', 42), 'turn', 0), updated_at = now() where id = p_room_id;
  elsif r.kind = 'rps' then
    update public.game_rooms set status = 'playing',
      state = jsonb_build_object('round', 1, 'wins', jsonb_build_array(0, 0), 'target', 2, 'moved', '[]'::jsonb),
      secret = jsonb_build_object('choices', '{}'::jsonb), updated_at = now() where id = p_room_id;
  else
    select jsonb_agg(id) into v_ids from (select id from public.trivia_questions order by random() limit 8) q;
    update public.game_rooms set status = 'playing', secret = jsonb_build_object('ids', v_ids, 'answers', '{}'::jsonb), updated_at = now() where id = p_room_id;
    perform private.trivia_open(p_room_id, 0);
  end if;
end;
$$;

create or replace function public.delete_room(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  r public.game_rooms%rowtype;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into r from public.game_rooms where id = p_room_id;
  if r.id is null then return; end if;
  if r.host_id <> v_uid and not private.is_group_manager(r.group_id) then raise exception 'not_allowed' using errcode = '42501'; end if;
  delete from public.game_rooms where id = p_room_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- The one move function: cell (0-8), column (0-6), choice (1 rock, 2 paper, 3 scissors) or option (0-3)
-- ---------------------------------------------------------------------------
create or replace function public.make_move(p_room_id uuid, p_move integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  r public.game_rooms%rowtype;
  me public.game_room_players%rowtype;
  v_board text; v_mark text; v_line integer[]; v_row integer; v_i integer;
  v_choices jsonb; v_c0 integer; v_c1 integer; v_res integer; v_wins jsonb; v_w0 integer; v_w1 integer; v_round integer; v_win_seat integer; v_win uuid;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into r from public.game_rooms where id = p_room_id for update;
  if r.id is null or not private.is_group_member(r.group_id) then raise exception 'not_allowed' using errcode = '42501'; end if;
  select * into me from public.game_room_players where room_id = p_room_id and user_id = v_uid;
  if me.user_id is null then raise exception 'not_in_game' using errcode = '42501'; end if;
  if r.kind = 'trivia' then
    perform private.trivia_tick(p_room_id);
    select * into r from public.game_rooms where id = p_room_id;
  end if;
  if r.status <> 'playing' then raise exception 'game_over' using errcode = 'P0001'; end if;
  if p_move is null then raise exception 'invalid_move' using errcode = '22023'; end if;

  -- Tic-Tac-Toe ------------------------------------------------------------
  if r.kind = 'tictactoe' then
    if (r.state ->> 'turn')::integer <> me.seat then raise exception 'not_your_turn' using errcode = 'P0001'; end if;
    if p_move < 0 or p_move > 8 then raise exception 'invalid_move' using errcode = '22023'; end if;
    v_board := r.state ->> 'board';
    if substr(v_board, p_move + 1, 1) <> '.' then raise exception 'cell_taken' using errcode = 'P0001'; end if;
    v_mark := case when me.seat = 0 then 'X' else 'O' end;
    v_board := overlay(v_board placing v_mark from p_move + 1 for 1);
    v_line := private.ttt_line(v_board, v_mark);
    if v_line is not null then
      update public.game_room_players set score = 1 where room_id = p_room_id and user_id = v_uid;
      perform private.room_finish(p_room_id, v_uid, jsonb_build_object('board', v_board, 'turn', me.seat, 'last', p_move, 'line', to_jsonb(v_line)));
    elsif position('.' in v_board) = 0 then
      perform private.room_finish(p_room_id, null, jsonb_build_object('board', v_board, 'turn', me.seat, 'last', p_move, 'draw', true));
    else
      update public.game_rooms set state = jsonb_build_object('board', v_board, 'turn', 1 - me.seat, 'last', p_move), updated_at = now() where id = p_room_id;
    end if;

  -- Connect 4 --------------------------------------------------------------
  elsif r.kind = 'connect4' then
    if (r.state ->> 'turn')::integer <> me.seat then raise exception 'not_your_turn' using errcode = 'P0001'; end if;
    if p_move < 0 or p_move > 6 then raise exception 'invalid_move' using errcode = '22023'; end if;
    v_board := r.state ->> 'board';
    v_row := null;
    for v_i in reverse 5..0 loop
      if substr(v_board, v_i*7 + p_move + 1, 1) = '.' then v_row := v_i; exit; end if;
    end loop;
    if v_row is null then raise exception 'column_full' using errcode = 'P0001'; end if;
    v_mark := case when me.seat = 0 then 'R' else 'Y' end;
    v_board := overlay(v_board placing v_mark from v_row*7 + p_move + 1 for 1);
    v_line := private.c4_line(v_board, v_mark);
    if v_line is not null then
      update public.game_room_players set score = 1 where room_id = p_room_id and user_id = v_uid;
      perform private.room_finish(p_room_id, v_uid, jsonb_build_object('board', v_board, 'turn', me.seat, 'last', v_row*7 + p_move, 'line', to_jsonb(v_line)));
    elsif position('.' in v_board) = 0 then
      perform private.room_finish(p_room_id, null, jsonb_build_object('board', v_board, 'turn', me.seat, 'last', v_row*7 + p_move, 'draw', true));
    else
      update public.game_rooms set state = jsonb_build_object('board', v_board, 'turn', 1 - me.seat, 'last', v_row*7 + p_move), updated_at = now() where id = p_room_id;
    end if;

  -- Rock-Paper-Scissors, first to 2 -------------------------------------------
  elsif r.kind = 'rps' then
    if p_move < 1 or p_move > 3 then raise exception 'invalid_move' using errcode = '22023'; end if;
    v_choices := coalesce(r.secret -> 'choices', '{}'::jsonb);
    if v_choices ? me.seat::text then raise exception 'already_moved' using errcode = 'P0001'; end if;
    v_choices := v_choices || jsonb_build_object(me.seat::text, p_move);
    if not (v_choices ? '0' and v_choices ? '1') then
      update public.game_rooms
         set secret = jsonb_set(r.secret, '{choices}', v_choices),
             state = jsonb_set(r.state, '{moved}', coalesce(r.state -> 'moved', '[]'::jsonb) || to_jsonb(me.seat)),
             updated_at = now()
       where id = p_room_id;
    else
      v_c0 := (v_choices ->> '0')::integer; v_c1 := (v_choices ->> '1')::integer;
      v_res := case when v_c0 = v_c1 then -1
                    when (v_c0 = 1 and v_c1 = 3) or (v_c0 = 2 and v_c1 = 1) or (v_c0 = 3 and v_c1 = 2) then 0
                    else 1 end;
      v_w0 := (r.state -> 'wins' ->> 0)::integer + case when v_res = 0 then 1 else 0 end;
      v_w1 := (r.state -> 'wins' ->> 1)::integer + case when v_res = 1 then 1 else 0 end;
      v_round := (r.state ->> 'round')::integer;
      v_wins := jsonb_build_array(v_w0, v_w1);
      update public.game_room_players set score = v_w0 where room_id = p_room_id and seat = 0;
      update public.game_room_players set score = v_w1 where room_id = p_room_id and seat = 1;
      if v_w0 >= 2 or v_w1 >= 2 then
        v_win_seat := case when v_w0 >= 2 then 0 else 1 end;
        select user_id into v_win from public.game_room_players where room_id = p_room_id and seat = v_win_seat;
        perform private.room_finish(p_room_id, v_win, jsonb_build_object('round', v_round, 'wins', v_wins, 'target', 2, 'moved', '[]'::jsonb,
          'last', jsonb_build_object('c', jsonb_build_array(v_c0, v_c1), 'result', v_res)));
      else
        update public.game_rooms
           set secret = jsonb_set(r.secret, '{choices}', '{}'::jsonb),
               state = jsonb_build_object('round', v_round + 1, 'wins', v_wins, 'target', 2, 'moved', '[]'::jsonb,
                         'last', jsonb_build_object('c', jsonb_build_array(v_c0, v_c1), 'result', v_res)),
               updated_at = now()
         where id = p_room_id;
      end if;
    end if;

  -- Trivia race ------------------------------------------------------------
  else
    if r.state ->> 'phase' <> 'question' or now() >= (r.state ->> 'until')::timestamptz then
      raise exception 'too_late' using errcode = 'P0001';
    end if;
    if p_move < 0 or p_move > 3 then raise exception 'invalid_move' using errcode = '22023'; end if;
    if (r.secret -> 'answers') ? v_uid::text then raise exception 'already_moved' using errcode = 'P0001'; end if;
    update public.game_rooms
       set secret = jsonb_set(r.secret, '{answers}', coalesce(r.secret -> 'answers', '{}'::jsonb) || jsonb_build_object(v_uid::text, jsonb_build_object('c', p_move, 'at', now()))),
           state = jsonb_set(r.state, '{answered}', coalesce(r.state -> 'answered', '[]'::jsonb) || to_jsonb(v_uid)),
           updated_at = now()
     where id = p_room_id;
    perform private.trivia_tick(p_room_id);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Reading: one room (public parts only), and the lobby with a leaderboard
-- ---------------------------------------------------------------------------
create or replace function public.get_room(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  r public.game_rooms%rowtype;
  v_me public.game_room_players%rowtype;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into r from public.game_rooms where id = p_room_id;
  if r.id is null or not private.is_group_member(r.group_id) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if r.kind = 'trivia' and r.status = 'playing' then
    perform 1 from public.game_rooms where id = p_room_id for update;
    perform private.trivia_tick(p_room_id);
    select * into r from public.game_rooms where id = p_room_id;
  end if;
  select * into v_me from public.game_room_players where room_id = p_room_id and user_id = v_uid;
  return jsonb_build_object(
    'id', r.id, 'group_id', r.group_id, 'kind', r.kind, 'status', r.status, 'host_id', r.host_id,
    'winner_id', r.winner_id, 'max_players', private.room_max_players(r.kind), 'state', r.state,
    'me_seat', v_me.seat, 'in_room', v_me.user_id is not null,
    'my_answer', case when r.kind = 'trivia' and r.status = 'playing' then (r.secret -> 'answers' -> v_uid::text ->> 'c')::integer end,
    'my_choice', case when r.kind = 'rps' and r.status = 'playing' and v_me.user_id is not null then (r.secret -> 'choices' ->> v_me.seat::text)::integer end,
    'server_now', now(), 'created_at', r.created_at,
    'players', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', p.user_id, 'seat', p.seat, 'score', p.score,
                                          'name', coalesce(pr.display_name, 'Member'), 'avatar_path', pr.avatar_path) order by p.seat)
        from public.game_room_players p left join public.profiles pr on pr.id = p.user_id
       where p.room_id = p_room_id), '[]'::jsonb));
end;
$$;

create or replace function public.list_rooms(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or not private.is_group_member(p_group_id) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  -- rooms nobody touched for six hours are closed
  update public.game_rooms
     set status = 'finished', finished_at = now(), state = state || '{"abandoned": true}'::jsonb
   where group_id = p_group_id and status <> 'finished' and updated_at < now() - interval '6 hours';
  return jsonb_build_object(
    'rooms', coalesce((
      select jsonb_agg(x.j order by x.rank, x.created_at desc)
        from (
          select g.created_at, case when g.status = 'finished' then 1 else 0 end as rank,
            jsonb_build_object(
              'id', g.id, 'kind', g.kind, 'status', g.status, 'host_id', g.host_id, 'winner_id', g.winner_id,
              'created_at', g.created_at, 'max_players', private.room_max_players(g.kind),
              'abandoned', coalesce((g.state ->> 'abandoned')::boolean, false),
              'in_room', exists (select 1 from public.game_room_players p where p.room_id = g.id and p.user_id = v_uid),
              'players', coalesce((select jsonb_agg(jsonb_build_object('user_id', p.user_id, 'seat', p.seat, 'score', p.score,
                                       'name', coalesce(pr.display_name, 'Member')) order by p.seat)
                                     from public.game_room_players p left join public.profiles pr on pr.id = p.user_id
                                    where p.room_id = g.id), '[]'::jsonb)) as j
            from public.game_rooms g
           where g.group_id = p_group_id
             and (g.status <> 'finished' or g.id in (select id from public.game_rooms where group_id = p_group_id and status = 'finished' order by finished_at desc nulls last limit 5))
           order by case when g.status = 'finished' then 1 else 0 end, g.created_at desc
           limit 30
        ) x), '[]'::jsonb),
    'leaderboard', coalesce((
      select jsonb_agg(l.j order by l.wins desc, l.played asc, l.name)
        from (
          select count(*) filter (where r.winner_id = p.user_id) as wins, count(*) as played, coalesce(pr.display_name, 'Member') as name,
                 jsonb_build_object('user_id', p.user_id, 'name', coalesce(pr.display_name, 'Member'),
                                    'wins', count(*) filter (where r.winner_id = p.user_id), 'played', count(*)) as j
            from public.game_room_players p
            join public.game_rooms r on r.id = p.room_id and r.status = 'finished' and r.group_id = p_group_id
                                    and not coalesce((r.state ->> 'abandoned')::boolean, false)
            left join public.profiles pr on pr.id = p.user_id
           group by p.user_id, pr.display_name
           order by 1 desc, 2 asc limit 10
        ) l), '[]'::jsonb));
end;
$$;

revoke all on function public.create_room(uuid, text), public.join_room(uuid), public.leave_room(uuid), public.start_room(uuid),
  public.delete_room(uuid), public.make_move(uuid, integer), public.get_room(uuid), public.list_rooms(uuid) from public, anon;
grant execute on function public.create_room(uuid, text), public.join_room(uuid), public.leave_room(uuid), public.start_room(uuid),
  public.delete_room(uuid), public.make_move(uuid, integer), public.get_room(uuid), public.list_rooms(uuid) to authenticated;

commit;
