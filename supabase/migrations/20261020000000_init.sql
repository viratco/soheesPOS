-- Sohee's Kitchen: dine-in QR ordering, v1 schema.
-- All money is integer paise. order_items snapshots name + price at order time.

-- ─── Enums ────────────────────────────────────────────────────────────────
create type order_status      as enum ('open', 'paid', 'cancelled');
create type order_item_status as enum ('pending', 'ready', 'served', 'void');
create type payment_method    as enum ('upi', 'cash');
create type staff_role        as enum ('staff', 'kitchen');

-- ─── Tables ───────────────────────────────────────────────────────────────
create table tables (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  qr_token   text not null unique default replace(gen_random_uuid()::text, '-', ''),
  is_active  boolean not null default true,
  sort_order int not null default 0
);

create table menu_categories (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  sort_order int not null default 0
);

create table menu_items (
  id           uuid primary key default gen_random_uuid(),
  category_id  uuid not null references menu_categories(id) on delete restrict,
  name         text not null,
  description  text,
  price_paise  int not null check (price_paise >= 0),
  image_url    text,
  is_available boolean not null default true,
  sort_order   int not null default 0,
  created_at   timestamptz not null default now()
);
create index on menu_items (category_id, sort_order);

create table orders (
  id             uuid primary key default gen_random_uuid(),
  table_id       uuid not null references tables(id) on delete restrict,
  status         order_status not null default 'open',
  note           text,
  created_at     timestamptz not null default now(),
  closed_at      timestamptz,
  -- Frozen when the order is closed (paid), so the bill never changes later.
  subtotal_paise int,
  gst_rate_bps   int,          -- basis points: 500 = 5%
  gst_paise      int,
  total_paise    int
);
-- At most one open order per table. This is what makes "append" race-safe.
create unique index one_open_order_per_table on orders (table_id) where status = 'open';
create index on orders (status);

create table order_items (
  id                   uuid primary key default gen_random_uuid(),
  order_id             uuid not null references orders(id) on delete restrict,
  menu_item_id         uuid references menu_items(id) on delete set null,
  name_snapshot        text not null,
  price_paise_snapshot int not null check (price_paise_snapshot >= 0),
  qty                  int not null check (qty between 1 and 50),
  note                 text check (char_length(note) <= 200),
  status               order_item_status not null default 'pending',
  source               text not null default 'customer' check (source in ('customer', 'staff')),
  created_at           timestamptz not null default now(),
  ready_at             timestamptz
);
create index on order_items (order_id);
create index kitchen_queue on order_items (created_at) where status = 'pending';

create table payments (
  id           uuid primary key default gen_random_uuid(),
  order_id     uuid not null references orders(id) on delete restrict,
  method       payment_method not null,
  amount_paise int not null check (amount_paise > 0),
  received_at  timestamptz not null default now()
);

-- Which auth users are staff vs the kitchen tablet.
create table staff (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  role         staff_role not null default 'staff',
  display_name text
);

-- ─── Role helpers ─────────────────────────────────────────────────────────
create function is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from staff where user_id = auth.uid() and role = 'staff');
$$;

create function is_kitchen_or_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from staff where user_id = auth.uid());
$$;

-- ─── Row Level Security ───────────────────────────────────────────────────
-- Customers (anon) never touch tables/orders directly; they go through RPCs below.
alter table tables          enable row level security;
alter table menu_categories enable row level security;
alter table menu_items      enable row level security;
alter table orders          enable row level security;
alter table order_items     enable row level security;
alter table payments        enable row level security;
alter table staff           enable row level security;

create policy "menu readable by all"  on menu_categories for select using (true);
create policy "items readable by all" on menu_items      for select using (true);
create policy "staff manage categories" on menu_categories for all using (is_staff()) with check (is_staff());
create policy "staff manage items"      on menu_items      for all using (is_staff()) with check (is_staff());

create policy "staff+kitchen read tables" on tables for select using (is_kitchen_or_staff());
create policy "staff manage tables"       on tables for all    using (is_staff()) with check (is_staff());

create policy "staff+kitchen read orders" on orders for select using (is_kitchen_or_staff());
create policy "staff manage orders"       on orders for all    using (is_staff()) with check (is_staff());

create policy "staff+kitchen read items" on order_items for select using (is_kitchen_or_staff());
create policy "staff manage items"       on order_items for all    using (is_staff()) with check (is_staff());

create policy "staff manage payments" on payments for all using (is_staff()) with check (is_staff());

create policy "read own staff row" on staff for select using (user_id = auth.uid());

-- ─── RPCs ─────────────────────────────────────────────────────────────────

