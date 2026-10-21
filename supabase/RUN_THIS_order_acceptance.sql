-- Paste this whole file into Supabase SQL Editor and click Run. Safe to run more than once.

-- Staff acceptance: customer QR orders arrive as 'new' and only reach the
-- kitchen ('pending') after staff tap "Accept & send to kitchen".
-- Staff-entered items skip acceptance.

alter type order_item_status add value if not exists 'new' before 'pending';

alter table order_items add column if not exists accepted_at timestamptz;

-- Customer items start as 'new'; staff items go straight to the kitchen.
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

-- Staff: accept every waiting item on an order and send it to the kitchen.
-- Returns what was accepted, for the chef's WhatsApp alert.
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

  with acc as (
    update order_items set status = 'pending', accepted_at = now()
    where order_id = p_order_id and status = 'new'
    returning name_snapshot, qty, note
  )
  select coalesce(jsonb_agg(to_jsonb(acc)), '[]'::jsonb) into v_items from acc;

  select t.name into v_table from orders o join tables t on t.id = o.table_id where o.id = p_order_id;
  return jsonb_build_object('table_name', v_table, 'items', v_items);
end;
$$;
revoke execute on function accept_order_items(uuid) from public, anon;
grant execute on function accept_order_items(uuid) to authenticated;

-- Bill only what was actually sent to the kitchen; anything still waiting is dropped.
create or replace function close_order(p_order_id uuid, p_method payment_method, p_gst_rate_bps int)
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

  update order_items set status = 'void' where order_id = p_order_id and status = 'new';

  select coalesce(sum(price_paise_snapshot * qty), 0) into v_subtotal
  from order_items where order_id = p_order_id and status in ('pending', 'ready', 'served');

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
