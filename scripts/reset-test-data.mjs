// Deletes ONE café's orders, order items and payments, and restarts its invoice numbers at 00001.
// Its menu, tables and logins are kept. Other cafés are never touched.
// Usage: npm run reset-test-data -- --cafe sohees --yes
import { cafeFromArgs, db } from "./lib/db.mjs";

const cafe = await cafeFromArgs();
if (!process.argv.includes("--yes")) {
  console.log(`This deletes every order, item and payment of ${cafe.name} and resets its invoice numbers.`);
  console.log(`Run again with --yes to confirm:  npm run reset-test-data -- --cafe ${cafe.slug} --yes`);
  process.exit(0);
}

async function wipe(table) {
  const { error, count } = await db.from(table).delete({ count: "exact" }).eq("cafe_id", cafe.id);
  if (error) throw new Error(`${table}: ${error.message}`);
  console.log(`deleted ${count ?? 0} from ${table}`);
}

await wipe("payments");
await wipe("order_items");
await wipe("orders");
const { error } = await db.from("invoice_counters").delete().eq("cafe_id", cafe.id);
if (error) throw new Error(`invoice_counters: ${error.message}`);
console.log(`invoice numbers reset: the next paid bill is ${cafe.invoice_prefix}/<year>/00001`);
