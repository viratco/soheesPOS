-- Each café can have its own floor plan (walls, door, counter, where each table stands).
-- Shape: see frontend/lib/floorPlan.ts. Empty = the app draws a tidy grid of the café's tables
-- (Sohee's Kitchen's room is built into the app).
alter table cafes add column if not exists floor_plan jsonb
  check (floor_plan is null or jsonb_typeof(floor_plan) = 'object');
