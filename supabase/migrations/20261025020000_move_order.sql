-- Staff: move an open order to another table, or merge it into that table's open order.
-- Items, kitchen progress and guest details all come along; nothing is lost or re-sent.

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

  select * into v_from from orders where id = p_order_id and status = 'open' for update;
  if not found then
    raise exception 'order_not_open' using errcode = 'P0001';
  end if;
  if v_from.table_id = p_to_table then
    raise exception 'same_table' using errcode = 'P0001';
  end if;

  select name into v_to_t from tables where id = p_to_table and is_active;
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
