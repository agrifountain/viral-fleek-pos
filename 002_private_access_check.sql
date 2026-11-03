-- Move the access check out of the public API (Supabase security advisor 0029)
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;
create or replace function private.can_use_shop(s uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.shop_members m join public.shops sh on sh.id = m.shop_id
    where m.shop_id = s and m.user_id = (select auth.uid()) and sh.status = 'active'
  );
$$;
revoke execute on function private.can_use_shop(uuid) from public, anon;
grant execute on function private.can_use_shop(uuid) to authenticated;
drop policy docs_read on public.docs;
drop policy docs_insert on public.docs;
drop policy docs_update on public.docs;
drop policy docs_delete on public.docs;
create policy docs_read on public.docs for select to authenticated using (private.can_use_shop(shop_id));
create policy docs_insert on public.docs for insert to authenticated with check (private.can_use_shop(shop_id));
create policy docs_update on public.docs for update to authenticated using (private.can_use_shop(shop_id)) with check (private.can_use_shop(shop_id));
create policy docs_delete on public.docs for delete to authenticated using (private.can_use_shop(shop_id));
drop function public.can_use_shop(uuid);
