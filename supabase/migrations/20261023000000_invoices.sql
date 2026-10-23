-- GST tax invoices: every paid bill gets a sequential invoice number per
-- Indian financial year (April–March), e.g. SK/2026-27/00001.

alter table orders add column if not exists invoice_no text unique;

create table if not exists invoice_counters (
  fy   text primary key,          -- '2026-27'
  last int  not null default 0
);
alter table invoice_counters enable row level security;  -- only reachable via close_order

-- Financial year for a moment, in India time.
create or replace function financial_year(p_at timestamptz)
returns text
language sql stable as $$
  select case
    when extract(month from p_at at time zone 'Asia/Kolkata') >= 4
      then extract(year from p_at at time zone 'Asia/Kolkata')::int::text || '-'
           || lpad(((extract(year from p_at at time zone 'Asia/Kolkata')::int + 1) % 100)::text, 2, '0')
    else (extract(year from p_at at time zone 'Asia/Kolkata')::int - 1)::text || '-'
           || lpad((extract(year from p_at at time zone 'Asia/Kolkata')::int % 100)::text, 2, '0')
  end;
$$;

-- Same as before, plus: assigns the next invoice number (row lock = no gaps, no duplicates).
create or replace function close_order(p_order_id uuid, p_method payment_method, p_gst_rate_bps int)
returns orders
language plpgsql security definer set search_path = public as $$
declare
  v_subtotal int;
  v_gst      int;
  v_order    orders;
  v_fy       text := financial_year(now());
  v_n        int;
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
    insert into invoice_counters (fy, last) values (v_fy, 1)
    on conflict (fy) do update set last = invoice_counters.last + 1
    returning last into v_n;

    update orders set invoice_no = 'SK/' || v_fy || '/' || lpad(v_n::text, 5, '0')
    where id = p_order_id
    returning * into v_order;

    insert into payments (order_id, method, amount_paise)
    values (p_order_id, p_method, v_order.total_paise);
  end if;

  return v_order;
end;
$$;

revoke execute on function financial_year(timestamptz) from public, anon;
