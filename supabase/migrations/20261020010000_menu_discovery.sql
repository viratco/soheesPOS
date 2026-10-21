-- Menu discovery: diet, spice, best sellers, moods, combos.
-- Powers the customer "Start here" / mood / combo sections and the Veg·Egg·Non-veg switch.

alter table menu_items
  add column if not exists diet         text     not null default 'veg' check (diet in ('veg', 'egg', 'nonveg')),
  add column if not exists spice_level  smallint not null default 0     check (spice_level between 0 and 3),
  add column if not exists is_bestseller boolean not null default false,
  -- Short social-proof / guidance label shown on the card, e.g. '#1 ordered', 'Try this first'.
  add column if not exists badge        text     check (char_length(badge) <= 24),
  -- Which "In the mood for…" chips the item appears under.
  add column if not exists moods        text[]   not null default '{}'
                          check (moods <@ array['meal', 'share', 'drink']::text[]),
  -- A combo is an ordinary menu item (own price, contents in the description),
  -- so ordering, snapshots and billing need no special handling.
  add column if not exists is_combo     boolean  not null default false;
