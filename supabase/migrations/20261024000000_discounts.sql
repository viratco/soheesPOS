-- Discounts at payment time. Applied to the item subtotal BEFORE GST
-- (GST is charged on the discounted value, as per Indian GST rules).
--   subtotal_paise  = items total (unchanged meaning)
--   discount_paise  = amount taken off
--   gst_paise       = GST on (subtotal - discount)
--   total_paise     = subtotal - discount + gst

alter table orders
  add column if not exists discount_paise int not null default 0 check (discount_paise >= 0),
  add column if not exists discount_reason text check (char_length(discount_reason) <= 60);

-- Replace the 3-argument version so PostgREST has one unambiguous close_order.
drop function if exists close_order(uuid, payment_method, int);

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

  return v_order;
end;
$$;

revoke execute on function close_order(uuid, payment_method, int, text, int, text) from public, anon;
grant execute on function close_order(uuid, payment_method, int, text, int, text) to authenticated;
