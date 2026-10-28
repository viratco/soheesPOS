-- Paste this whole file into Supabase SQL Editor (New query) and click Run.
-- Offline mode for the counter, plus each café's own floor plan. Safe to run more than once.

-- Each café can have its own floor plan (walls, door, counter, where each table stands).
-- Shape: see frontend/lib/floorPlan.ts. Empty = the app draws a tidy grid of the café's tables
-- (Sohee's Kitchen's room is built into the app).
alter table cafes add column if not exists floor_plan jsonb
  check (floor_plan is null or jsonb_typeof(floor_plan) = 'object');

-- Offline mode for the counter.
--
-- When the café's internet drops, the counter keeps taking orders and bills on the device
-- and sends everything here once it's back. This makes that catch-up safe:
--
--   * Each counter device gets a letter (A, B, C…) and its own invoice series for bills
--     paid while offline: SK/2026-27/A0001, A0002… The device numbers them itself, so the
--     printed bill already has its real number, and it can never clash with the main series.
--   * Sending the same change twice does nothing the second time (dishes carry an id made on
--     the device, bills carry their invoice number), so a shaky connection can't double anything.
--   * Changes keep the time they really happened: a bill paid at 8:18 is saved as 8:18.
--   * An offline bill is saved exactly as it was printed; anything that had to differ is noted
--     on the order (orders.offline_note) for the owner to see.
--   * The guest QR page can tell when no counter has checked in for a while.

-- ─── 1. Counter devices and their offline invoice series ─────────────────────
create table if not exists counter_devices (
  id           uuid primary key,  -- made on the device
  cafe_id      uuid not null references cafes(id) on delete cascade,
  letter       text not null check (letter ~ '^[A-Z]$'),
  label        text check (char_length(label) <= 60),
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique (cafe_id, letter)
);
alter table counter_devices enable row level security;  -- only reachable through the functions below
revoke all on counter_devices from anon, authenticated;

-- Last offline invoice number per letter and financial year. Kept per letter (not per device),
-- so a letter handed to a new device carries on its series without repeating a number.
create table if not exists offline_series (
  cafe_id uuid not null references cafes(id) on delete cascade,
  letter  text not null check (letter ~ '^[A-Z]$'),
  fy      text not null,
  last    int  not null default 0,
  primary key (cafe_id, letter, fy)
);
alter table offline_series enable row level security;
revoke all on offline_series from anon, authenticated;

-- What the server had to adjust while saving an offline bill, in plain words.
alter table orders add column if not exists offline_note text check (char_length(offline_note) <= 600);

