-- Cerdo Láser 3000 — base de datos en Supabase.
-- Pegar entero en SQL Editor → New query → Run. Se puede volver a correr sin romper nada.
-- Requisito: Authentication → Sign In / Providers → "Allow anonymous sign-ins" ACTIVADO.

-- ============ JUGADORES: una fila por visitante (identidad anónima) ============
create table if not exists public.players (
  id uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  nick text not null default '' check (char_length(nick) <= 20),
  best integer not null default 0 check (best between 0 and 10000000),
  total_kills integer not null default 0 check (total_kills >= 0),
  total_leaks integer not null default 0 check (total_leaks >= 0),
  kills_by_ad jsonb not null default '{}'::jsonb check (jsonb_typeof(kills_by_ad) = 'object' and pg_column_size(kills_by_ad) < 2000),
  leaks_by_ad jsonb not null default '{}'::jsonb check (jsonb_typeof(leaks_by_ad) = 'object' and pg_column_size(leaks_by_ad) < 2000),
  visits integer not null default 0 check (visits >= 0),
  vote text check (vote in ('premio', 'virus', 'ram', 'solteros', 'casino', 'dieta')),
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now()
);
alter table public.players enable row level security;
drop policy if exists "players_select" on public.players;
drop policy if exists "players_insert" on public.players;
drop policy if exists "players_update" on public.players;
create policy "players_select" on public.players for select to anon, authenticated using (true);
create policy "players_insert" on public.players for insert to authenticated with check (id = auth.uid());
create policy "players_update" on public.players for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- ============ LIBRO DE VISITAS ============
create table if not exists public.guestbook (
  id bigint generated always as identity primary key,
  author uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 24),
  msg text not null check (char_length(msg) between 1 and 160),
  created_at timestamptz not null default now()
);
alter table public.guestbook enable row level security;
drop policy if exists "guestbook_select" on public.guestbook;
drop policy if exists "guestbook_insert" on public.guestbook;
drop policy if exists "guestbook_delete" on public.guestbook;
create policy "guestbook_select" on public.guestbook for select to anon, authenticated using (true);
create policy "guestbook_insert" on public.guestbook for insert to authenticated with check (author = auth.uid());
create policy "guestbook_delete" on public.guestbook for delete to authenticated using (author = auth.uid());

-- ============ CHAT (mensajes y zumbidos) ============
create table if not exists public.chat (
  id bigint generated always as identity primary key,
  author uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 20),
  kind text not null default 'msg' check (kind in ('msg', 'buzz')),
  msg text not null default '' check (char_length(msg) <= 200 and (kind = 'buzz' or char_length(msg) >= 1)),
  created_at timestamptz not null default now()
);
alter table public.chat enable row level security;
drop policy if exists "chat_select" on public.chat;
drop policy if exists "chat_insert" on public.chat;
create policy "chat_select" on public.chat for select to anon, authenticated using (true);
create policy "chat_insert" on public.chat for insert to authenticated with check (author = auth.uid());

grant select on public.players, public.guestbook, public.chat to anon, authenticated;
grant insert, update on public.players to authenticated;
grant insert, delete on public.guestbook to authenticated;
grant insert on public.chat to authenticated;

-- ============ ANTI-SPAM (en el servidor, no se puede saltear desde el navegador) ============
-- Fuerza la hora real del servidor y limita la frecuencia por autor.
create or replace function public.rate_limit() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  secs int := tg_argv[0]::int;
  recent boolean;
begin
  new.created_at := now();
  if tg_table_name = 'chat' then          -- (anidado: guestbook no tiene columna kind)
    if new.kind = 'buzz' then
      select exists (select 1 from public.chat where author = new.author and kind = 'buzz'
                     and created_at > now() - interval '15 seconds') into recent;
      if recent then raise exception 'rate_limit'; end if;
    end if;
  end if;
  execute format('select exists (select 1 from public.%I where author = $1 and created_at > now() - make_interval(secs => $2))', tg_table_name)
    into recent using new.author, secs;
  if recent then raise exception 'rate_limit'; end if;
  return new;
end $$;

drop trigger if exists guestbook_rate on public.guestbook;
create trigger guestbook_rate before insert on public.guestbook for each row execute function public.rate_limit('20');
drop trigger if exists chat_rate on public.chat;
create trigger chat_rate before insert on public.chat for each row execute function public.rate_limit('2');

-- ============ ESTADÍSTICAS GLOBALES (una sola llamada) ============
create or replace function public.get_stats() returns json
language sql stable set search_path = public as $$
  select json_build_object(
    'uniq',   (select count(*) from players),
    'visits', (select coalesce(sum(visits), 0) from players),
    'kills',  (select coalesce(sum(total_kills), 0) from players),
    'leaks',  (select coalesce(sum(total_leaks), 0) from players),
    'killsByAd', (select coalesce(json_object_agg(k, n), '{}'::json) from (
        select key as k, sum(case when jsonb_typeof(value) = 'number' then value::text::numeric else 0 end) as n
        from players, jsonb_each(kills_by_ad) group by key) s),
    'leaksByAd', (select coalesce(json_object_agg(k, n), '{}'::json) from (
        select key as k, sum(case when jsonb_typeof(value) = 'number' then value::text::numeric else 0 end) as n
        from players, jsonb_each(leaks_by_ad) group by key) s),
    'votes', (select coalesce(json_object_agg(vote, n), '{}'::json) from (
        select vote, count(*) as n from players where vote is not null group by vote) v)
  );
$$;
grant execute on function public.get_stats() to anon, authenticated;

-- ============ TIEMPO REAL para chat y libro de visitas ============
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'chat') then
    alter publication supabase_realtime add table public.chat;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'guestbook') then
    alter publication supabase_realtime add table public.guestbook;
  end if;
end $$;
