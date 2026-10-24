-- Dish options & add-ons (e.g. Veg / Chicken +₹50 / Pork +₹80, Half / Full +₹140, extra sauces).
--
-- menu_items.options = [
--   { "name": "Choice", "min": 1, "max": 1,
--     "choices": [ { "name": "Veg", "price": 0 }, { "name": "Chicken", "price": 5000 } ] },
--   { "name": "Add On", "min": 0, "max": 3, "choices": [ ... ] } ]          (prices in paise)
--
-- A cart line sends   "options": [ { "group": "Choice", "name": "Chicken" }, ... ]
-- The server validates every pick against the menu and charges base + option prices.
-- order_items.options keeps a snapshot [{ group, name, price }], and price_paise_snapshot
-- is the per-unit price INCLUDING options, so billing, invoices and discounts work as before.

alter table menu_items add column if not exists options jsonb not null default '[]'::jsonb
  check (jsonb_typeof(options) = 'array');
alter table order_items add column if not exists options jsonb
  check (options is null or jsonb_typeof(options) = 'array');

create or replace function append_items(p_table_id uuid, p_items jsonb, p_source text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
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
    where id = (v_line->>'menu_item_id')::uuid and is_available;
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

-- Accepting an order also reports the options, for the chef's WhatsApp alert.
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
    returning name_snapshot, qty, note, options
  )
  select coalesce(jsonb_agg(to_jsonb(acc)), '[]'::jsonb) into v_items from acc;

  select t.name into v_table from orders o join tables t on t.id = o.table_id where o.id = p_order_id;
  return jsonb_build_object('table_name', v_table, 'items', v_items);
end;
$$;
revoke execute on function accept_order_items(uuid) from public, anon;
grant execute on function accept_order_items(uuid) to authenticated;
