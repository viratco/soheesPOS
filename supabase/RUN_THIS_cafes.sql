-- Paste this whole file into Supabase SQL Editor (New query) and click Run.
-- Part 1 installs the security lockdown (it was never installed). Part 2 adds café accounts.
-- All or nothing: if anything fails, nothing changes.

-- ═════════════ PART 1: security lockdown ═════════════
-- Security lockdown: staff can no longer bypass the app to edit money records.
--   * payments: written only by close_order (no direct insert/update/delete)
--   * orders: staff may only cancel an OPEN order directly; paid/cancelled orders are frozen
--   * order_items: staff may only change status, along allowed steps, on open orders
--   * nobody can delete orders or items; invoice counters are unreachable
--   * QR ordering gets a flood guard (slow_down)
-- SECURITY DEFINER functions (close_order, append_items, ...) run as the owner, so they keep working.

-- 1. Payments: read-only for everyone; only close_order writes.
revoke insert, update, delete on payments from anon, authenticated;

-- 2. Orders: direct writes limited to cancelling.
revoke insert, update, delete on orders from anon, authenticated;
grant update (status, closed_at) on orders to authenticated;

-- 3. Order items: direct writes limited to status (serve / remove).
revoke insert, update, delete on order_items from anon, authenticated;
grant update (status) on order_items to authenticated;

-- 4. Invoice counters: no direct access at all.
revoke all on invoice_counters from anon, authenticated;

-- 5. Guard: closed orders are frozen; "paid" only via close_order.
create or replace function guard_orders()
returns trigger
language plpgsql as $$
begin
  if coalesce(current_setting('app.closing', true), '') = 'on' then
    return new;
  end if;
  if old.status <> 'open' then
    raise exception 'order_closed' using errcode = 'P0001';
  end if;
  if new.status = 'paid' then
    raise exception 'use_close_order' using errcode = 'P0001';
  end if;
  if new.status = 'cancelled' then
    new.closed_at := now();
  end if;
  return new;
end;
$$;
drop trigger if exists guard_orders on orders;
create trigger guard_orders before update on orders for each row execute function guard_orders();

-- 6. Guard: items only move forward along real kitchen steps, and only on open orders.
create or replace function guard_order_items()
returns trigger
language plpgsql as $$
declare
  v_status order_status;
begin
  if coalesce(current_setting('app.closing', true), '') = 'on' then
    return new;
  end if;
  select status into v_status from orders where id = new.order_id;
  if v_status is distinct from 'open' then
    raise exception 'order_closed' using errcode = 'P0001';
  end if;
  if new.status is distinct from old.status and not (
       (old.status = 'new'     and new.status in ('pending', 'void'))
    or (old.status = 'pending' and new.status in ('ready', 'served', 'void'))
    or (old.status = 'ready'   and new.status in ('served', 'void'))
    or (old.status = 'served'  and new.status = 'void')
  ) then
    raise exception 'invalid_status_change' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
drop trigger if exists guard_order_items on order_items;
create trigger guard_order_items before update on order_items for each row execute function guard_order_items();

revoke execute on function guard_orders() from public, anon, authenticated;
revoke execute on function guard_order_items() from public, anon, authenticated;

