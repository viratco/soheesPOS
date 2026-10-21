-- DANGER: deletes ALL Sohee's Kitchen data (menu, tables, orders, payments).
-- Only use while setting up, then re-run the migration file.
drop table if exists payments, order_items, orders, menu_items, menu_categories, tables, staff cascade;
drop function if exists close_order(uuid, payment_method, int), mark_item_ready(uuid),
  staff_add_items(uuid, jsonb), place_order(text, jsonb), append_items(uuid, jsonb, text),
  get_table_by_token(text), is_kitchen_or_staff(), is_staff();
drop type if exists order_status, order_item_status, payment_method, staff_role;
