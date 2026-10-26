// Daily pilot report: what happened at the café on a given day.
// Usage: npm run report                               (Sohee's, today, India time)
//        npm run report -- 2026-10-25                 (a specific day)
//        npm run report -- --cafe brew-bros 2026-10-25 (another café)
import { cafeFromArgs, db } from "./lib/db.mjs";

const cafe = await cafeFromArgs("sohees");
const IST = 5.5 * 3600_000;
const day = process.argv.find((a) => /^\d{4}-\d{2}-\d{2}$/.test(a)) ?? new Date(Date.now() + IST).toISOString().slice(0, 10);
const start = new Date(new Date(`${day}T00:00:00Z`).getTime() - IST);
const end = new Date(start.getTime() + 24 * 3600_000);

const rupees = (p) => "₹" + (p / 100).toLocaleString("en-IN", { maximumFractionDigits: 2 });
const mins = (a, b) => (new Date(b) - new Date(a)) / 60_000;
const median = (xs) => {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.floor(s.length / 2)];
};
const fmtMin = (m) => (m == null ? "—" : m < 1 ? `${Math.round(m * 60)}s` : `${m.toFixed(1)} min`);
const ist = (iso) => new Date(iso).toLocaleTimeString("en-IN", { hour: "numeric", minute: "2-digit", timeZone: "Asia/Kolkata" });

const { data: orders, error } = await db
  .from("orders")
  .select("*, tables(name), order_items(*), payments(method, amount_paise)")
  .eq("cafe_id", cafe.id)
  .gte("created_at", start.toISOString())
  .lt("created_at", end.toISOString())
  .order("created_at");
if (error) {
  console.error(error.message);
  process.exit(1);
}

const items = orders.flatMap((o) => o.order_items.map((i) => ({ ...i, table: o.tables?.name })));
const paid = orders.filter((o) => o.status === "paid");
const qty = (list) => list.reduce((n, i) => n + i.qty, 0);
const qrItems = items.filter((i) => i.source === "customer");
const staffItems = items.filter((i) => i.source === "staff");
const voided = items.filter((i) => i.status === "void");
const acceptWait = qrItems.filter((i) => i.accepted_at).map((i) => mins(i.created_at, i.accepted_at));
const cookTime = items.filter((i) => i.ready_at).map((i) => mins(i.accepted_at ?? i.created_at, i.ready_at));
const tableTime = paid.filter((o) => o.closed_at).map((o) => mins(o.created_at, o.closed_at));
const sales = paid.reduce((s, o) => s + ((o.total_paise ?? 0) - (o.gst_paise ?? 0)), 0);
const gross = paid.reduce((s, o) => s + (o.total_paise ?? 0), 0);
const discounts = paid.filter((o) => (o.discount_paise ?? 0) > 0);
const pay = (m) => paid.flatMap((o) => o.payments).filter((p) => p.method === m).reduce((s, p) => s + p.amount_paise, 0);

const byHour = new Map();
for (const o of orders) {
  const h = new Date(new Date(o.created_at).getTime() + IST).getUTCHours();
  byHour.set(h, (byHour.get(h) ?? 0) + 1);
}
const top = new Map();
for (const i of items.filter((i) => i.status !== "void")) top.set(i.name_snapshot, (top.get(i.name_snapshot) ?? 0) + i.qty);

const out = [];
out.push(`# ${cafe.name} · day report · ${day}`, "");
out.push("## Orders");
out.push(`- Tables served: ${orders.length} (paid ${paid.length}, still open ${orders.filter((o) => o.status === "open").length}, cancelled ${orders.filter((o) => o.status === "cancelled").length})`);
out.push(`- Items ordered: ${qty(items)} · by QR ${qty(qrItems)} (${items.length ? Math.round((qty(qrItems) / qty(items)) * 100) : 0}%) · by staff ${qty(staffItems)}`);
out.push(`- Removed / rejected items: ${qty(voided)}${voided.length ? " → " + voided.map((i) => `${i.qty}× ${i.name_snapshot} (${i.table})`).join(", ") : ""}`);
out.push("");
out.push("## Speed (median)");
out.push(`- QR order → staff accepted: ${fmtMin(median(acceptWait))}`);
out.push(`- Sent to kitchen → marked ready: ${fmtMin(median(cookTime))}${cookTime.length ? "" : " (kitchen screen not used to mark ready)"}`);
out.push(`- Table open → paid: ${fmtMin(median(tableTime))}`);
out.push("");
out.push("## Money");
out.push(`- Net sales (before GST): ${rupees(sales)} · with GST: ${rupees(gross)}`);
out.push(`- Average bill: ${paid.length ? rupees(Math.round(gross / paid.length)) : "—"}`);
out.push(`- UPI ${rupees(pay("upi"))} · Cash ${rupees(pay("cash"))}`);
out.push(`- Discounts: ${discounts.length}${discounts.length ? " → " + discounts.map((o) => `${rupees(o.discount_paise)} (${o.discount_reason ?? "no reason"})`).join(", ") : ""}`);
out.push("");
out.push("## Busiest hours");
out.push([...byHour].sort((a, b) => a[0] - b[0]).map(([h, n]) => `${h}:00 ${"█".repeat(n)} ${n}`).join("\n") || "—");
out.push("");
out.push("## Top dishes");
out.push([...top].sort((a, b) => b[1] - a[1]).slice(0, 8).map(([n, q]) => `- ${q}× ${n}`).join("\n") || "—");
out.push("");
out.push("## Timeline");
for (const o of orders) {
  out.push(`- ${ist(o.created_at)} ${o.tables?.name ?? "?"} · ${o.status}${o.closed_at ? ` at ${ist(o.closed_at)}` : ""} · ${rupees(o.total_paise ?? 0)}${o.invoice_no ? ` · ${o.invoice_no}` : ""}`);
}
console.log(out.join("\n"));