-- 7. append_items with the QR flood guard.
create or replace function append_items(p_table_id uuid, p_items jsonb, p_source text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_order_id uuid;
  v_count    int;
  v_inserted jsonb;
  v_status   order_item_status := case when p_source = 'customer' then 'new' else 'pending' end;
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0
     or jsonb_array_length(p_items) > 30 then
    raise exception 'invalid_cart' using errcode = 'P0001';
  end if;

  -- Flood guard for QR orders: a real table doesn't send 40+ items a minute,
  -- or pile up more than 60 items still waiting for staff to accept.
  if p_source = 'customer' then
    if (select coalesce(sum(oi.qty), 0) from order_items oi join orders o on o.id = oi.order_id
        where o.table_id = p_table_id and oi.source = 'customer' and oi.created_at > now() - interval '1 minute') > 40
       or (select coalesce(sum(oi.qty), 0) from order_items oi join orders o on o.id = oi.order_id
        where o.table_id = p_table_id and o.status = 'open' and oi.status = 'new') > 60 then
      raise exception 'slow_down' using errcode = 'P0001';
    end if;
  end if;

  select count(*) into v_count
  from jsonb_to_recordset(p_items) as c(menu_item_id uuid, qty int, note text)
  left join menu_items m on m.id = c.menu_item_id and m.is_available
  where m.id is null or c.qty is null or c.qty not between 1 and 50;
  if v_count > 0 then
    raise exception 'item_unavailable' using errcode = 'P0001';
  end if;

  insert into orders (table_id) values (p_table_id)
  on conflict (table_id) where status = 'open' do nothing;
  select id into v_order_id from orders
  where table_id = p_table_id and status = 'open'
  for update;

  with ins as (
    insert into order_items (order_id, menu_item_id, name_snapshot, price_paise_snapshot, qty, note, source, status, accepted_at)
    select v_order_id, m.id, m.name, m.price_paise, c.qty,
           nullif(left(trim(c.note), 200), ''), p_source, v_status,
           case when v_status = 'pending' then now() end
    from jsonb_to_recordset(p_items) as c(menu_item_id uuid, qty int, note text)
    join menu_items m on m.id = c.menu_item_id
    returning id, name_snapshot, price_paise_snapshot, qty, note
  )
  select jsonb_agg(to_jsonb(ins)) into v_inserted from ins;

  return jsonb_build_object('order_id', v_order_id, 'items', v_inserted);
end;
$$;
revoke execute on function append_items(uuid, jsonb, text) from public, anon, authenticated;

-- 8. close_order that tells the guards it is the official checkout.
create or replace function close_order(
  p_order_id        uuid,
  p_method          payment_method,
  p_gst_rate_bps    int,
  p_discount_type   text default null,  -- 'percent' | 'amount' | null
  p_discount_value  int  default 0,     -- percent: basis points (1000 = 10%); amount: paise
  p_discount_reason text default null
)
returns orders
language plpgsql security definer set search_path = public as $$
declare
  v_subtotal int;
  v_discount int := 0;
  v_taxable  int;
  v_gst      int;
  v_order    orders;
  v_fy       text := financial_year(now());
  v_n        int;
begin
  if not is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- Lets the guard triggers know this change comes from the official checkout.
  perform set_config('app.closing', 'on', true);

  update order_items set status = 'void' where order_id = p_order_id and status = 'new';

  select coalesce(sum(price_paise_snapshot * qty), 0) into v_subtotal
  from order_items where order_id = p_order_id and status in ('pending', 'ready', 'served');

  -- Server decides the discount; the screen's number is only a preview.
  if p_discount_type = 'percent' then
    if p_discount_value < 0 or p_discount_value > 10000 then
      raise exception 'invalid_discount' using errcode = 'P0001';
    end if;
    v_discount := (v_subtotal * p_discount_value + 5000) / 10000;
  elsif p_discount_type = 'amount' then
    if p_discount_value < 0 then
      raise exception 'invalid_discount' using errcode = 'P0001';
    end if;
    v_discount := least(p_discount_value, v_subtotal);
  elsif p_discount_type is not null then
    raise exception 'invalid_discount' using errcode = 'P0001';
  end if;

  v_taxable := v_subtotal - v_discount;
  v_gst := (v_taxable * p_gst_rate_bps + 5000) / 10000;

  update orders set
    status = 'paid', closed_at = now(),
    subtotal_paise = v_subtotal,
    discount_paise = v_discount,
    discount_reason = case when v_discount > 0 then nullif(left(trim(p_discount_reason), 60), '') end,
    gst_rate_bps = p_gst_rate_bps,
    gst_paise = v_gst,
    total_paise = v_taxable + v_gst
  where id = p_order_id and status = 'open'
  returning * into v_order;

  if not found then
    raise exception 'order_not_open' using errcode = 'P0001';
  end if;

  if v_order.total_paise > 0 then
    insert into invoice_counters (fy, last) values (v_fy, 1)
    on conflict (fy) do update set last = invoice_counters.last + 1
    returning last into v_n;

    update orders set invoice_no = 'SK/' || v_fy || '/' || lpad(v_n::text, 5, '0')
    where id = p_order_id
    returning * into v_order;

    insert into payments (order_id, method, amount_paise)
    values (p_order_id, p_method, v_order.total_paise);
  end if;

  perform set_config('app.closing', 'off', true);
  return v_order;
end;
$$;
revoke execute on function close_order(uuid, payment_method, int, text, int, text) from public, anon;
grant execute on function close_order(uuid, payment_method, int, text, int, text) to authenticated;

-- ═════════════ PART 2: café accounts ═════════════
-- Multi-café: every café is its own account, and its data is walled off from every other café.
--
--   * cafes: one row per customer café (name, bill details, GST rate, invoice prefix).
--   * Every café-owned row carries cafe_id. Each login (staff row) belongs to exactly ONE café.
--   * my_cafe() = the signed-in user's café. Every policy and staff RPC checks it, so a login
--     can only ever see or change its own café's tables, menu, orders, bills and guests.
--   * Turning a café off (cafes.is_active = false) locks its logins out and stops its QR menu.
--
-- Everything that exists today becomes the café "Sohee's Kitchen" (slug 'sohees'), so the
-- live café keeps working exactly as before: same QR codes, same logins, same invoice series.

-- ─── 1. Cafés ───────────────────────────────────────────────────────────────
create table if not exists cafes (
  id             uuid primary key default gen_random_uuid(),
  slug           text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,39}$'),
  name           text not null check (char_length(name) between 1 and 60),
  legal_name     text check (char_length(legal_name) <= 100),
  address        text check (char_length(address) <= 300),
  phone          text check (char_length(phone) <= 30),
  gstin          text check (gstin is null or gstin ~ '^[0-9]{2}[A-Z0-9]{13}$'),
  fssai          text check (char_length(fssai) <= 20),
  bill_footer    text not null default 'Thank you! Visit again.' check (char_length(bill_footer) <= 120),
  gst_rate_bps   int  not null default 500 check (gst_rate_bps between 0 and 2800),  -- 500 = 5%
  invoice_prefix text not null default 'INV' check (invoice_prefix ~ '^[A-Z0-9]{1,6}$'),
  logo_url       text,   -- round logo on the customer menu
  qr_logo_url    text,   -- white logo on the printed table cards (falls back to the name)
  is_active      boolean not null default true,
  created_at     timestamptz not null default now()
);

