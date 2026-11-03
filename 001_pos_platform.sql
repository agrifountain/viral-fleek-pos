-- POS platform: one database for many shops, each shop's records walled off by row-level security.

create table public.shops (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  status text not null default 'active' check (status in ('active','suspended')),
  plan text not null default 'business',
  created_at timestamptz not null default now()
);

create table public.shop_members (
  shop_id uuid not null references public.shops(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'owner' check (role in ('owner','staff')),
  created_at timestamptz not null default now(),
  primary key (shop_id, user_id)
);
create index shop_members_user_idx on public.shop_members(user_id);

create table public.docs (
  shop_id uuid not null references public.shops(id) on delete cascade,
  col text not null check (col in ('products','sales','laybys','cashups','settings','customers','bookings','expenses','statements')),
  id text not null check (length(id) between 1 and 200),
  data jsonb not null check (jsonb_typeof(data) = 'object' and octet_length(data::text) < 900000),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid(),
  primary key (shop_id, col, id)
);
create index docs_shop_updated_idx on public.docs(shop_id, updated_at);

-- recycle bin: every deleted record is kept here so it can be put back
create table public.docs_trash (
  trash_id bigint generated always as identity primary key,
  shop_id uuid not null,
  col text not null,
  id text not null,
  data jsonb not null,
  deleted_at timestamptz not null default now(),
  deleted_by uuid
);
create index docs_trash_shop_idx on public.docs_trash(shop_id, deleted_at);

-- helpers
create or replace function public.can_use_shop(s uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.shop_members m join public.shops sh on sh.id = m.shop_id
    where m.shop_id = s and m.user_id = (select auth.uid()) and sh.status = 'active'
  );
$$;

create or replace function public.jsonb_deep_merge(a jsonb, b jsonb) returns jsonb
language sql immutable set search_path = '' as $$
  select case
    when jsonb_typeof(a) = 'object' and jsonb_typeof(b) = 'object' then
      coalesce((
        select jsonb_object_agg(k,
          case when a ? k and b ? k then public.jsonb_deep_merge(a -> k, b -> k)
               when b ? k then b -> k
               else a -> k end)
        from (select jsonb_object_keys(a) as k union select jsonb_object_keys(b)) s
      ), '{}'::jsonb)
    else b end;
$$;

create or replace function public.docs_touch() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end $$;
create trigger docs_touch before insert or update on public.docs
  for each row execute function public.docs_touch();

create or replace function public.docs_to_trash() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.docs_trash(shop_id, col, id, data, deleted_by)
  values (old.shop_id, old.col, old.id, old.data, auth.uid());
  return old;
end $$;
create trigger docs_to_trash after delete on public.docs
  for each row execute function public.docs_to_trash();

-- merge-update one record atomically (two devices editing the same product never overwrite each other)
create or replace function public.doc_update(p_shop uuid, p_col text, p_id text, p_patch jsonb) returns void
language plpgsql security invoker set search_path = '' as $$
begin
  update public.docs set data = public.jsonb_deep_merge(data, p_patch)
  where shop_id = p_shop and col = p_col and id = p_id;
  if not found then
    raise exception 'record not found' using errcode = 'P0002';
  end if;
end $$;

-- row-level security
alter table public.shops enable row level security;
alter table public.shop_members enable row level security;
alter table public.docs enable row level security;
alter table public.docs_trash enable row level security;

create policy shops_member_read on public.shops for select to authenticated
  using (exists (select 1 from public.shop_members m where m.shop_id = shops.id and m.user_id = (select auth.uid())));
create policy members_own_read on public.shop_members for select to authenticated
  using (user_id = (select auth.uid()));
create policy docs_read on public.docs for select to authenticated using (public.can_use_shop(shop_id));
create policy docs_insert on public.docs for insert to authenticated with check (public.can_use_shop(shop_id));
create policy docs_update on public.docs for update to authenticated using (public.can_use_shop(shop_id)) with check (public.can_use_shop(shop_id));
create policy docs_delete on public.docs for delete to authenticated using (public.can_use_shop(shop_id));
-- docs_trash: no policies; only the provider (service role / dashboard) can read or restore

revoke all on public.shops, public.shop_members, public.docs, public.docs_trash from anon;
revoke all on public.docs_trash from authenticated;
revoke execute on function public.can_use_shop(uuid) from public, anon;
grant execute on function public.can_use_shop(uuid) to authenticated;
revoke execute on function public.doc_update(uuid, text, text, jsonb) from public, anon;
grant execute on function public.doc_update(uuid, text, text, jsonb) to authenticated;
revoke execute on function public.docs_to_trash() from public, anon, authenticated;

-- provider tools (run from the Supabase SQL editor; not callable from the app)
create or replace function public.admin_add_shop(p_name text, p_owner_email text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare s uuid; u uuid;
begin
  select id into u from auth.users where lower(email) = lower(p_owner_email);
  if u is null then raise exception 'No login with email %. Add the user under Authentication first.', p_owner_email; end if;
  insert into public.shops(name) values (p_name) returning id into s;
  insert into public.shop_members(shop_id, user_id, role) values (s, u, 'owner');
  return s;
end $$;
create or replace function public.admin_restore_trash(p_shop uuid, p_since timestamptz) returns integer
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  insert into public.docs(shop_id, col, id, data)
  select distinct on (col, id) shop_id, col, id, data from public.docs_trash
  where shop_id = p_shop and deleted_at >= p_since order by col, id, deleted_at desc
  on conflict (shop_id, col, id) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.admin_add_shop(text, text) from public, anon, authenticated;
revoke execute on function public.admin_restore_trash(uuid, timestamptz) from public, anon, authenticated;

-- live updates between the shop's phone and laptop
alter publication supabase_realtime add table public.docs;
