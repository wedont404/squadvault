-- 013_game_night.sql
-- Game night, part 2. Adds seven new live games on top of 012:
--   clash    (2 players)   battle: strike / heavy / guard / heal, picked in secret each round
--   penalty  (2 players)   football penalty shootout, shooter and keeper pick a corner in secret
--   race     (2-10)        street race to the finish line, pick a gear each round (boost can spin you out)
--   emoji    (2-12)        emoji decode: same engine as the trivia race, with emoji puzzles
--   likely   (3-12)        "Most likely to...": vote for a squadmate, most votes wears the crown
--   rather   (2-12)        "Would you rather...": pick a side, the majority side scores
--   pot      (2-10)        "Risk It": everyone puts squad coins in the pot, rolls two dice, may re-roll once (at their own risk),
--                          highest total takes the pot
--
-- SQUAD COINS ARE PRETEND. They are not money, can't be bought, sold, withdrawn or paid out, and no Mobile Money moves.
-- Everyone starts with 200 coins per squad and can claim +50 once a day, so nobody is ever locked out.
-- The server rolls every die and keeps secrets (picks, dice, answers) until the moment of reveal.
-- Safe to re-run. Prerequisites: 001-012.

begin;

alter table public.game_rooms drop constraint if exists game_rooms_kind_check;
alter table public.game_rooms add constraint game_rooms_kind_check
  check (kind in ('tictactoe', 'connect4', 'rps', 'trivia', 'clash', 'penalty', 'race', 'emoji', 'likely', 'rather', 'pot'));
alter table public.game_rooms add column if not exists stake integer not null default 0;
alter table public.game_rooms drop constraint if exists game_rooms_stake_check;
alter table public.game_rooms add constraint game_rooms_stake_check check (stake in (0, 10, 25, 50, 100));