-- When an offline change happened: the device's time, but never in the future
-- and never more than 30 days back (a device with a wrong clock can't rewrite history).
create or replace function offline_time(p_at timestamptz) returns timestamptz
language sql stable as $$
  select case when p_at is null then now()
              else least(now(), greatest(p_at, now() - interval '30 days')) end;
$$;

-- ─── 2. Counter check-in ─────────────────────────────────────────────────────
-- Called by the counter screen when it opens and every minute while online.
-- Returns the device's letter and where its offline series stands.
create or replace function register_counter(p_device_id uuid, p_label text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_cafe   uuid := my_cafe();
  v_dev    counter_devices%rowtype;
  v_letter text;
  v_series jsonb;
begin
  if not is_staff() or p_device_id is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select * into v_dev from counter_devices where id = p_device_id;
  if found and v_dev.cafe_id <> v_cafe then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if found then
    v_letter := v_dev.letter;
    update counter_devices
    set last_seen_at = now(), label = coalesce(nullif(left(trim(p_label), 60), ''), label)
    where id = p_device_id;
  else
    select l into v_letter
    from unnest(string_to_array('A,B,C,D,E,F,G,H,I,J,K,L,M,N,O,P,Q,R,S,T,U,V,W,X,Y,Z', ',')) l
    where l not in (select letter from counter_devices where cafe_id = v_cafe)
    order by l limit 1;
    if v_letter is null then
      -- All 26 letters in use: take over the one idle longest (30+ days). Its series carries on.
      select letter into v_letter from counter_devices
      where cafe_id = v_cafe and last_seen_at < now() - interval '30 days'
      order by last_seen_at limit 1;
      if v_letter is null then
        raise exception 'too_many_devices' using errcode = 'P0001';
      end if;
      delete from counter_devices where cafe_id = v_cafe and letter = v_letter;
    end if;
    insert into counter_devices (id, cafe_id, letter, label)
    values (p_device_id, v_cafe, v_letter, nullif(left(trim(p_label), 60), ''));
  end if;

  select coalesce(jsonb_object_agg(fy, last), '{}'::jsonb) into v_series
  from offline_series where cafe_id = v_cafe and letter = v_letter;

  return jsonb_build_object(
    'letter', v_letter,
    'prefix', (select invoice_prefix from cafes where id = v_cafe),
    'series', v_series
  );
end;
$$;
revoke execute on function register_counter(uuid, text) from public, anon;
grant execute on function register_counter(uuid, text) to authenticated;

-- Guest QR page: when did any counter of this table's café last check in?
create or replace function counter_last_seen(p_qr_token text)
returns timestamptz
language sql stable security definer set search_path = public as $$
  select max(d.last_seen_at)
  from tables t join counter_devices d on d.cafe_id = t.cafe_id
  where t.qr_token = p_qr_token and t.is_active;
$$;
revoke execute on function counter_last_seen(text) from public;
grant execute on function counter_last_seen(text) to anon, authenticated;

-- ─── 3. Adding dishes: safe to send twice, keeps its real time ───────────────
-- Staff calls may now pass, per dish, an "id" made on the device, plus the order id to use if
-- the table has no open order yet, and when it happened. If a dish id is already saved, the
-- whole call was sent before and nothing happens.
-- p_offline (staff only): the dish was already served while offline, so a dish switched off
-- or an option renamed since then must not stop it from being saved.
drop function if exists append_items(uuid, jsonb, text);
create or replace function append_items(
  p_table_id uuid,
  p_items    jsonb,
  p_source   text,
  p_order_id uuid        default null,
  p_at       timestamptz default null,
  p_offline  boolean     default false
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_staff    boolean := p_source = 'staff';
  v_offline  boolean := p_source = 'staff' and coalesce(p_offline, false);
  v_at       timestamptz := case when p_source = 'staff' then offline_time(p_at) else now() end;
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

  -- Sent before (a retry after a dropped connection): already saved.
  if v_staff then
    select oi.order_id into v_order_id from order_items oi
    where oi.cafe_id = v_cafe
      and oi.id in (select (l->>'id')::uuid from jsonb_array_elements(p_items) l where l->>'id' is not null)
    limit 1;
    if found then
      return jsonb_build_object('order_id', v_order_id, 'items', '[]'::jsonb, 'replay', true);
    end if;
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
  -- A new order takes the counter's id, unless that id is already used (an order since closed).
  insert into orders (id, table_id, created_at)
  values (
    case when v_staff and p_order_id is not null and not exists (select 1 from orders where id = p_order_id)
         then p_order_id else gen_random_uuid() end,
    p_table_id, v_at
  )
  on conflict (table_id) where status = 'open' do nothing;
  select id into v_order_id from orders
  where table_id = p_table_id and status = 'open'
  for update;

  -- Any error below rolls back the whole submission, so nothing is half-saved.
  for v_line in select * from jsonb_array_elements(p_items) loop
    select * into v_item from menu_items
    where id = (v_line->>'menu_item_id')::uuid and (is_available or v_offline) and cafe_id = v_cafe;
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
    -- (Offline: a pick renamed since is kept by name, at no extra charge.)
    v_extra := 0;
    v_snap := '[]'::jsonb;
    for v_pick in select * from jsonb_array_elements(v_sel) loop
      select (c->>'price')::int into v_price
      from jsonb_array_elements(v_item.options) g, jsonb_array_elements(g->'choices') c
      where g->>'name' = v_pick->>'group' and c->>'name' = v_pick->>'name'
      limit 1;
      if not found then
        if not v_offline then
          raise exception 'invalid_options' using errcode = 'P0001';
        end if;
        v_price := 0;
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

    -- Each group's min/max (e.g. "pick exactly 1"). Offline dishes were already served as picked.
    if not v_offline then
      for v_group in select * from jsonb_array_elements(v_item.options) loop
        select count(*) into v_count from jsonb_array_elements(v_sel) s where s->>'group' = v_group->>'name';
        if v_count < coalesce((v_group->>'min')::int, 0) or v_count > coalesce((v_group->>'max')::int, 1) then
          raise exception 'invalid_options' using errcode = 'P0001';
        end if;
      end loop;
    end if;

    insert into order_items (id, order_id, menu_item_id, name_snapshot, price_paise_snapshot, qty, note, source, status,
                             created_at, accepted_at, options)
    values (
      coalesce(case when v_staff then (v_line->>'id')::uuid end, gen_random_uuid()),
      v_order_id, v_item.id, v_item.name, v_item.price_paise + v_extra, v_qty,
      nullif(left(trim(v_line->>'note'), 200), ''), p_source, v_status,
      v_at, case when v_status = 'pending' then v_at end,
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
revoke execute on function append_items(uuid, jsonb, text, uuid, timestamptz, boolean) from public, anon, authenticated;

-- Staff: add items for a guest who didn't scan (own café's tables only).
drop function if exists staff_add_items(uuid, jsonb);
create or replace function staff_add_items(
  p_table_id uuid,
  p_items    jsonb,
  p_order_id uuid        default null,
  p_at       timestamptz default null,
  p_offline  boolean     default false
)
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
  return append_items(p_table_id, p_items, 'staff', p_order_id, p_at, p_offline)
         || jsonb_build_object('table_name', v_name);
end;
$$;
revoke execute on function staff_add_items(uuid, jsonb, uuid, timestamptz, boolean) from public, anon;
grant execute on function staff_add_items(uuid, jsonb, uuid, timestamptz, boolean) to authenticated;

-- ─── 4. Accepting QR dishes: only the ones staff actually saw ────────────────
-- p_item_ids: accept just these (a QR order that arrived while the counter was offline
-- stays waiting instead of reaching the kitchen unseen). Null = every waiting dish, as before.
drop function if exists accept_order_items(uuid);
create or replace function accept_order_items(p_order_id uuid, p_item_ids uuid[] default null, p_at timestamptz default null)
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
    update order_items set status = 'pending', accepted_at = offline_time(p_at)
    where order_id = p_order_id and status = 'new' and (p_item_ids is null or id = any(p_item_ids))
    returning name_snapshot, qty, note, options
  )
  select coalesce(jsonb_agg(to_jsonb(acc)), '[]'::jsonb) into v_items from acc;

  return jsonb_build_object('table_name', v_table, 'items', v_items);
end;
$$;
revoke execute on function accept_order_items(uuid, uuid[], timestamptz) from public, anon;
grant execute on function accept_order_items(uuid, uuid[], timestamptz) to authenticated;

-- ─── 5. A bill paid while offline ────────────────────────────────────────────
-- Saved exactly as printed: the dishes on it (p_item_ids), its invoice number from the
-- device's own series, and the time it was paid. If anything has to differ (a dish added on
-- another device meanwhile, a price changed, the number already used), the bill is still saved
-- and the difference is written to orders.offline_note.
create or replace function close_order_offline(
  p_order_id        uuid,
  p_method          payment_method,
  p_item_ids        uuid[],
  p_expected_total  int,
  p_closed_at       timestamptz,
  p_device_id       uuid default null,
  p_invoice_no      text default null,  -- null: the device had no series yet; the main series is used
  p_discount_type   text default null,  -- 'percent' | 'amount' | null
  p_discount_value  int  default 0,     -- percent: basis points (1000 = 10%); amount: paise
  p_discount_reason text default null
)
returns orders
language plpgsql security definer set search_path = public as $$
declare
  v_order    orders;
  v_cafe     cafes%rowtype;
  v_at       timestamptz := offline_time(p_closed_at);
  v_ids      uuid[] := coalesce(p_item_ids, '{}');
  v_notes    text[] := '{}';
  v_letter   text;
  v_m        text[];
  v_invoice  text;
  v_fy       text;
  v_n        int;
  v_count    int;
  v_subtotal int;
  v_discount int := 0;
  v_taxable  int;
  v_gst      int;
begin
  if not is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_order from orders where id = p_order_id and cafe_id = my_cafe() for update;
  if not found then
    raise exception 'order_not_found' using errcode = 'P0001';
  end if;
  select * into v_cafe from cafes where id = v_order.cafe_id;

  if v_order.status = 'paid' then
    -- Sent before (a retry): already saved.
    if (p_invoice_no is not null and v_order.invoice_no = p_invoice_no)
       or (p_invoice_no is null and v_order.closed_at = v_at) then
      return v_order;
    end if;
    raise exception 'already_paid' using errcode = 'P0001', detail = coalesce(v_order.invoice_no, '');
  end if;
  if v_order.status = 'cancelled' then
    raise exception 'order_cancelled' using errcode = 'P0001';
  end if;

  -- Lets the guard triggers know this change comes from the official checkout.
  perform set_config('app.closing', 'on', true);

  -- The bill is exactly what was printed. Dishes not on it are left off…
  select count(*) into v_count from order_items
  where order_id = p_order_id and status not in ('void', 'new') and not (id = any(v_ids));
  if v_count > 0 then
    v_notes := v_notes || format('%s dish(es) added on another device were not on the printed bill, so they were left off.', v_count);
  end if;
  update order_items set status = 'void' where order_id = p_order_id and status <> 'void' and not (id = any(v_ids));

  -- …and dishes on it are billed, even if someone removed them elsewhere meanwhile.
  select count(*) into v_count from order_items where order_id = p_order_id and id = any(v_ids) and status = 'void';
  if v_count > 0 then
    v_notes := v_notes || format('%s dish(es) removed on another device were on the printed bill, so they were kept.', v_count);
  end if;
  update order_items set status = 'served' where order_id = p_order_id and id = any(v_ids) and status in ('new', 'void');

  select count(*) into v_count from order_items where order_id = p_order_id and id = any(v_ids);
  if v_count < cardinality(v_ids) then
    v_notes := v_notes || format('%s dish(es) on the printed bill could not be found.', cardinality(v_ids) - v_count);
  end if;

  select coalesce(sum(price_paise_snapshot * qty), 0) into v_subtotal
  from order_items where order_id = p_order_id and id = any(v_ids);

  if p_discount_type = 'percent' then
    v_discount := (v_subtotal * least(10000, greatest(0, p_discount_value)) + 5000) / 10000;
  elsif p_discount_type = 'amount' then
    v_discount := least(greatest(0, p_discount_value), v_subtotal);
  end if;
  v_taxable := v_subtotal - v_discount;
  v_gst := (v_taxable * v_cafe.gst_rate_bps + 5000) / 10000;

  if p_expected_total is not null and v_taxable + v_gst <> p_expected_total then
    v_notes := v_notes || format('Printed bill said Rs %s; saved as Rs %s (a price or the GST rate changed meanwhile).',
      to_char(p_expected_total / 100.0, 'FM99999990.00'), to_char((v_taxable + v_gst) / 100.0, 'FM99999990.00'));
  end if;

  if v_taxable + v_gst > 0 then
    -- The device's own number, if it really is this device's series and not used yet.
    if p_invoice_no is not null then
      select letter into v_letter from counter_devices where id = p_device_id and cafe_id = v_order.cafe_id;
      v_m := regexp_match(p_invoice_no, '^([A-Z0-9]{1,6})/([0-9]{4}-[0-9]{2})/([A-Z])([0-9]{4})$');
      if v_letter is not null and v_m is not null and v_m[3] = v_letter
         and not exists (select 1 from orders where cafe_id = v_order.cafe_id and invoice_no = p_invoice_no) then
        v_invoice := p_invoice_no;
        insert into offline_series (cafe_id, letter, fy, last) values (v_order.cafe_id, v_letter, v_m[2], v_m[4]::int)
        on conflict (cafe_id, letter, fy) do update set last = greatest(offline_series.last, excluded.last);
      end if;
    end if;

    if v_invoice is null then
      v_fy := financial_year(v_at);
      insert into invoice_counters (cafe_id, fy, last) values (v_order.cafe_id, v_fy, 1)
      on conflict (cafe_id, fy) do update set last = invoice_counters.last + 1
      returning last into v_n;
      v_invoice := v_cafe.invoice_prefix || '/' || v_fy || '/' || lpad(v_n::text, 5, '0');
      if p_invoice_no is not null then
        v_notes := v_notes || format('Printed as invoice %s, which could not be used; saved as %s.', p_invoice_no, v_invoice);
      end if;
    end if;
  end if;

  update orders set
    status = 'paid', closed_at = v_at,
    subtotal_paise = v_subtotal,
    discount_paise = v_discount,
    discount_reason = case when v_discount > 0 then nullif(left(trim(p_discount_reason), 60), '') end,
    gst_rate_bps = v_cafe.gst_rate_bps,
    gst_paise = v_gst,
    total_paise = v_taxable + v_gst,
    invoice_no = v_invoice,
    offline_note = left(nullif(array_to_string(v_notes, ' '), ''), 600)
  where id = p_order_id
  returning * into v_order;

  if v_order.total_paise > 0 then
    insert into payments (order_id, method, amount_paise, received_at)
    values (p_order_id, p_method, v_order.total_paise, v_at);
  end if;

  perform set_config('app.closing', 'off', true);
  return v_order;
end;
$$;
revoke execute on function close_order_offline(uuid, payment_method, uuid[], int, timestamptz, uuid, text, text, int, text) from public, anon;
grant execute on function close_order_offline(uuid, payment_method, uuid[], int, timestamptz, uuid, text, text, int, text) to authenticated;

revoke execute on function offline_time(timestamptz) from public, anon;
