-- DotPe-style menu layout.
-- Poster image for each category tile on the customer landing grid.
alter table menu_categories add column if not exists image_url text;
-- Sub-category inside a category (e.g. Signatures → French Fries, Kimbap, Mandu).
-- Shown as photo tabs; items with no sub-category are grouped under "More".
alter table menu_items add column if not exists subcategory text check (char_length(subcategory) <= 40);
