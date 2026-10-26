// Adds another login to a café (e.g. a second counter phone, or a new kitchen tablet).
// One login belongs to one café only.
// Usage: npm run add-login -- --cafe brew-bros --email counter2@brewbros.in [--role staff|kitchen]
import { randomBytes } from "node:crypto";
import { arg, cafeFromArgs, db, must } from "./lib/db.mjs";

const cafe = await cafeFromArgs();
const email = arg("--email")?.toLowerCase();
const role = arg("--role", "staff");
if (!email || !["staff", "kitchen"].includes(role)) {
  console.log("Usage: npm run add-login -- --cafe <slug> --email someone@cafe.in [--role staff|kitchen]");
  process.exit(1);
}
const pw = randomBytes(9).toString("base64url");
const { data, error } = await db.auth.admin.createUser({ email, password: pw, email_confirm: true });
if (error) {
  console.error(/already/i.test(error.message) ? `${email} already has a login (one login = one café).` : error.message);
  process.exit(1);
}
await must(db.from("staff").insert({ user_id: data.user.id, role, display_name: email.split("@")[0], cafe_id: cafe.id }));
console.log(`${cafe.name}: ${email} (${role})  password: ${pw}`);