insert into cafes (id, slug, name, legal_name, address, gstin, invoice_prefix, logo_url, qr_logo_url)
values (
  '5011ee00-0000-4000-8000-000000000001', 'sohees', 'Sohee''s Kitchen', null,
  'First Floor, BB 28, Block B, Ansal Golf Link-1, Greater Noida, Uttar Pradesh 201315',
  '09HIZPK7132P1Z0', 'SK', null, '/brand/sohees-logo-white.png'
)
on conflict (id) do nothing;

-- ─── 2. cafe_id on every café-owned table, filled with Sohee's for existing rows ─────
-- The guard triggers block edits to paid orders; this one-off backfill is allowed past them.
alter table orders      disable trigger guard_orders;
alter table order_items disable trigger guard_order_items;

do $$
declare
  t text;
begin
  foreach t in array array['tables', 'menu_categories', 'menu_items', 'orders', 'order_items',
                           'payments', 'order_guests', 'invoice_counters', 'staff'] loop
    execute format('alter table %I add column if not exists cafe_id uuid references cafes(id) on delete restrict', t);
    execute format('update %I set cafe_id = %L where cafe_id is null', t, '5011ee00-0000-4000-8000-000000000001');
    execute format('alter table %I alter column cafe_id set not null', t);
    execute format('create index if not exists %I on %I (cafe_id)', t || '_cafe_id', t);
  end loop;
end $$;

alter table orders      enable trigger guard_orders;
alter table order_items enable trigger guard_order_items;

-- ─── 3. Who am I? ───────────────────────────────────────────────────────────
-- The signed-in user's café (null if not staff, or if the café is switched off).
create or replace function my_cafe() returns uuid
language sql stable security definer set search_path = public as $$
  select s.cafe_id from staff s join cafes c on c.id = s.cafe_id and c.is_active
  where s.user_id = auth.uid();
$$;

create or replace function is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from staff s join cafes c on c.id = s.cafe_id and c.is_active
                 where s.user_id = auth.uid() and s.role = 'staff');
