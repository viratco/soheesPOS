-- Delivery sales: Zomato / Swiggy / phone orders, typed in by staff so the café sees
-- all its food revenue in one place. Prices are what the café actually charged on that
-- platform (often different from the dine-in menu), so they're entered, not looked up.
-- These are a sales record, not tax invoices: on Zomato/Swiggy the platform bills the guest.

create table if not exists delivery_orders (
  id          uuid primary key default gen_random_uuid(),
  cafe_id     uuid not null default my_cafe() references cafes(id) on delete restrict,
  platform    text not null check (platform in ('zomato', 'swiggy', 'phone', 'other')),
  ref         text check (char_length(ref) <= 40),    -- the platform's order number, optional
  note        text check (char_length(note) <= 200),
  ordered_at  timestamptz not null default now(),
  total_paise int  not null check (total_paise >= 0),
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now(),
  voided_at   timestamptz,                            -- entered by mistake: kept, but not counted
  void_reason text check (char_length(void_reason) <= 60)
);
create index if not exists delivery_orders_cafe_time on delivery_orders (cafe_id, ordered_at);

create table if not exists delivery_items (
  id                uuid primary key default gen_random_uuid(),
  delivery_order_id uuid not null references delivery_orders(id) on delete cascade,
  cafe_id           uuid not null references cafes(id) on delete restrict,
  menu_item_id      uuid references menu_items(id) on delete set null,  -- null for a typed-in dish
  name              text not null check (char_length(name) between 1 and 80),
  qty               int  not null check (qty between 1 and 100),
  price_paise       int  not null check (price_paise between 0 and 10000000)  -- per unit
);
create index if not exists delivery_items_order on delivery_items (delivery_order_id);

-- Staff of the café read their own; all writes go through the functions below.
alter table delivery_orders enable row level security;
alter table delivery_items  enable row level security;
drop policy if exists "staff read own deliveries" on delivery_orders;
create policy "staff read own deliveries" on delivery_orders for select to authenticated
  using ((select is_staff()) and cafe_id = (select my_cafe()));
drop policy if exists "staff read own delivery items" on delivery_items;
create policy "staff read own delivery items" on delivery_items for select to authenticated
  using ((select is_staff()) and cafe_id = (select my_cafe()));
revoke all on delivery_orders, delivery_items from anon, authenticated;
grant select on delivery_orders, delivery_items to authenticated;

-- Staff: record one delivery order.
-- p_items: [{ "menu_item_id": uuid|null, "name": text, "qty": int, "price_paise": int }, ...]
create or replace function add_delivery_order(
  p_platform   text,
  p_items      jsonb,
  p_ref        text default null,
  p_note       text default null,
  p_ordered_at timestamptz default null
)
returns delivery_orders
language plpgsql security definer set search_path = public as $$
declare
  v_cafe  uuid := my_cafe();
  v_order delivery_orders;
  v_line  jsonb;
  v_menu  uuid;
  v_total bigint := 0;
begin
  if not is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 50 then
    raise exception 'invalid_cart' using errcode = 'P0001';
  end if;
  -- Can't be in the future, or more than 31 days back (catching up on a missed day is fine).
  if p_ordered_at is not null and (p_ordered_at > now() + interval '5 minutes' or p_ordered_at < now() - interval '31 days') then
    raise exception 'invalid_date' using errcode = 'P0001';
  end if;

  insert into delivery_orders (cafe_id, platform, ref, note, ordered_at, total_paise)
  values (v_cafe, p_platform, nullif(left(trim(p_ref), 40), ''), nullif(left(trim(p_note), 200), ''),
          coalesce(p_ordered_at, now()), 0)
  returning * into v_order;

  for v_line in select * from jsonb_array_elements(p_items) loop
    -- A linked dish must be this café's own.
    v_menu := nullif(v_line->>'menu_item_id', '')::uuid;
    if v_menu is not null and not exists (select 1 from menu_items where id = v_menu and cafe_id = v_cafe) then
      v_menu := null;
    end if;
    insert into delivery_items (delivery_order_id, cafe_id, menu_item_id, name, qty, price_paise)
    values (v_order.id, v_cafe, v_menu, left(trim(v_line->>'name'), 80),
            (v_line->>'qty')::int, (v_line->>'price_paise')::int);
    v_total := v_total + (v_line->>'qty')::int * (v_line->>'price_paise')::int;
  end loop;

  update delivery_orders set total_paise = v_total where id = v_order.id returning * into v_order;
  return v_order;
end;
$$;
revoke execute on function add_delivery_order(text, jsonb, text, text, timestamptz) from public, anon;
grant execute on function add_delivery_order(text, jsonb, text, text, timestamptz) to authenticated;

-- Staff: mark an entry as a mistake. It stays on record but stops counting.
create or replace function void_delivery_order(p_id uuid, p_reason text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update delivery_orders set voided_at = now(), void_reason = nullif(left(trim(p_reason), 60), '')
  where id = p_id and cafe_id = my_cafe() and voided_at is null;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
end;
$$;
revoke execute on function void_delivery_order(uuid, text) from public, anon;
grant execute on function void_delivery_order(uuid, text) to authenticated;
