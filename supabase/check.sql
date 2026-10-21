-- Run in the Supabase SQL Editor. Expect: tables = 7, functions = 8, realtime = 2.
select
  (select count(*) from information_schema.tables
    where table_schema = 'public'
      and table_name in ('tables','menu_categories','menu_items','orders','order_items','payments','staff')) as tables,
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('is_staff','is_kitchen_or_staff','get_table_by_token','append_items',
                        'place_order','staff_add_items','mark_item_ready','close_order')) as functions,
  (select count(*) from pg_publication_tables
    where pubname = 'supabase_realtime' and tablename in ('orders','order_items')) as realtime;