$$;

create or replace function is_kitchen_or_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select my_cafe() is not null;
$$;

revoke execute on function my_cafe() from public;
grant execute on function my_cafe() to anon, authenticated;  -- policies call it for anon too

-- New tables and categories made in the app belong to the maker's café.
alter table tables          alter column cafe_id set default my_cafe();
alter table menu_categories alter column cafe_id set default my_cafe();

-- Child rows always belong to their parent's café (never trusted from the client).
create or replace function inherit_cafe() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'menu_items' then
    select cafe_id into new.cafe_id from menu_categories where id = new.category_id;
  elsif tg_table_name = 'orders' then
    select cafe_id into new.cafe_id from tables where id = new.table_id;
  else  -- order_items, payments, order_guests
    select cafe_id into new.cafe_id from orders where id = new.order_id;
  end if;
  return new;
end;
$$;
revoke execute on function inherit_cafe() from public, anon, authenticated;

drop trigger if exists inherit_cafe on menu_items;
create trigger inherit_cafe before insert or update of category_id, cafe_id on menu_items
  for each row execute function inherit_cafe();
drop trigger if exists inherit_cafe on orders;
create trigger inherit_cafe before insert or update of table_id on orders
  for each row execute function inherit_cafe();
drop trigger if exists inherit_cafe on order_items;
create trigger inherit_cafe before insert or update of order_id on order_items
  for each row execute function inherit_cafe();
drop trigger if exists inherit_cafe on payments;
create trigger inherit_cafe before insert on payments
  for each row execute function inherit_cafe();
drop trigger if exists inherit_cafe on order_guests;
create trigger inherit_cafe before insert or update of order_id on order_guests
  for each row execute function inherit_cafe();

-- ─── 4. Names and numbers are unique per café, not globally ─────────────────
alter table tables drop constraint if exists tables_name_key;
create unique index if not exists tables_cafe_name on tables (cafe_id, name);

alter table orders drop constraint if exists orders_invoice_no_key;
create unique index if not exists orders_cafe_invoice_no on orders (cafe_id, invoice_no);

alter table invoice_counters drop constraint if exists invoice_counters_pkey;
alter table invoice_counters add primary key (cafe_id, fy);

-- ─── 5. Row Level Security: every rule is "and it's my café" ────────────────
do $$
declare
  r record;
begin
  for r in select policyname, tablename from pg_policies
           where schemaname = 'public'
             and tablename in ('tables', 'menu_categories', 'menu_items', 'orders', 'order_items',
                               'payments', 'order_guests', 'staff', 'cafes') loop
    execute format('drop policy %I on %I', r.policyname, r.tablename);
  end loop;
end $$;

alter table cafes enable row level security;
create policy "members read own cafe" on cafes for select to authenticated using (id = (select my_cafe()));
create policy "staff edit own cafe"   on cafes for update to authenticated
  using (id = (select my_cafe()) and (select is_staff())) with check (id = (select my_cafe()));
revoke all on cafes from anon, authenticated;
grant select on cafes to authenticated;
grant update (name, legal_name, address, phone, gstin, fssai, bill_footer, gst_rate_bps) on cafes to authenticated;

-- Menus are public to guests (the QR page filters by café); a login sees only its own café's.
create policy "guests read menus"      on menu_categories for select to anon using (true);
create policy "members read own menu"  on menu_categories for select to authenticated using (cafe_id = (select my_cafe()));
create policy "staff manage own menu"  on menu_categories for all to authenticated
  using ((select is_staff()) and cafe_id = (select my_cafe())) with check ((select is_staff()) and cafe_id = (select my_cafe()));

create policy "guests read dishes"       on menu_items for select to anon using (true);
create policy "members read own dishes"  on menu_items for select to authenticated using (cafe_id = (select my_cafe()));
create policy "staff manage own dishes"  on menu_items for all to authenticated
  using ((select is_staff()) and cafe_id = (select my_cafe())) with check ((select is_staff()) and cafe_id = (select my_cafe()));

create policy "members read own tables" on tables for select to authenticated using (cafe_id = (select my_cafe()));
create policy "staff manage own tables" on tables for all to authenticated
  using ((select is_staff()) and cafe_id = (select my_cafe())) with check ((select is_staff()) and cafe_id = (select my_cafe()));