create table if not exists public.squad_wallets (
  group_id uuid not null references public.savings_groups (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  balance integer not null default 200 check (balance >= 0),
  last_claim date,
  primary key (group_id, user_id)
);

create table if not exists public.vibe_prompts (
  id serial primary key,
  kind text not null check (kind in ('likely', 'rather')),
  prompt text not null unique,
  option_a text,
  option_b text
);

alter table public.squad_wallets enable row level security;
alter table public.vibe_prompts enable row level security;
revoke all on public.squad_wallets, public.vibe_prompts from anon, authenticated;
grant select, insert, update, delete on public.squad_wallets, public.vibe_prompts to service_role;
revoke all on sequence public.vibe_prompts_id_seq from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Content: emoji puzzles, slang and football trivia, "most likely" and "would you rather"
-- ---------------------------------------------------------------------------
insert into public.trivia_questions (topic, question, options, answer) values
 ('Emoji', 'Guess the movie: 🦁👑', array['The Lion King', 'Madagascar', 'Jumanji', 'Zootopia'], 0),
 ('Emoji', 'Guess the movie: ❄️👸⛄', array['Tangled', 'Frozen', 'Moana', 'Cinderella'], 1),
 ('Emoji', 'Guess the movie: 🕷️🧑', array['Ant-Man', 'Venom', 'Spider-Man', 'Black Widow'], 2),
 ('Emoji', 'Guess the movie: 🐠🔍', array['Shark Tale', 'Finding Nemo', 'The Little Mermaid', 'Aquaman'], 1),
 ('Emoji', 'Guess the movie: 🧸🤠🚀', array['Toy Story', 'Cars', 'Up', 'Coco'], 0),
 ('Emoji', 'Guess the movie: 🐼🥋', array['Madagascar', 'Kung Fu Panda', 'Rio', 'Sing'], 1),
 ('Emoji', 'Guess the movie: 🖤🐆👑', array['The Lion King', 'Creed', 'Black Panther', 'Wakanda Rising'], 2),
 ('Emoji', 'Guess the movie: 🦈🌊😱', array['Jaws', 'Moana', 'Titanic', 'Aquaman'], 0),
 ('Emoji', 'Guess the movie: 🏎️⚡😎', array['Fast & Furious', 'Cars', 'Transformers', 'Speed'], 1),
 ('Emoji', 'Guess the movie: 🧙‍♂️💍🌋', array['Harry Potter', 'The Hobbit', 'The Lord of the Rings', 'Narnia'], 2),
 ('Emoji', 'Guess the movie: 🦇🧔', array['Batman', 'Dracula', 'Venom', 'Joker'], 0),
 ('Emoji', 'Guess the movie: 👻🚫', array['Casper', 'Coco', 'Ghostbusters', 'Scary Movie'], 2),
 ('Emoji', 'What does 💀 mean in a chat?', array['Someone died', 'I''m dying laughing', 'I''m scared', 'Halloween'], 1),
 ('Emoji', 'What does 🍵 mean when girls text it?', array['Let''s drink tea', 'Spill the gossip', 'I''m sleepy', 'Good morning'], 1),
 ('Emoji', 'What does 🧢 mean in a comment?', array['That''s a lie, cap', 'Nice hat', 'School time', 'Football fan'], 0),
 ('Emoji', 'What does 🐐 mean?', array['Farm animal', 'Greatest of all time', 'Very slow', 'Hungry'], 1),
 ('Emoji', 'What does 😭 often mean in a chat?', array['Truly devastated only', 'So funny or so relatable', 'Allergies', 'Sleepy'], 1),
 ('Emoji', 'What does 🫶 mean?', array['Love and support', 'Stop it', 'Please pay me', 'Clap for me'], 0),
 ('Emoji', 'What does 💅 mean when someone posts it?', array['Time for nails only', 'Slay, unbothered and confident', 'I''m angry', 'Goodbye'], 1),
 ('Emoji', 'What does 🙄 mean?', array['Eye roll, annoyed', 'I''m so excited', 'Looking for you', 'Dizzy'], 0),
 ('Slang', 'What does "no cap" mean?', array['No hat', 'No lie, for real', 'No problem', 'No money'], 1),
 ('Slang', 'If someone says "that''s a W", it means...', array['It''s a win', 'It''s wrong', 'It''s weird', 'It''s waiting'], 0),
 ('Slang', 'What does "rizz" mean?', array['Being very tired', 'Charm and flirting skill', 'Being rich', 'A type of rice'], 1),
 ('Slang', 'If your friend says you "ate", you...', array['Had lunch', 'Did something really well', 'Were rude', 'Were late'], 1),
 ('Slang', 'What does "delulu" mean?', array['Delivered late', 'Delusional, living in a fantasy', 'Delicious', 'Very tall'], 1),
 ('Slang', 'What does "mid" mean?', array['Amazing', 'Average and not impressive', 'Midnight', 'Middle child'], 1),
 ('Slang', 'What does "ghosting" someone mean?', array['Scaring them', 'Cutting contact with no explanation', 'Dressing as a ghost', 'Calling them at night'], 1),
 ('Slang', 'What does "FOMO" stand for?', array['Fear of missing out', 'Friends of my office', 'Food on my order', 'Fun on my own'], 0),
 ('Slang', 'What does "GOAT" stand for?', array['Great on all tracks', 'Greatest of all time', 'Good at online trading', 'Going out and talking'], 1),
 ('Slang', 'What does "L" mean in "that''s an L"?', array['A loss', 'A lot', 'A letter', 'Late'], 0),
 ('Slang', 'If you are "cooked", you are...', array['Hungry', 'In serious trouble', 'Very rich', 'Very famous'], 1),
 ('Slang', 'What is a "vibe check"?', array['A phone update', 'Checking the mood or energy', 'A medical test', 'A song contest'], 1),
 ('Football', 'How many players does one team have on the pitch?', array['9', '10', '11', '12'], 2),
 ('Football', 'What is a "hat-trick"?', array['Three goals by one player', 'Two red cards', 'A special corner', 'A goal from the halfway line'], 0),
 ('Football', 'Which club plays its home games at Camp Nou?', array['Real Madrid', 'FC Barcelona', 'Manchester City', 'Juventus'], 1),
 ('Football', 'Which country hosted the 2010 FIFA World Cup?', array['Brazil', 'Germany', 'South Africa', 'Russia'], 2),
 ('Football', 'How long is a normal football match without extra time?', array['60 minutes', '80 minutes', '90 minutes', '100 minutes'], 2),
 ('Football', 'What colour card means a player must leave the pitch?', array['Yellow', 'Red', 'Blue', 'Green'], 1)
on conflict (question) do nothing;

insert into public.vibe_prompts (kind, prompt) values
 ('likely', 'Most likely to be late to their own birthday party'),
 ('likely', 'Most likely to cry at a wedding'),
 ('likely', 'Most likely to go viral on TikTok'),
 ('likely', 'Most likely to reply after 3 days'),
 ('likely', 'Most likely to win the squad savings challenge'),
 ('likely', 'Most likely to start the group chat drama'),
 ('likely', 'Most likely to forget their phone charger'),
 ('likely', 'Most likely to become a millionaire first'),
 ('likely', 'Most likely to ghost the group chat'),
 ('likely', 'Most likely to have the best outfit at the next event'),
 ('likely', 'Most likely to say "I''ll pay you back tomorrow"'),
 ('likely', 'Most likely to know all the gossip'),
 ('likely', 'Most likely to get lost with the map open'),
 ('likely', 'Most likely to be everyone''s free therapist'),
 ('likely', 'Most likely to eat the last piece of food'),
 ('likely', 'Most likely to dance first at the party'),
 ('likely', 'Most likely to say "one more minute" for an hour'),
 ('likely', 'Most likely to have 100 unread messages'),
 ('likely', 'Most likely to be the squad''s main character'),
 ('likely', 'Most likely to save the most money this year')
on conflict (prompt) do nothing;

insert into public.vibe_prompts (kind, prompt, option_a, option_b) values
 ('rather', 'Would you rather never use social media again, or never watch another movie or series?', 'Never use social media again', 'Never watch movies or series again'),
 ('rather', 'Would you rather always be 10 minutes late, or always be 20 minutes early?', 'Always 10 minutes late', 'Always 20 minutes early'),
 ('rather', 'Would you rather lose your phone for a week, or lose your best shoes forever?', 'Lose my phone for a week', 'Lose my best shoes forever'),
 ('rather', 'Would you rather eat only chips forever, or only pizza forever?', 'Only chips forever', 'Only pizza forever'),
 ('rather', 'Would you rather have unlimited data, or unlimited airtime?', 'Unlimited data', 'Unlimited airtime'),
 ('rather', 'Would you rather go viral for a dance, or be known for a great business?', 'Viral dance', 'Great business'),
 ('rather', 'Would you rather speak every language, or talk to animals?', 'Speak every language', 'Talk to animals'),
 ('rather', 'Would you rather wake up at 5am every day, or stay up until 3am every day?', 'Wake up at 5am daily', 'Stay up until 3am daily'),
 ('rather', 'Would you rather get 1,000,000 RWF now, or 1,000 RWF every day for life?', '1,000,000 RWF now', '1,000 RWF every day for life'),
 ('rather', 'Would you rather live in Kigali forever, or travel to a new country every year?', 'Kigali forever', 'A new country every year'),
 ('rather', 'Would you rather have perfect hair every day, or perfect skin every day?', 'Perfect hair', 'Perfect skin'),
 ('rather', 'Would you rather be able to fly, or be invisible?', 'Fly', 'Be invisible'),
 ('rather', 'Would you rather match outfits with your bestie daily, or never repeat an outfit?', 'Match outfits with my bestie', 'Never repeat an outfit'),
 ('rather', 'Would you rather sing in public, or dance in public?', 'Sing in public', 'Dance in public'),
 ('rather', 'Would you rather your crush replies instantly but is boring, or replies slowly but is fun?', 'Instant but boring', 'Slow but fun'),
 ('rather', 'Would you rather have a free ride everywhere, or free food everywhere?', 'Free rides everywhere', 'Free food everywhere'),
 ('rather', 'Would you rather read everyone''s mind, or have everyone love you?', 'Read minds', 'Be loved by everyone'),
 ('rather', 'Would you rather get a surprise party, or plan your own perfect party?', 'Surprise party', 'Plan my own')
on conflict (prompt) do nothing;
update public.vibe_prompts set option_a = null, option_b = null where kind = 'likely';

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
create or replace function private.room_max_players(p_kind text)
returns integer language sql immutable set search_path = '' as $$
  select case p_kind when 'trivia' then 12 when 'emoji' then 12 when 'likely' then 12 when 'rather' then 12
                     when 'race' then 10 when 'pot' then 10 else 2 end
$$;

create or replace function private.room_min_players(p_kind text)
returns integer language sql immutable set search_path = '' as $$
  select case p_kind when 'likely' then 3 else 2 end
$$;

-- squad coins: +/- an amount. Fails with not_enough_coins instead of going below zero.
create or replace function private.wallet_add(p_group uuid, p_user uuid, p_delta integer)
returns integer language plpgsql security definer set search_path = '' as $$
declare v_bal integer;
begin
  insert into public.squad_wallets (group_id, user_id) values (p_group, p_user) on conflict do nothing;
  begin
    update public.squad_wallets set balance = balance + p_delta where group_id = p_group and user_id = p_user returning balance into v_bal;
  exception when check_violation then
    raise exception 'not_enough_coins' using errcode = 'P0001';
  end;
  return v_bal;
end;
$$;

-- give every player of a lobby their stake back
create or replace function private.pot_refund(p_room uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.game_rooms%rowtype; p record;
begin
  select * into r from public.game_rooms where id = p_room;
  if r.id is null or r.kind <> 'pot' or r.stake = 0 then return; end if;
  for p in select user_id from public.game_room_players where room_id = p_room loop
    perform private.wallet_add(r.group_id, p.user_id, r.stake);
  end loop;
end;
$$;

-- two dice, with the house flavour: double sixes count 13, snake eyes count 0
create or replace function private.dice_total(p_a integer, p_b integer)
returns integer language sql immutable set search_path = '' as $$
  select case when p_a = 6 and p_b = 6 then 13 when p_a = 1 and p_b = 1 then 0 else p_a + p_b end
$$;

create or replace function private.roll_die()
returns integer language sql volatile set search_path = '' as $$ select 1 + floor(random() * 6)::integer $$;

-- Risk It: everyone's dice are revealed, highest total takes the pot (a tie splits it). Undecided players hold.
create or replace function private.pot_resolve(p_room uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.game_rooms%rowtype;
  v_n integer; v_pot integer; v_best integer; v_winners uuid[]; v_share integer; v_rest integer; v_results jsonb; w uuid; i integer := 0;
begin
  select * into r from public.game_rooms where id = p_room;
  if r.id is null or r.kind <> 'pot' or r.status <> 'playing' then return; end if;
  select count(*) into v_n from public.game_room_players where room_id = p_room;
  v_pot := r.stake * v_n;
  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id', pl.user_id, 'seat', pl.seat,
           'dice', r.secret -> 'rolls' -> pl.user_id::text -> 'd',
           'rerolled', coalesce((r.secret -> 'rolls' -> pl.user_id::text ->> 'rerolled')::boolean, false),
           'total', private.dice_total((r.secret -> 'rolls' -> pl.user_id::text -> 'd' ->> 0)::integer, (r.secret -> 'rolls' -> pl.user_id::text -> 'd' ->> 1)::integer)
         ) order by pl.seat), '[]'::jsonb)
    into v_results
    from public.game_room_players pl where pl.room_id = p_room;
  select max((e ->> 'total')::integer) into v_best from jsonb_array_elements(v_results) e;
  select array_agg((e ->> 'user_id')::uuid order by (e ->> 'seat')::integer) into v_winners
    from jsonb_array_elements(v_results) e where (e ->> 'total')::integer = v_best;
  v_share := v_pot / cardinality(v_winners);
  v_rest := v_pot - v_share * cardinality(v_winners);
  foreach w in array v_winners loop
    i := i + 1;
    perform private.wallet_add(r.group_id, w, v_share + case when i = 1 then v_rest else 0 end);
  end loop;
  update public.game_room_players gp set score = (e ->> 'total')::integer
    from jsonb_array_elements(v_results) e where gp.room_id = p_room and gp.user_id = (e ->> 'user_id')::uuid;
  perform private.room_finish(p_room, case when cardinality(v_winners) = 1 then v_winners[1] end,
    jsonb_build_object('phase', 'done', 'stake', r.stake, 'pot', v_pot, 'winners', to_jsonb(v_winners), 'results', v_results));
