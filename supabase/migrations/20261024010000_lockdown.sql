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
