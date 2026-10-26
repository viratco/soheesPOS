// Shared by the scripts: an admin database client, and "which café is this for?".
// The secret key bypasses every security rule, so each script must scope itself to ONE café.
import { createClient } from "@supabase/supabase-js";
import ws from "ws"; // Node 20 has no built-in WebSocket

const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const secret = process.env.SUPABASE_SECRET_KEY;
if (!url || !secret) {
  console.error("Missing NEXT_PUBLIC_SUPABASE_URL or SUPABASE_SECRET_KEY in backend/.env");
  process.exit(1);
}
export const db = createClient(url, secret, { auth: { persistSession: false }, realtime: { transport: ws } });

export async function must(promise) {
  const { data, error } = await promise;
  if (error) throw new Error(error.message);
  return data;
}

/** Value after a flag, e.g. arg("--cafe") for `--cafe brew-bros`. */
export function arg(name, fallback) {
  const i = process.argv.indexOf(name);
  return i > -1 && process.argv[i + 1] && !process.argv[i + 1].startsWith("--") ? process.argv[i + 1] : fallback;
}

/** The café named by --cafe <slug> (or `fallback`). Exits if there's no such café. */
export async function cafeFromArgs(fallback) {
  const slug = arg("--cafe", fallback);
  if (!slug) {
    console.error("Say which café:  --cafe <slug>   (e.g. --cafe sohees)");
    process.exit(1);
  }
  const { data, error } = await db.from("cafes").select("*").eq("slug", slug).maybeSingle();
  if (error) {
    console.error(/cafes/.test(error.message) ? "Run RUN_THIS_cafes.sql in Supabase first." : error.message);
    process.exit(1);
  }
  if (!data) {
    console.error(`No café with slug "${slug}".`);
    process.exit(1);
  }
  return data;
}