create policy "members read own orders" on orders for select to authenticated using (cafe_id = (select my_cafe()));
create policy "staff manage own orders" on orders for all to authenticated
  using ((select is_staff()) and cafe_id = (select my_cafe())) with check ((select is_staff()) and cafe_id = (select my_cafe()));

create policy "members read own items" on order_items for select to authenticated using (cafe_id = (select my_cafe()));
create policy "staff manage own items" on order_items for all to authenticated
  using ((select is_staff()) and cafe_id = (select my_cafe())) with check ((select is_staff()) and cafe_id = (select my_cafe()));

create policy "staff read own payments" on payments for select to authenticated
  using ((select is_staff()) and cafe_id = (select my_cafe()));

create policy "staff read own guests" on order_guests for select to authenticated
  using ((select is_staff()) and cafe_id = (select my_cafe()));

create policy "read own staff row" on staff for select to authenticated using (user_id = auth.uid());
-- Logins are created by the onboarding script only (one login = one café, for good).
revoke insert, update, delete on staff from anon, authenticated;

-- ─── 6. RPCs: café-aware ────────────────────────────────────────────────────

-- Customer: QR token -> table + the café it belongs to (only if the café is active).
drop function if exists get_table_by_token(text);
create function get_table_by_token(p_qr_token text)
returns table (id uuid, name text, cafe_id uuid, cafe_name text, cafe_slug text, logo_url text)
language sql stable security definer set search_path = public as $$
  select t.id, t.name, c.id, c.name, c.slug, c.logo_url
  from tables t join cafes c on c.id = t.cafe_id and c.is_active
  where t.qr_token = p_qr_token and t.is_active;
$$;
revoke execute on function get_table_by_token(text) from public;
grant execute on function get_table_by_token(text) to anon, authenticated;

