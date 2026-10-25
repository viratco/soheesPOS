-- Guest name + mobile number collected before a QR order is placed.
-- Kept in their own table so only staff can read them: the kitchen tablet login
-- can read orders, but must not see guests' phone numbers.

create table if not exists order_guests (
  id                uuid primary key default gen_random_uuid(),
  order_id          uuid not null references orders(id) on delete cascade,
  name              text not null check (char_length(name) between 1 and 60),
  phone             text not null check (phone ~ '^[6-9][0-9]{9}$'),   -- Indian mobile, 10 digits
  marketing_consent boolean not null default false,                   -- ticked "send me offers"
  created_at        timestamptz not null default now(),
  unique (order_id, phone)
);
create index if not exists order_guests_phone on order_guests (phone);

alter table order_guests enable row level security;
drop policy if exists "staff read guests" on order_guests;
create policy "staff read guests" on order_guests for select using (is_staff());
-- Written only by place_order (security definer); nobody writes directly.
revoke all on order_guests from anon, authenticated;
grant select on order_guests to authenticated;

-- place_order now takes the guest's details. They're optional at the database level
-- so phones that still have the previous version of the menu open keep working;
-- the menu itself requires them.
drop function if exists place_order(text, jsonb);
create or replace function place_order(p_qr_token text, p_items jsonb, p_customer jsonb default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_table  tables%rowtype;
  v_result jsonb;
  v_name   text;
  v_phone  text;
begin
  select * into v_table from tables where qr_token = p_qr_token and is_active;
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
