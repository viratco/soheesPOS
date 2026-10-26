// Onboards a new café: its own account, tables and logins. Its data is walled off from
// every other café (see migration 20261026000000_cafes.sql).
//
// Usage:
//   npm run new-cafe -- --name "Brew Bros" --slug brew-bros --owner owner@brewbros.in
//     [--tables 10] [--prefix BB] [--gst 5] [--phone "98xxxxxx"] [--address "..."] [--gstin ...]
//
// Prints the owner and kitchen logins once. Passwords are random; write them down.
import { randomBytes } from "node:crypto";
import { arg, db, must } from "./lib/db.mjs";

const name = arg("--name");
const slug = arg("--slug");
const owner = arg("--owner")?.toLowerCase();
if (!name || !slug || !owner) {
  console.log('Usage: npm run new-cafe -- --name "Brew Bros" --slug brew-bros --owner owner@brewbros.in [--tables 10] [--prefix BB] [--gst 5]');
  process.exit(1);
}
if (!/^[a-z0-9][a-z0-9-]{1,39}$/.test(slug)) {
  console.error("--slug: lowercase letters, numbers and dashes only (e.g. brew-bros)");
  process.exit(1);
}
const tableCount = Number(arg("--tables", "10"));
const prefix = (arg("--prefix") ?? name.replace(/[^A-Za-z0-9 ]/g, "").split(/\s+/).map((w) => w[0]).join("")).toUpperCase().slice(0, 6) || "INV";
const gstBps = Math.round(Number(arg("--gst", "5")) * 100);
// The kitchen tablet gets its own login. "+kitchen" lands in the owner's own inbox (Gmail etc.).
const [local, domain] = owner.split("@");
const kitchenEmail = arg("--kitchen-email", `${local}+kitchen@${domain}`).toLowerCase();

const { data: taken } = await db.from("cafes").select("id").eq("slug", slug).maybeSingle();
if (taken) {
  console.error(`A café with slug "${slug}" already exists.`);
  process.exit(1);
}

const password = () => randomBytes(9).toString("base64url"); // 12 characters

async function createLogin(email, role, cafeId) {
  const pw = password();
  const { data, error } = await db.auth.admin.createUser({ email, password: pw, email_confirm: true });
  if (error) throw new Error(`${email}: ${error.message}`);
  await must(db.from("staff").insert({ user_id: data.user.id, role, display_name: role === "kitchen" ? "kitchen" : local, cafe_id: cafeId }));
  return pw;
}

const [cafe] = await must(
  db.from("cafes").insert({
    slug,
    name,
    invoice_prefix: prefix,
    gst_rate_bps: gstBps,
    phone: arg("--phone") ?? null,
    address: arg("--address") ?? null,
    gstin: arg("--gstin")?.toUpperCase() ?? null,
    legal_name: arg("--legal-name") ?? null,
  }).select(),
);

let ownerPw, kitchenPw;
try {
  ownerPw = await createLogin(owner, "staff", cafe.id);
  kitchenPw = await createLogin(kitchenEmail, "kitchen", cafe.id);
} catch (e) {
  // Don't leave a half-made café behind.
  const { data: rows } = await db.from("staff").select("user_id").eq("cafe_id", cafe.id);
  for (const r of rows ?? []) await db.auth.admin.deleteUser(r.user_id);
  await db.from("cafes").delete().eq("id", cafe.id);
  console.error(`Stopped, nothing was created: ${e.message}`);
  process.exit(1);
}

await must(
  db.from("tables").insert(
    Array.from({ length: tableCount }, (_, i) => ({ name: `Table ${i + 1}`, sort_order: (i + 1) * 10, cafe_id: cafe.id })),
  ),
);

const site = process.env.SITE_URL ?? "https://pos-frontend-nmvx.vercel.app";
console.log(`
✅ ${name} is ready  (slug: ${slug}, invoices ${prefix}/<year>/00001, GST ${gstBps / 100}%)

Owner / counter login   ${owner}
                        password: ${ownerPw}
Kitchen tablet login    ${kitchenEmail}
                        password: ${kitchenPw}

Next:
 1. Sign in at ${site}/login as the owner.
 2. Settings → fill in legal name, address, GSTIN, FSSAI (printed on bills).
 3. Menu → add categories and dishes.
 4. QR codes → print ${tableCount} table cards.
 5. On the kitchen tablet, sign in with the kitchen login (it opens the kitchen screen).
`);
