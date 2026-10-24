// Deletes ALL orders, order items and payments, and restarts invoice numbers at 00001.
// Menu, tables and staff logins are kept. Use once before going live.
// Usage: npm run reset-test-data -- --yes
import { createClient } from "@supabase/supabase-js";
import ws from "ws";

if (!process.argv.includes("--yes")) {
  console.log("This deletes every order, item and payment and resets invoice numbers.");
  console.log("Run again with --yes to confirm:  npm run reset-test-data -- --yes");
  process.exit(0);
}

const db = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL, process.env.SUPABASE_SECRET_KEY, {
  auth: { persistSession: false },
  realtime: { transport: ws },
});

async function wipe(table) {
  const { error, count } = await db.from(table).delete({ count: "exact" }).not("id", "is", null);
  if (error) throw new Error(`${table}: ${error.message}`);
  console.log(`deleted ${count ?? 0} from ${table}`);
}

await wipe("payments");
await wipe("order_items");
await wipe("orders");
const { error } = await db.from("invoice_counters").delete().not("fy", "is", null);
if (error) throw new Error(`invoice_counters: ${error.message}`);
console.log("invoice numbers reset: the next paid bill is SK/<year>/00001");
