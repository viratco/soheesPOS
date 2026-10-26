// Lists every café, or switches one off/on (e.g. unpaid subscription). Switching off
// locks its logins out and stops its QR menu; nothing is deleted.
// Usage: npm run cafes
//        npm run cafes -- --off brew-bros
//        npm run cafes -- --on brew-bros
import { arg, db, must } from "./lib/db.mjs";

const off = arg("--off"), on = arg("--on");
if (off || on) {
  const rows = await must(db.from("cafes").update({ is_active: !!on }).eq("slug", off ?? on).select("name"));
  console.log(rows.length ? `${rows[0].name} is now ${on ? "ON" : "OFF"}` : `No café with slug "${off ?? on}".`);
  process.exit(0);
}

const cafes = await must(db.from("cafes").select("id, slug, name, is_active, created_at").order("created_at"));
const since = new Date(Date.now() - 7 * 24 * 3600_000).toISOString();
for (const c of cafes) {
  const count = async (t, q = (x) => x) => (await q(db.from(t).select("*", { count: "exact", head: true }).eq("cafe_id", c.id))).count ?? 0;
  const [tables, dishes, logins, orders7d] = await Promise.all([
    count("tables"),
    count("menu_items"),
    count("staff"),
    count("orders", (x) => x.gte("created_at", since)),
  ]);
  console.log(
    `${c.is_active ? "●" : "○"} ${c.name.padEnd(24)} ${c.slug.padEnd(16)} tables ${String(tables).padStart(3)} · dishes ${String(dishes).padStart(3)} · logins ${logins} · orders (7 days) ${orders7d}`,
  );
}