-- Customer: resolve a QR token to a table (without exposing other tables' tokens).
create function get_table_by_token(p_qr_token text)
returns table (id uuid, name text)
language sql stable security definer set search_path = public as $$
  select t.id, t.name from tables t where t.qr_token = p_qr_token and t.is_active;
$$;

-- Shared by customer + staff paths: append items to a table's open order,
-- opening one if needed. Prices come from menu_items here, never from the client.
-- p_items: [{ "menu_item_id": uuid, "qty": int, "note": text|null }, ...]
create function append_items(p_table_id uuid, p_items jsonb, p_source text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_order_id uuid;
  v_count    int;
  v_inserted jsonb;
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0
     or jsonb_array_length(p_items) > 30 then
    raise exception 'invalid_cart' using errcode = 'P0001';
  end if;

  -- Every requested item must exist and be available.
  select count(*) into v_count
  from jsonb_to_recordset(p_items) as c(menu_item_id uuid, qty int, note text)
  left join menu_items m on m.id = c.menu_item_id and m.is_available
  where m.id is null or c.qty is null or c.qty not between 1 and 50;
  if v_count > 0 then
    raise exception 'item_unavailable' using errcode = 'P0001';
  end if;

  -- Find-or-create the open order. The partial unique index serialises racing submits.
  insert into orders (table_id) values (p_table_id)
  on conflict (table_id) where status = 'open' do nothing;
  select id into v_order_id from orders
  where table_id = p_table_id and status = 'open'
  for update;

  with ins as (
    insert into order_items (order_id, menu_item_id, name_snapshot, price_paise_snapshot, qty, note, source)
    select v_order_id, m.id, m.name, m.price_paise, c.qty,
           nullif(left(trim(c.note), 200), ''), p_source
    from jsonb_to_recordset(p_items) as c(menu_item_id uuid, qty int, note text)
    join menu_items m on m.id = c.menu_item_id
    returning id, name_snapshot, price_paise_snapshot, qty, note
  )
  select jsonb_agg(to_jsonb(ins)) into v_inserted from ins;

  return jsonb_build_object('order_id', v_order_id, 'items', v_inserted);
end;
$$;

-- Customer: submit a cart from the QR page.
create function place_order(p_qr_token text, p_items jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_table tables%rowtype;
begin
  select * into v_table from tables where qr_token = p_qr_token and is_active;
  if not found then
    raise exception 'invalid_table' using errcode = 'P0001';
  end if;
  return append_items(v_table.id, p_items, 'customer')
         || jsonb_build_object('table_name', v_table.name);
end;
$$;

-- Staff: add items for a customer who didn't scan.
create function staff_add_items(p_table_id uuid, p_items jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_name text;
begin
  if not is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select name into v_name from tables where id = p_table_id;
  if not found then
    raise exception 'invalid_table' using errcode = 'P0001';
  end if;
  return append_items(p_table_id, p_items, 'staff')
         || jsonb_build_object('table_name', v_name);
end;
$$;

-- Kitchen: mark a pending item ready.
create function mark_item_ready(p_item_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_kitchen_or_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update order_items set status = 'ready', ready_at = now()
  where id = p_item_id and status = 'pending';
end;
$$;

-- Staff: take payment and close the table. Freezes the bill on the order row.
create function close_order(p_order_id uuid, p_method payment_method, p_gst_rate_bps int)
returns orders
language plpgsql security definer set search_path = public as $$
declare
  v_subtotal int;
  v_gst      int;
  v_order    orders;
begin
  if not is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select coalesce(sum(price_paise_snapshot * qty), 0) into v_subtotal
  from order_items where order_id = p_order_id and status <> 'void';

  -- Integer rounding to the nearest paisa.
  v_gst := (v_subtotal * p_gst_rate_bps + 5000) / 10000;

  update orders set
    status = 'paid', closed_at = now(),
    subtotal_paise = v_subtotal, gst_rate_bps = p_gst_rate_bps,
    gst_paise = v_gst, total_paise = v_subtotal + v_gst
  where id = p_order_id and status = 'open'
  returning * into v_order;

  if not found then
    raise exception 'order_not_open' using errcode = 'P0001';
  end if;

  if v_order.total_paise > 0 then
    insert into payments (order_id, method, amount_paise)
    values (p_order_id, p_method, v_order.total_paise);
  end if;

  return v_order;
end;
$$;

revoke execute on all functions in schema public from public, anon;
revoke execute on function append_items(uuid, jsonb, text) from authenticated;  -- internal only
grant execute on function get_table_by_token(text)          to anon, authenticated;
grant execute on function place_order(text, jsonb)          to anon, authenticated;
grant execute on function staff_add_items(uuid, jsonb)      to authenticated;
grant execute on function mark_item_ready(uuid)             to authenticated;
grant execute on function close_order(uuid, payment_method, int) to authenticated;
grant execute on function is_staff()                        to anon, authenticated;
grant execute on function is_kitchen_or_staff()             to anon, authenticated;  -- policies call these for anon too

-- ─── Realtime ─────────────────────────────────────────────────────────────
alter publication supabase_realtime add table orders, order_items;