-- Same as before, plus: a dish can only be ordered at a table of the café that owns it.
create or replace function append_items(p_table_id uuid, p_items jsonb, p_source text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_cafe     uuid;
  v_order_id uuid;
  v_status   order_item_status := case when p_source = 'customer' then 'new' else 'pending' end;
  v_line     jsonb;
  v_item     menu_items%rowtype;
  v_qty      int;
  v_sel      jsonb;
  v_pick     jsonb;
  v_group    jsonb;
  v_price    int;
  v_extra    int;
  v_count    int;
  v_snap     jsonb;
  v_row      order_items%rowtype;
  v_inserted jsonb := '[]'::jsonb;
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0
     or jsonb_array_length(p_items) > 30 then
    raise exception 'invalid_cart' using errcode = 'P0001';
  end if;

  select cafe_id into v_cafe from tables where id = p_table_id;
  if not found then
    raise exception 'invalid_table' using errcode = 'P0001';
  end if;

  -- Flood guard for QR orders: a real table doesn't send 40+ items a minute,
  -- or pile up more than 60 items still waiting for staff to accept.
  if p_source = 'customer' then
    if (select coalesce(sum(oi.qty), 0) from order_items oi join orders o on o.id = oi.order_id
        where o.table_id = p_table_id and oi.source = 'customer' and oi.created_at > now() - interval '1 minute') > 40
       or (select coalesce(sum(oi.qty), 0) from order_items oi join orders o on o.id = oi.order_id
        where o.table_id = p_table_id and o.status = 'open' and oi.status = 'new') > 60 then
      raise exception 'slow_down' using errcode = 'P0001';
    end if;
  end if;

  -- Find-or-create the open order. The partial unique index serialises racing submits.
  insert into orders (table_id) values (p_table_id)
  on conflict (table_id) where status = 'open' do nothing;
  select id into v_order_id from orders
  where table_id = p_table_id and status = 'open'
  for update;

  -- Any error below rolls back the whole submission, so nothing is half-saved.
  for v_line in select * from jsonb_array_elements(p_items) loop
    select * into v_item from menu_items
    where id = (v_line->>'menu_item_id')::uuid and is_available and cafe_id = v_cafe;
    if not found then
      raise exception 'item_unavailable' using errcode = 'P0001';
    end if;

    v_qty := (v_line->>'qty')::int;
    if v_qty is null or v_qty not between 1 and 50 then
      raise exception 'invalid_cart' using errcode = 'P0001';
    end if;

    v_sel := coalesce(v_line->'options', '[]'::jsonb);
    if jsonb_typeof(v_sel) <> 'array' or jsonb_array_length(v_sel) > 20 then
      raise exception 'invalid_options' using errcode = 'P0001';
    end if;

    -- Every pick must exist on this dish; price comes from the menu, never the phone.
    v_extra := 0;
    v_snap := '[]'::jsonb;
    for v_pick in select * from jsonb_array_elements(v_sel) loop
      select (c->>'price')::int into v_price
      from jsonb_array_elements(v_item.options) g, jsonb_array_elements(g->'choices') c
      where g->>'name' = v_pick->>'group' and c->>'name' = v_pick->>'name'
      limit 1;
      if not found then
        raise exception 'invalid_options' using errcode = 'P0001';
      end if;
      v_extra := v_extra + coalesce(v_price, 0);
      v_snap := v_snap || jsonb_build_array(jsonb_build_object(
        'group', v_pick->>'group', 'name', v_pick->>'name', 'price', coalesce(v_price, 0)));
    end loop;

    -- No duplicate picks.
    select count(distinct (s->>'group') || '|' || (s->>'name')) into v_count from jsonb_array_elements(v_sel) s;
    if v_count <> jsonb_array_length(v_sel) then
      raise exception 'invalid_options' using errcode = 'P0001';
    end if;

    -- Each group's min/max (e.g. "pick exactly 1").
    for v_group in select * from jsonb_array_elements(v_item.options) loop
      select count(*) into v_count from jsonb_array_elements(v_sel) s where s->>'group' = v_group->>'name';
      if v_count < coalesce((v_group->>'min')::int, 0) or v_count > coalesce((v_group->>'max')::int, 1) then
        raise exception 'invalid_options' using errcode = 'P0001';
      end if;
    end loop;

    insert into order_items (order_id, menu_item_id, name_snapshot, price_paise_snapshot, qty, note, source, status, accepted_at, options)
    values (
      v_order_id, v_item.id, v_item.name, v_item.price_paise + v_extra, v_qty,
      nullif(left(trim(v_line->>'note'), 200), ''), p_source, v_status,
      case when v_status = 'pending' then now() end,
      case when jsonb_array_length(v_snap) > 0 then v_snap end
    )
    returning * into v_row;

    v_inserted := v_inserted || jsonb_build_array(jsonb_build_object(
      'id', v_row.id, 'name_snapshot', v_row.name_snapshot, 'price_paise_snapshot', v_row.price_paise_snapshot,
      'qty', v_row.qty, 'note', v_row.note, 'options', v_row.options));
  end loop;

  return jsonb_build_object('order_id', v_order_id, 'items', v_inserted);
end;
$$;
revoke execute on function append_items(uuid, jsonb, text) from public, anon, authenticated;

-- Customer: place an order from the QR page (the café must be active).
create or replace function place_order(p_qr_token text, p_items jsonb, p_customer jsonb default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_table  tables%rowtype;
  v_result jsonb;
  v_name   text;
  v_phone  text;
begin
  select t.* into v_table from tables t join cafes c on c.id = t.cafe_id and c.is_active
  where t.qr_token = p_qr_token and t.is_active;
  if not found then
    raise exception 'invalid_table' using errcode = 'P0001';
  end if;

  if p_customer is not null then
    v_name := nullif(left(regexp_replace(trim(p_customer->>'name'), '\s+', ' ', 'g'), 60), '');
    v_phone := regexp_replace(coalesce(p_customer->>'phone', ''), '\D', '', 'g');
    if length(v_phone) = 12 and left(v_phone, 2) = '91' then v_phone := substr(v_phone, 3); end if;
    if length(v_phone) = 11 and left(v_phone, 1) = '0' then v_phone := substr(v_phone, 2); end if;
    if v_name is null then
      raise exception 'invalid_name' using errcode = 'P0001';
    end if;
    if v_phone !~ '^[6-9][0-9]{9}$' then
      raise exception 'invalid_phone' using errcode = 'P0001';
    end if;
  end if;

  v_result := append_items(v_table.id, p_items, 'customer');

  if v_name is not null then
    insert into order_guests (order_id, name, phone, marketing_consent)
    values ((v_result->>'order_id')::uuid, v_name, v_phone, coalesce((p_customer->>'marketing_consent')::boolean, false))
    on conflict (order_id, phone) do update
      set name = excluded.name,
          marketing_consent = order_guests.marketing_consent or excluded.marketing_consent;
  end if;

  return v_result || jsonb_build_object('table_name', v_table.name);
end;
$$;
revoke execute on function place_order(text, jsonb, jsonb) from public;
grant execute on function place_order(text, jsonb, jsonb) to anon, authenticated;

-- Staff: add items for a guest who didn't scan (own café's tables only).
create or replace function staff_add_items(p_table_id uuid, p_items jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_name text;
begin
  if not is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select name into v_name from tables where id = p_table_id and cafe_id = my_cafe();
  if not found then
    raise exception 'invalid_table' using errcode = 'P0001';
  end if;
  return append_items(p_table_id, p_items, 'staff')
         || jsonb_build_object('table_name', v_name);
end;
$$;
revoke execute on function staff_add_items(uuid, jsonb) from public, anon;
grant execute on function staff_add_items(uuid, jsonb) to authenticated;

-- Kitchen: mark a dish ready (own café only).
create or replace function mark_item_ready(p_item_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_kitchen_or_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update order_items set status = 'ready', ready_at = now()
  where id = p_item_id and status = 'pending' and cafe_id = my_cafe();
end;
$$;
revoke execute on function mark_item_ready(uuid) from public, anon;
grant execute on function mark_item_ready(uuid) to authenticated;

-- Staff: accept waiting QR items and send them to the kitchen (own café only).
create or replace function accept_order_items(p_order_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_items jsonb;
  v_table text;
begin
  if not is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select t.name into v_table from orders o join tables t on t.id = o.table_id
  where o.id = p_order_id and o.cafe_id = my_cafe();
  if not found then
    raise exception 'order_not_open' using errcode = 'P0001';
  end if;

  with acc as (
    update order_items set status = 'pending', accepted_at = now()
    where order_id = p_order_id and status = 'new'
    returning name_snapshot, qty, note, options
  )
  select coalesce(jsonb_agg(to_jsonb(acc)), '[]'::jsonb) into v_items from acc;

  return jsonb_build_object('table_name', v_table, 'items', v_items);
end;
$$;
revoke execute on function accept_order_items(uuid) from public, anon;
grant execute on function accept_order_items(uuid) to authenticated;

-- Staff: take payment. GST rate and invoice series come from the café's own settings
-- (p_gst_rate_bps is kept so older screens still work, but the café's rate always wins).
create or replace function close_order(
  p_order_id        uuid,
  p_method          payment_method,
  p_gst_rate_bps    int,
  p_discount_type   text default null,  -- 'percent' | 'amount' | null
  p_discount_value  int  default 0,     -- percent: basis points (1000 = 10%); amount: paise
  p_discount_reason text default null
)
returns orders
language plpgsql security definer set search_path = public as $$
declare
  v_cafe     cafes%rowtype;
  v_subtotal int;
  v_discount int := 0;
  v_taxable  int;
  v_gst      int;
  v_order    orders;
  v_fy       text := financial_year(now());
  v_n        int;
begin
  if not is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select c.* into v_cafe from orders o join cafes c on c.id = o.cafe_id
  where o.id = p_order_id and o.cafe_id = my_cafe();
  if not found then
    raise exception 'order_not_open' using errcode = 'P0001';
  end if;

  -- Lets the guard triggers know this change comes from the official checkout.
  perform set_config('app.closing', 'on', true);

  update order_items set status = 'void' where order_id = p_order_id and status = 'new';

  select coalesce(sum(price_paise_snapshot * qty), 0) into v_subtotal
  from order_items where order_id = p_order_id and status in ('pending', 'ready', 'served');

  -- Server decides the discount; the screen's number is only a preview.
  if p_discount_type = 'percent' then
    if p_discount_value < 0 or p_discount_value > 10000 then
      raise exception 'invalid_discount' using errcode = 'P0001';
    end if;
    v_discount := (v_subtotal * p_discount_value + 5000) / 10000;
  elsif p_discount_type = 'amount' then
    if p_discount_value < 0 then
      raise exception 'invalid_discount' using errcode = 'P0001';
    end if;
    v_discount := least(p_discount_value, v_subtotal);
  elsif p_discount_type is not null then
    raise exception 'invalid_discount' using errcode = 'P0001';
  end if;

  v_taxable := v_subtotal - v_discount;
  v_gst := (v_taxable * v_cafe.gst_rate_bps + 5000) / 10000;

  update orders set
    status = 'paid', closed_at = now(),
    subtotal_paise = v_subtotal,
    discount_paise = v_discount,
    discount_reason = case when v_discount > 0 then nullif(left(trim(p_discount_reason), 60), '') end,
    gst_rate_bps = v_cafe.gst_rate_bps,
    gst_paise = v_gst,
    total_paise = v_taxable + v_gst
  where id = p_order_id and status = 'open'
  returning * into v_order;

  if not found then
    raise exception 'order_not_open' using errcode = 'P0001';
  end if;

  if v_order.total_paise > 0 then
    -- Each café has its own invoice series per financial year (row lock = no gaps, no duplicates).
    insert into invoice_counters (cafe_id, fy, last) values (v_cafe.id, v_fy, 1)
    on conflict (cafe_id, fy) do update set last = invoice_counters.last + 1
    returning last into v_n;

    update orders set invoice_no = v_cafe.invoice_prefix || '/' || v_fy || '/' || lpad(v_n::text, 5, '0')
    where id = p_order_id
    returning * into v_order;

    insert into payments (order_id, method, amount_paise)
    values (p_order_id, p_method, v_order.total_paise);
  end if;

  perform set_config('app.closing', 'off', true);
  return v_order;
end;
$$;
revoke execute on function close_order(uuid, payment_method, int, text, int, text) from public, anon;
grant execute on function close_order(uuid, payment_method, int, text, int, text) to authenticated;

-- Staff: move or merge an open order (both tables must be in the staff member's café).
create or replace function move_order(p_order_id uuid, p_to_table uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_from   orders%rowtype;
  v_to     orders%rowtype;
  v_from_t text;
  v_to_t   text;
begin
  if not is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select * into v_from from orders where id = p_order_id and status = 'open' and cafe_id = my_cafe() for update;
  if not found then
    raise exception 'order_not_open' using errcode = 'P0001';
  end if;
  if v_from.table_id = p_to_table then
    raise exception 'same_table' using errcode = 'P0001';
  end if;

  select name into v_to_t from tables where id = p_to_table and is_active and cafe_id = v_from.cafe_id;
  if not found then
    raise exception 'invalid_table' using errcode = 'P0001';
  end if;
  select name into v_from_t from tables where id = v_from.table_id;

  select * into v_to from orders where table_id = p_to_table and status = 'open' for update;

  if not found then
    -- Target is free: the order simply changes table.
    update orders set table_id = p_to_table where id = v_from.id;
    return jsonb_build_object('order_id', v_from.id, 'merged', false, 'from_table', v_from_t, 'to_table', v_to_t);
  end if;

  -- Target has an open order: merge everything into it, then drop the empty source order.
  update order_items set order_id = v_to.id where order_id = v_from.id;

  insert into order_guests (order_id, name, phone, marketing_consent, created_at)
  select v_to.id, g.name, g.phone, g.marketing_consent, g.created_at from order_guests g where g.order_id = v_from.id
  on conflict (order_id, phone) do update
    set marketing_consent = order_guests.marketing_consent or excluded.marketing_consent;
  delete from order_guests where order_id = v_from.id;

  -- Keep the earlier start time so "open for 40 min" stays true.
  update orders set created_at = least(v_to.created_at, v_from.created_at) where id = v_to.id;
  delete from orders where id = v_from.id;

  return jsonb_build_object('order_id', v_to.id, 'merged', true, 'from_table', v_from_t, 'to_table', v_to_t);
end;
$$;
revoke execute on function move_order(uuid, uuid) from public, anon;
grant execute on function move_order(uuid, uuid) to authenticated;