end;
$$;

create or replace function private.pot_tick(p_room uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.game_rooms%rowtype;
begin
  select * into r from public.game_rooms where id = p_room;
  if r.id is null or r.kind <> 'pot' or r.status <> 'playing' then return; end if;
  if now() >= (r.state ->> 'until')::timestamptz
     or (select count(*) from jsonb_each(r.secret -> 'rolls') e where (e.value ->> 'decided')::boolean) >= (select count(*) from public.game_room_players where room_id = p_room) then
    perform private.pot_resolve(p_room);
  end if;
end;
$$;

-- Trivia and emoji decode share one engine (replaces the 012 version so both kinds are covered)
create or replace function private.trivia_tick(p_room uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.game_rooms%rowtype;
  v_idx integer; v_total integer; v_correct integer; v_results jsonb; v_winner uuid; v_top integer;
begin
  select * into r from public.game_rooms where id = p_room;
  if r.id is null or r.kind not in ('trivia', 'emoji') or r.status <> 'playing' then return; end if;
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

-- "Most likely to" / "Would you rather": opens round p_idx
create or replace function private.vibe_open(p_room uuid, p_idx integer)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.game_rooms%rowtype; q public.vibe_prompts%rowtype;
begin
  select * into r from public.game_rooms where id = p_room;
  select * into q from public.vibe_prompts where id = (r.secret -> 'ids' ->> p_idx)::integer;
  update public.game_rooms
     set state = jsonb_build_object('q', p_idx, 'total', jsonb_array_length(r.secret -> 'ids'), 'phase', 'question',
           'prompt', q.prompt, 'option_a', q.option_a, 'option_b', q.option_b,
           'until', now() + interval '20 seconds', 'answered', '[]'::jsonb),
         secret = jsonb_set(r.secret, '{answers}', '{}'::jsonb),
         updated_at = now()
   where id = p_room;
end;
$$;

create or replace function private.vibe_tick(p_room uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.game_rooms%rowtype;
  v_idx integer; v_total integer; v_results jsonb; v_top integer; v_winner uuid; v_maj integer; v_a integer; v_b integer;
begin
  select * into r from public.game_rooms where id = p_room;
  if r.id is null or r.kind not in ('likely', 'rather') or r.status <> 'playing' then return; end if;
  v_idx := (r.state ->> 'q')::integer;
  v_total := (r.state ->> 'total')::integer;

  if r.state ->> 'phase' = 'question' then
    if now() >= (r.state ->> 'until')::timestamptz
       or (select count(*) from jsonb_object_keys(r.secret -> 'answers')) >= (select count(*) from public.game_room_players where room_id = p_room) then
      if r.kind = 'likely' then
        select coalesce(jsonb_agg(jsonb_build_object('seat', pl.seat, 'user_id', pl.user_id, 'n', x.n) order by pl.seat), '[]'::jsonb)
          into v_results
          from public.game_room_players pl
          left join lateral (select count(*)::integer as n from jsonb_each(r.secret -> 'answers') a where (a.value ->> 'c')::integer = pl.seat) x on true
         where pl.room_id = p_room;
        select max((e ->> 'n')::integer) into v_top from jsonb_array_elements(v_results) e;
        if v_top > 0 then
          update public.game_room_players gp set score = gp.score + 1
            from jsonb_array_elements(v_results) e
           where gp.room_id = p_room and gp.user_id = (e ->> 'user_id')::uuid and (e ->> 'n')::integer = v_top;
        end if;
        update public.game_rooms
           set state = r.state || jsonb_build_object('phase', 'reveal', 'votes', v_results, 'top', coalesce(v_top, 0), 'until', now() + interval '5 seconds'), updated_at = now()
         where id = p_room;
      else
        select count(*) filter (where (a.value ->> 'c')::integer = 0), count(*) filter (where (a.value ->> 'c')::integer = 1)
          into v_a, v_b from jsonb_each(r.secret -> 'answers') a;
        v_maj := case when v_a > v_b then 0 when v_b > v_a then 1 end;
        if v_maj is not null then
          update public.game_room_players gp set score = gp.score + 1
           where gp.room_id = p_room and (r.secret -> 'answers' -> gp.user_id::text ->> 'c')::integer = v_maj;
        end if;
        update public.game_rooms
           set state = r.state || jsonb_build_object('phase', 'reveal', 'a', v_a, 'b', v_b, 'majority', v_maj, 'until', now() + interval '5 seconds'), updated_at = now()
         where id = p_room;
      end if;
    end if;
  elsif r.state ->> 'phase' = 'reveal' and now() >= (r.state ->> 'until')::timestamptz then
    if v_idx + 1 < v_total then
      perform private.vibe_open(p_room, v_idx + 1);
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

-- Street race: resolves a round when everyone has picked a gear or the 10 seconds are up
create or replace function private.race_tick(p_room uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.game_rooms%rowtype;
  p record;
  v_gear integer; v_delta integer; v_crash boolean; v_pos jsonb; v_used jsonb; v_last jsonb := '[]'::jsonb; v_cur integer; v_new integer;
  v_goal integer; v_win uuid; v_best integer;
begin
  select * into r from public.game_rooms where id = p_room;
  if r.id is null or r.kind <> 'race' or r.status <> 'playing' then return; end if;
  if not (now() >= (r.state ->> 'until')::timestamptz
          or (select count(*) from jsonb_object_keys(r.secret -> 'gears')) >= (select count(*) from public.game_room_players where room_id = p_room)) then
    return;
  end if;
  v_goal := (r.state ->> 'goal')::integer;
  v_pos := r.state -> 'pos';
  v_used := r.state -> 'used';
  for p in select user_id, seat from public.game_room_players where room_id = p_room order by seat loop
    v_gear := coalesce((r.secret -> 'gears' ->> p.user_id::text)::integer, 1);
    if v_gear = 3 and (v_used ? p.seat::text) then v_gear := 1; end if;
    v_crash := false;
    if v_gear = 1 then v_delta := 3;
    elsif v_gear = 2 then
      if random() < 0.65 then v_delta := 7; else v_delta := -2; v_crash := true; end if;
    else v_delta := 9; v_used := v_used || jsonb_build_object(p.seat::text, true);
    end if;
    v_cur := (v_pos ->> p.seat::text)::integer;
    v_new := greatest(0, v_cur + v_delta);
    v_pos := v_pos || jsonb_build_object(p.seat::text, v_new);
    v_last := v_last || jsonb_build_object('seat', p.seat, 'gear', v_gear, 'delta', v_new - v_cur, 'crashed', v_crash);
    update public.game_room_players set score = v_new where room_id = p_room and user_id = p.user_id;
  end loop;
  select max(value::integer) into v_best from jsonb_each_text(v_pos);
  if v_best >= v_goal then
    -- photo finish: the server flips for it
    select pl.user_id into v_win from public.game_room_players pl
      where pl.room_id = p_room and (v_pos ->> pl.seat::text)::integer = v_best order by random() limit 1;
    perform private.room_finish(p_room, v_win, jsonb_build_object('round', (r.state ->> 'round')::integer, 'goal', v_goal, 'pos', v_pos, 'used', v_used, 'answered', '[]'::jsonb, 'last', v_last, 'phase', 'done'));
  else
    update public.game_rooms
       set state = jsonb_build_object('round', (r.state ->> 'round')::integer + 1, 'goal', v_goal, 'pos', v_pos, 'used', v_used,
                     'answered', '[]'::jsonb, 'last', v_last, 'phase', 'pick', 'until', now() + interval '10 seconds'),
           secret = jsonb_set(r.secret, '{gears}', '{}'::jsonb), updated_at = now()
     where id = p_room;
  end if;
end;
$$;

-- one call that moves whichever timed game this room is
create or replace function private.room_tick(p_room uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_kind text;
begin
  select kind into v_kind from public.game_rooms where id = p_room;
  if v_kind in ('trivia', 'emoji') then perform private.trivia_tick(p_room);
  elsif v_kind in ('likely', 'rather') then perform private.vibe_tick(p_room);
  elsif v_kind = 'race' then perform private.race_tick(p_room);
  elsif v_kind = 'pot' then perform private.pot_tick(p_room);
  end if;
end;
$$;

revoke all on function private.room_min_players(text), private.wallet_add(uuid, uuid, integer), private.pot_refund(uuid),
  private.dice_total(integer, integer), private.roll_die(), private.pot_resolve(uuid), private.pot_tick(uuid),
  private.vibe_open(uuid, integer), private.vibe_tick(uuid), private.race_tick(uuid), private.room_tick(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Lobby: create (with an optional coin stake), join (stake goes in the pot), leave (stake comes back), start, delete
-- ---------------------------------------------------------------------------
drop function if exists public.create_room(uuid, text);

create or replace function public.create_room(p_group_id uuid, p_kind text, p_stake integer default 0)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_stake integer := coalesce(p_stake, 0);
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or not private.is_group_member(p_group_id) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if p_kind is null or p_kind not in ('tictactoe', 'connect4', 'rps', 'trivia', 'clash', 'penalty', 'race', 'emoji', 'likely', 'rather', 'pot') then
    raise exception 'invalid_game' using errcode = '22023';
  end if;
  if p_kind = 'pot' then
    if v_stake not in (10, 25, 50, 100) then raise exception 'invalid_stake' using errcode = '22023'; end if;
  elsif v_stake <> 0 then
    raise exception 'invalid_stake' using errcode = '22023';
  end if;
  if (select count(*) from public.game_rooms where group_id = p_group_id and host_id = v_uid and status <> 'finished') >= 3 then
    raise exception 'too_many_games' using errcode = 'P0001';
  end if;
  if v_stake > 0 then perform private.wallet_add(p_group_id, v_uid, -v_stake); end if;
  insert into public.game_rooms (group_id, kind, host_id, stake) values (p_group_id, p_kind, v_uid, v_stake) returning id into v_id;
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
  if r.stake > 0 then perform private.wallet_add(r.group_id, v_uid, -r.stake); end if;
  insert into public.game_room_players (room_id, user_id, seat) values (p_room_id, v_uid, v_seat);
  update public.game_rooms set updated_at = now() where id = p_room_id;
end;
$$;

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
    if r.stake > 0 then perform private.wallet_add(r.group_id, v_uid, r.stake); end if;
    delete from public.game_room_players where room_id = p_room_id and user_id = v_uid;
    select user_id into v_next from public.game_room_players where room_id = p_room_id order by seat limit 1;
    if v_next is null then
      delete from public.game_rooms where id = p_room_id;
    elsif r.host_id = v_uid then
      update public.game_rooms set host_id = v_next, updated_at = now() where id = p_room_id;
    end if;
  elsif r.status = 'playing' and r.kind in ('tictactoe', 'connect4', 'rps', 'clash', 'penalty') then
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
  v_pos jsonb := '{}'::jsonb;
  v_rolls jsonb := '{}'::jsonb;
  p record;
  v_n integer;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into r from public.game_rooms where id = p_room_id for update;
  if r.id is null or not private.is_group_member(r.group_id) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if r.host_id <> v_uid then raise exception 'not_allowed' using errcode = '42501'; end if;
  if r.status <> 'lobby' then raise exception 'game_started' using errcode = 'P0001'; end if;
  select count(*) into v_n from public.game_room_players where room_id = p_room_id;
  if v_n < private.room_min_players(r.kind) then raise exception 'not_enough_players' using errcode = 'P0001'; end if;

  if r.kind = 'tictactoe' then
    update public.game_rooms set status = 'playing', state = jsonb_build_object('board', '.........', 'turn', 0), updated_at = now() where id = p_room_id;
  elsif r.kind = 'connect4' then
    update public.game_rooms set status = 'playing', state = jsonb_build_object('board', repeat('.', 42), 'turn', 0), updated_at = now() where id = p_room_id;
  elsif r.kind = 'rps' then
    update public.game_rooms set status = 'playing',
      state = jsonb_build_object('round', 1, 'wins', jsonb_build_array(0, 0), 'target', 2, 'moved', '[]'::jsonb),
      secret = jsonb_build_object('choices', '{}'::jsonb), updated_at = now() where id = p_room_id;
  elsif r.kind = 'clash' then
    update public.game_rooms set status = 'playing',
      state = jsonb_build_object('round', 1, 'hp', jsonb_build_array(100, 100), 'heals', jsonb_build_array(2, 2), 'moved', '[]'::jsonb),
      secret = jsonb_build_object('choices', '{}'::jsonb), updated_at = now() where id = p_room_id;
    update public.game_room_players set score = 100 where room_id = p_room_id;
  elsif r.kind = 'penalty' then
    update public.game_rooms set status = 'playing',
      state = jsonb_build_object('kick', 0, 'scores', jsonb_build_array(0, 0), 'moved', '[]'::jsonb, 'hist', '[]'::jsonb),
      secret = jsonb_build_object('choices', '{}'::jsonb), updated_at = now() where id = p_room_id;
  elsif r.kind = 'race' then
    for p in select seat from public.game_room_players where room_id = p_room_id loop
      v_pos := v_pos || jsonb_build_object(p.seat::text, 0);
    end loop;
    update public.game_rooms set status = 'playing',
      state = jsonb_build_object('round', 1, 'goal', 30, 'pos', v_pos, 'used', '{}'::jsonb, 'answered', '[]'::jsonb, 'last', null,
                                 'phase', 'pick', 'until', now() + interval '10 seconds'),
      secret = jsonb_build_object('gears', '{}'::jsonb), updated_at = now() where id = p_room_id;
  elsif r.kind = 'pot' then
    for p in select user_id from public.game_room_players where room_id = p_room_id loop
      v_rolls := v_rolls || jsonb_build_object(p.user_id::text, jsonb_build_object('d', jsonb_build_array(private.roll_die(), private.roll_die()), 'rerolled', false, 'decided', false));
    end loop;
    update public.game_rooms set status = 'playing',
      state = jsonb_build_object('phase', 'roll', 'stake', r.stake, 'pot', r.stake * v_n, 'answered', '[]'::jsonb, 'until', now() + interval '20 seconds'),
      secret = jsonb_build_object('rolls', v_rolls), updated_at = now() where id = p_room_id;
  elsif r.kind in ('likely', 'rather') then
    select jsonb_agg(id) into v_ids from (select id from public.vibe_prompts where kind = r.kind order by random() limit 6) q;
    update public.game_rooms set status = 'playing', secret = jsonb_build_object('ids', v_ids, 'answers', '{}'::jsonb), updated_at = now() where id = p_room_id;
    perform private.vibe_open(p_room_id, 0);
  else
    select jsonb_agg(id) into v_ids from (select id from public.trivia_questions
       where (r.kind = 'emoji' and topic = 'Emoji') or (r.kind = 'trivia' and topic <> 'Emoji') order by random() limit 8) q;
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
  select * into r from public.game_rooms where id = p_room_id for update;
  if r.id is null then return; end if;
  if r.host_id <> v_uid and not private.is_group_manager(r.group_id) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if r.kind = 'pot' and r.status = 'playing' then raise exception 'game_started' using errcode = 'P0001'; end if;
  if r.kind = 'pot' and r.status = 'lobby' then perform private.pot_refund(p_room_id); end if;
  delete from public.game_rooms where id = p_room_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Moves
--   tictactoe: cell 0-8      connect4: column 0-6     rps: 1 rock 2 paper 3 scissors
--   clash: 1 strike 2 heavy 3 guard 4 heal             penalty: 0 left 1 middle 2 right (shooter aims, keeper dives)
--   race: 1 cruise 2 boost 3 nitro (once)              trivia / emoji: option 0-3
--   likely: the seat number you vote for                rather: 0 or 1
--   pot: 0 hold your dice, 1 re-roll (final)
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
  -- clash
  v_hp0 integer; v_hp1 integer; v_heals jsonb; v_d0 integer := 0; v_d1 integer := 0; v_h0 integer := 0; v_h1 integer := 0; v_base integer; v_hp jsonb;
  -- penalty
  v_kick integer; v_shooter integer; v_shot integer; v_dive integer; v_result text; v_scores jsonb; v_hist jsonb; v_s0 integer; v_s1 integer; v_done integer;
  v_roll jsonb;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into r from public.game_rooms where id = p_room_id for update;
  if r.id is null or not private.is_group_member(r.group_id) then raise exception 'not_allowed' using errcode = '42501'; end if;
  select * into me from public.game_room_players where room_id = p_room_id and user_id = v_uid;
  if me.user_id is null then raise exception 'not_in_game' using errcode = '42501'; end if;
  if r.kind in ('trivia', 'emoji', 'likely', 'rather', 'race', 'pot') then
    perform private.room_tick(p_room_id);
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

  -- Clash: strike beats heavy (it interrupts), heavy beats guard (it breaks through), guard beats strike (and counters) ------
  elsif r.kind = 'clash' then
    if p_move < 1 or p_move > 4 then raise exception 'invalid_move' using errcode = '22023'; end if;
    if p_move = 4 and (r.state -> 'heals' ->> me.seat)::integer <= 0 then raise exception 'invalid_move' using errcode = '22023'; end if;
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
      v_hp0 := (r.state -> 'hp' ->> 0)::integer; v_hp1 := (r.state -> 'hp' ->> 1)::integer;
      v_heals := r.state -> 'heals';
      -- seat 0 attacks seat 1
      if v_c0 = 1 then
        v_base := 14 + floor(random() * 9)::integer;
        if v_c1 = 3 then v_d1 := v_d1 + round(v_base * 0.25)::integer; v_d0 := v_d0 + 8; else v_d1 := v_d1 + v_base; end if;
      elsif v_c0 = 2 and v_c1 <> 1 then
        v_d1 := v_d1 + 28 + floor(random() * 13)::integer;
      end if;
      -- seat 1 attacks seat 0
      if v_c1 = 1 then
        v_base := 14 + floor(random() * 9)::integer;
        if v_c0 = 3 then v_d0 := v_d0 + round(v_base * 0.25)::integer; v_d1 := v_d1 + 8; else v_d0 := v_d0 + v_base; end if;
      elsif v_c1 = 2 and v_c0 <> 1 then
        v_d0 := v_d0 + 28 + floor(random() * 13)::integer;
      end if;
      if v_c0 = 4 then v_h0 := 18 + floor(random() * 7)::integer; v_heals := jsonb_set(v_heals, '{0}', to_jsonb((v_heals ->> 0)::integer - 1)); end if;
      if v_c1 = 4 then v_h1 := 18 + floor(random() * 7)::integer; v_heals := jsonb_set(v_heals, '{1}', to_jsonb((v_heals ->> 1)::integer - 1)); end if;
      v_hp0 := least(100, v_hp0 - v_d0 + v_h0);
      v_hp1 := least(100, v_hp1 - v_d1 + v_h1);
      v_round := (r.state ->> 'round')::integer;
      v_hp := jsonb_build_array(greatest(v_hp0, 0), greatest(v_hp1, 0));
      update public.game_room_players set score = greatest(v_hp0, 0) where room_id = p_room_id and seat = 0;
      update public.game_room_players set score = greatest(v_hp1, 0) where room_id = p_room_id and seat = 1;
      if v_hp0 <= 0 or v_hp1 <= 0 or v_round >= 12 then
        v_win_seat := case when v_hp0 > v_hp1 then 0 when v_hp1 > v_hp0 then 1 end;
        if v_win_seat is not null then select user_id into v_win from public.game_room_players where room_id = p_room_id and seat = v_win_seat; else v_win := null; end if;
        perform private.room_finish(p_room_id, v_win, jsonb_build_object('round', v_round, 'hp', v_hp, 'heals', v_heals, 'moved', '[]'::jsonb,
          'last', jsonb_build_object('m', jsonb_build_array(v_c0, v_c1), 'dmg', jsonb_build_array(v_d0, v_d1), 'heal', jsonb_build_array(v_h0, v_h1))));
      else
        update public.game_rooms
           set secret = jsonb_set(r.secret, '{choices}', '{}'::jsonb),
               state = jsonb_build_object('round', v_round + 1, 'hp', v_hp, 'heals', v_heals, 'moved', '[]'::jsonb,
                         'last', jsonb_build_object('m', jsonb_build_array(v_c0, v_c1), 'dmg', jsonb_build_array(v_d0, v_d1), 'heal', jsonb_build_array(v_h0, v_h1))),
               updated_at = now()
         where id = p_room_id;
      end if;
    end if;

  -- Penalty shootout ----------------------------------------------------------
  elsif r.kind = 'penalty' then
    if p_move < 0 or p_move > 2 then raise exception 'invalid_move' using errcode = '22023'; end if;
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
      v_kick := (r.state ->> 'kick')::integer;
      v_shooter := v_kick % 2;
      v_shot := (v_choices ->> v_shooter::text)::integer;
      v_dive := (v_choices ->> (1 - v_shooter)::text)::integer;
      v_result := case when random() < 0.12 then 'missed' when v_shot = v_dive then 'saved' else 'goal' end;
      v_s0 := (r.state -> 'scores' ->> 0)::integer + case when v_result = 'goal' and v_shooter = 0 then 1 else 0 end;
      v_s1 := (r.state -> 'scores' ->> 1)::integer + case when v_result = 'goal' and v_shooter = 1 then 1 else 0 end;
      v_scores := jsonb_build_array(v_s0, v_s1);
      v_hist := coalesce(r.state -> 'hist', '[]'::jsonb) || jsonb_build_object('k', v_kick, 's', v_shooter, 'shot', v_shot, 'dive', v_dive, 'r', v_result);
      v_done := v_kick + 1;
      update public.game_room_players set score = v_s0 where room_id = p_room_id and seat = 0;
      update public.game_room_players set score = v_s1 where room_id = p_room_id and seat = 1;
      if (v_done >= 10 and v_done % 2 = 0 and v_s0 <> v_s1) or v_done >= 20 then
        v_win_seat := case when v_s0 > v_s1 then 0 when v_s1 > v_s0 then 1 end;
        if v_win_seat is not null then select user_id into v_win from public.game_room_players where room_id = p_room_id and seat = v_win_seat; else v_win := null; end if;
        perform private.room_finish(p_room_id, v_win, jsonb_build_object('kick', v_done, 'scores', v_scores, 'moved', '[]'::jsonb, 'hist', v_hist));
      else
        update public.game_rooms
           set secret = jsonb_set(r.secret, '{choices}', '{}'::jsonb),
               state = jsonb_build_object('kick', v_done, 'scores', v_scores, 'moved', '[]'::jsonb, 'hist', v_hist),
               updated_at = now()
         where id = p_room_id;
      end if;
    end if;

  -- Street race ---------------------------------------------------------------
  elsif r.kind = 'race' then
    if p_move < 1 or p_move > 3 then raise exception 'invalid_move' using errcode = '22023'; end if;
    if p_move = 3 and (r.state -> 'used') ? me.seat::text then raise exception 'invalid_move' using errcode = '22023'; end if;
    if (r.secret -> 'gears') ? v_uid::text then raise exception 'already_moved' using errcode = 'P0001'; end if;
    update public.game_rooms
       set secret = jsonb_set(r.secret, '{gears}', coalesce(r.secret -> 'gears', '{}'::jsonb) || jsonb_build_object(v_uid::text, p_move)),
           state = jsonb_set(r.state, '{answered}', coalesce(r.state -> 'answered', '[]'::jsonb) || to_jsonb(v_uid)),
           updated_at = now()
     where id = p_room_id;
    perform private.race_tick(p_room_id);

  -- Risk It -------------------------------------------------------------------
  elsif r.kind = 'pot' then
    if p_move not in (0, 1) then raise exception 'invalid_move' using errcode = '22023'; end if;
    v_roll := r.secret -> 'rolls' -> v_uid::text;
    if coalesce((v_roll ->> 'decided')::boolean, false) then raise exception 'already_moved' using errcode = 'P0001'; end if;
    if p_move = 1 then
      v_roll := jsonb_build_object('d', jsonb_build_array(private.roll_die(), private.roll_die()), 'rerolled', true, 'decided', true);
    else
      v_roll := v_roll || jsonb_build_object('decided', true);
    end if;
    update public.game_rooms
       set secret = jsonb_set(r.secret, array['rolls', v_uid::text], v_roll),
           state = jsonb_set(r.state, '{answered}', coalesce(r.state -> 'answered', '[]'::jsonb) || to_jsonb(v_uid)),
           updated_at = now()
     where id = p_room_id;
    perform private.pot_tick(p_room_id);

  -- Trivia race / emoji decode / most likely / would you rather -------------------
  else
    if r.state ->> 'phase' <> 'question' or now() >= (r.state ->> 'until')::timestamptz then
      raise exception 'too_late' using errcode = 'P0001';
    end if;
    if r.kind = 'likely' then
      if not exists (select 1 from public.game_room_players where room_id = p_room_id and seat = p_move) then raise exception 'invalid_move' using errcode = '22023'; end if;
    elsif r.kind = 'rather' then
      if p_move not in (0, 1) then raise exception 'invalid_move' using errcode = '22023'; end if;
    elsif p_move < 0 or p_move > 3 then
      raise exception 'invalid_move' using errcode = '22023';
    end if;
    if (r.secret -> 'answers') ? v_uid::text then raise exception 'already_moved' using errcode = 'P0001'; end if;
    update public.game_rooms
       set secret = jsonb_set(r.secret, '{answers}', coalesce(r.secret -> 'answers', '{}'::jsonb) || jsonb_build_object(v_uid::text, jsonb_build_object('c', p_move, 'at', now()))),
           state = jsonb_set(r.state, '{answered}', coalesce(r.state -> 'answered', '[]'::jsonb) || to_jsonb(v_uid)),
           updated_at = now()
     where id = p_room_id;
    perform private.room_tick(p_room_id);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Coins
-- ---------------------------------------------------------------------------
create or replace function public.my_wallet(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  w public.squad_wallets%rowtype;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or not private.is_group_member(p_group_id) then raise exception 'not_allowed' using errcode = '42501'; end if;
  insert into public.squad_wallets (group_id, user_id) values (p_group_id, v_uid) on conflict do nothing;
  select * into w from public.squad_wallets where group_id = p_group_id and user_id = v_uid;
  return jsonb_build_object('balance', w.balance, 'can_claim', w.last_claim is distinct from (now() at time zone 'Africa/Kigali')::date);
end;
$$;

create or replace function public.claim_daily_coins(p_group_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_today date := (now() at time zone 'Africa/Kigali')::date;
  v_bal integer;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or not private.is_group_member(p_group_id) then raise exception 'not_allowed' using errcode = '42501'; end if;
  insert into public.squad_wallets (group_id, user_id) values (p_group_id, v_uid) on conflict do nothing;
  update public.squad_wallets set balance = balance + 50, last_claim = v_today
   where group_id = p_group_id and user_id = v_uid and last_claim is distinct from v_today
   returning balance into v_bal;
  if v_bal is null then raise exception 'already_claimed' using errcode = 'P0001'; end if;
  return v_bal;
end;
$$;

-- ---------------------------------------------------------------------------
-- Reading
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
  if r.kind in ('trivia', 'emoji', 'likely', 'rather', 'race', 'pot') and r.status = 'playing' then
    perform 1 from public.game_rooms where id = p_room_id for update;
    perform private.room_tick(p_room_id);
    select * into r from public.game_rooms where id = p_room_id;
  end if;
  select * into v_me from public.game_room_players where room_id = p_room_id and user_id = v_uid;
  return jsonb_build_object(
    'id', r.id, 'group_id', r.group_id, 'kind', r.kind, 'status', r.status, 'host_id', r.host_id, 'stake', r.stake,
    'winner_id', r.winner_id, 'max_players', private.room_max_players(r.kind), 'min_players', private.room_min_players(r.kind), 'state', r.state,
    'me_seat', v_me.seat, 'in_room', v_me.user_id is not null,
    'my_answer', case when r.kind in ('trivia', 'emoji', 'likely', 'rather') and r.status = 'playing' then (r.secret -> 'answers' -> v_uid::text ->> 'c')::integer end,
    'my_choice', case when r.status <> 'playing' or v_me.user_id is null then null
                      when r.kind in ('rps', 'clash', 'penalty') then (r.secret -> 'choices' ->> v_me.seat::text)::integer
                      when r.kind = 'race' then (r.secret -> 'gears' ->> v_uid::text)::integer end,
    'my_dice', case when r.kind = 'pot' and r.status = 'playing' and v_me.user_id is not null then r.secret -> 'rolls' -> v_uid::text end,
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
  v_stale record;
  w public.squad_wallets%rowtype;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or not private.is_group_member(p_group_id) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  -- rooms nobody touched for six hours are closed (coin stakes in an unstarted table are returned)
  for v_stale in select id, kind, status from public.game_rooms
                  where group_id = p_group_id and status <> 'finished' and updated_at < now() - interval '6 hours' for update loop
    if v_stale.kind = 'pot' and v_stale.status = 'playing' then
      perform private.pot_resolve(v_stale.id);
    else
      if v_stale.kind = 'pot' and v_stale.status = 'lobby' then perform private.pot_refund(v_stale.id); end if;
      update public.game_rooms set status = 'finished', finished_at = now(), state = state || '{"abandoned": true}'::jsonb where id = v_stale.id;
    end if;
  end loop;
  insert into public.squad_wallets (group_id, user_id) values (p_group_id, v_uid) on conflict do nothing;
  select * into w from public.squad_wallets where group_id = p_group_id and user_id = v_uid;
  return jsonb_build_object(
    'wallet', jsonb_build_object('balance', w.balance, 'can_claim', w.last_claim is distinct from (now() at time zone 'Africa/Kigali')::date),
    'rooms', coalesce((
      select jsonb_agg(x.j order by x.rank, x.created_at desc)
        from (
          select g.created_at, case when g.status = 'finished' then 1 else 0 end as rank,
            jsonb_build_object(
              'id', g.id, 'kind', g.kind, 'status', g.status, 'host_id', g.host_id, 'winner_id', g.winner_id, 'stake', g.stake,
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
        ) l), '[]'::jsonb),
    'rich', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', b.user_id, 'name', b.name, 'balance', b.balance) order by b.balance desc, b.name)
        from (select sw.user_id, sw.balance, coalesce(pr.display_name, 'Member') as name
                from public.squad_wallets sw left join public.profiles pr on pr.id = sw.user_id
               where sw.group_id = p_group_id and exists (select 1 from public.group_members gm where gm.group_id = p_group_id and gm.user_id = sw.user_id)
               order by sw.balance desc limit 10) b), '[]'::jsonb));
end;
$$;

revoke all on function public.create_room(uuid, text, integer), public.join_room(uuid), public.leave_room(uuid), public.start_room(uuid),
  public.delete_room(uuid), public.make_move(uuid, integer), public.get_room(uuid), public.list_rooms(uuid),
  public.my_wallet(uuid), public.claim_daily_coins(uuid) from public, anon;
grant execute on function public.create_room(uuid, text, integer), public.join_room(uuid), public.leave_room(uuid), public.start_room(uuid),
  public.delete_room(uuid), public.make_move(uuid, integer), public.get_room(uuid), public.list_rooms(uuid),
  public.my_wallet(uuid), public.claim_daily_coins(uuid) to authenticated;

commit;
