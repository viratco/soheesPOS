-- Stock purchases: what the café buys to cook and sell (ramen packets, raw chicken,
-- vegetables, sauces...). Staff record each bill from a supplier: items, quantity,
-- unit and amount paid, so the owner sees what is spent on stock and who is owed.
--
-- Replaces the "delivery sales" section (20261027000000_delivery.sql), which was built on a
-- misunderstanding and never held any entries.

drop function if exists add_delivery_order(text, jsonb, text, text, timestamptz);
drop function if exists void_delivery_order(uuid, text);
drop table if exists delivery_items;
drop table if exists delivery_orders;

-- Today's date in India, for "bought today" defaults and date checks.
create or replace function today_ist() returns date
language sql stable as $$ select (now() at time zone 'Asia/Kolkata')::date $$;

create table if not exists purchases (
  id           uuid primary key default gen_random_uuid(),
  cafe_id      uuid not null default my_cafe() references cafes(id) on delete restrict,
  supplier     text check (char_length(supplier) <= 60),
  bill_no      text check (char_length(bill_no) <= 40),
  note         text check (char_length(note) <= 200),
  purchased_on date not null default today_ist(),
  payment      text not null default 'cash' check (payment in ('cash', 'upi', 'bank', 'credit')),  -- credit = pay later
  total_paise  int  not null check (total_paise >= 0),
  created_by   uuid default auth.uid(),
  created_at   timestamptz not null default now(),
  voided_at    timestamptz,                 -- entered by mistake: kept, but not counted
  void_reason  text check (char_length(void_reason) <= 60)
);
create index if not exists purchases_cafe_day on purchases (cafe_id, purchased_on);

create table if not exists purchase_items (
  id           uuid primary key default gen_random_uuid(),
  purchase_id  uuid not null references purchases(id) on delete cascade,
  cafe_id      uuid not null references cafes(id) on delete restrict,
  name         text not null check (char_length(name) between 1 and 80),
  qty          numeric(10, 3) not null check (qty > 0 and qty <= 100000),
  unit         text not null check (unit in ('kg', 'g', 'l', 'ml', 'pcs', 'packet', 'box', 'dozen', 'tray', 'bottle', 'can')),
  amount_paise int  not null check (amount_paise between 0 and 100000000)  -- what was paid for this line
);
create index if not exists purchase_items_purchase on purchase_items (purchase_id);
create index if not exists purchase_items_cafe_name on purchase_items (cafe_id, lower(name));

-- The café's staff (counter/owner logins) read their own; writes go through the functions below.
alter table purchases      enable row level security;
alter table purchase_items enable row level security;
drop policy if exists "staff read own purchases" on purchases;
create policy "staff read own purchases" on purchases for select to authenticated
  using ((select is_staff()) and cafe_id = (select my_cafe()));
drop policy if exists "staff read own purchase items" on purchase_items;
create policy "staff read own purchase items" on purchase_items for select to authenticated
  using ((select is_staff()) and cafe_id = (select my_cafe()));
revoke all on purchases, purchase_items from anon, authenticated;
grant select on purchases, purchase_items to authenticated;

-- Staff: record one supplier bill.
-- p_items: [{ "name": "Raw chicken", "qty": 5, "unit": "kg", "amount_paise": 110000 }, ...]
create or replace function add_purchase(
  p_items        jsonb,
  p_supplier     text default null,
  p_purchased_on date default null,
  p_payment      text default 'cash',
  p_bill_no      text default null,
  p_note         text default null
)
returns purchases
language plpgsql security definer set search_path = public as $$
declare
  v_cafe     uuid := my_cafe();
  v_purchase purchases;
  v_line     jsonb;
  v_total    bigint := 0;
begin
  if not is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 60 then
    raise exception 'invalid_cart' using errcode = 'P0001';
  end if;
  -- Not in the future; up to two months back, for catching up on old bills.
  if p_purchased_on is not null and (p_purchased_on > today_ist() or p_purchased_on < today_ist() - 62) then
    raise exception 'invalid_date' using errcode = 'P0001';
  end if;

  insert into purchases (cafe_id, supplier, bill_no, note, purchased_on, payment, total_paise)
  values (v_cafe, nullif(left(trim(p_supplier), 60), ''), nullif(left(trim(p_bill_no), 40), ''),
          nullif(left(trim(p_note), 200), ''), coalesce(p_purchased_on, today_ist()), coalesce(p_payment, 'cash'), 0)
  returning * into v_purchase;

  for v_line in select * from jsonb_array_elements(p_items) loop
    insert into purchase_items (purchase_id, cafe_id, name, qty, unit, amount_paise)
    values (v_purchase.id, v_cafe, regexp_replace(trim(v_line->>'name'), '\s+', ' ', 'g'),
            (v_line->>'qty')::numeric, lower(v_line->>'unit'), (v_line->>'amount_paise')::int);
    v_total := v_total + (v_line->>'amount_paise')::int;
  end loop;

  update purchases set total_paise = v_total where id = v_purchase.id returning * into v_purchase;
  return v_purchase;
end;
$$;
revoke execute on function add_purchase(jsonb, text, date, text, text, text) from public, anon;
grant execute on function add_purchase(jsonb, text, date, text, text, text) to authenticated;

-- Staff: a "pay later" bill has now been paid.
create or replace function settle_purchase(p_id uuid, p_payment text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_payment not in ('cash', 'upi', 'bank') then
    raise exception 'invalid_payment' using errcode = 'P0001';
  end if;
  update purchases set payment = p_payment
  where id = p_id and cafe_id = my_cafe() and payment = 'credit' and voided_at is null;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
end;
$$;
revoke execute on function settle_purchase(uuid, text) from public, anon;
grant execute on function settle_purchase(uuid, text) to authenticated;

-- Staff: mark an entry as a mistake. It stays on record but stops counting.
create or replace function void_purchase(p_id uuid, p_reason text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update purchases set voided_at = now(), void_reason = nullif(left(trim(p_reason), 60), '')
  where id = p_id and cafe_id = my_cafe() and voided_at is null;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
end;
$$;
revoke execute on function void_purchase(uuid, text) from public, anon;
grant execute on function void_purchase(uuid, text) to authenticated;
