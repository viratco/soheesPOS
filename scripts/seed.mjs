// Seeds a demo menu, tables, and the staff/kitchen logins from backend/.env into ONE café
// (Sohee's unless --cafe says otherwise). Safe to re-run: skips what already exists.
// New cafés are made with `npm run new-cafe` instead.
// Usage: npm run seed [-- --cafe <slug>]
import { cafeFromArgs, db, must } from "./lib/db.mjs";

const cafe = await cafeFromArgs("sohees");
const mine = (q) => q.eq("cafe_id", cafe.id);

const MENU = [
  {
    name: "Coffee & Chai",
    items: [
      ["Masala Chai", "Kadak chai brewed with ginger, cardamom and fresh milk", 6000],
      ["Filter Coffee", "South Indian decoction, frothy, served in a dabarah", 8000],
      ["Cappuccino", "Double shot espresso with steamed milk foam", 16000],
      ["Iced Americano", "Espresso over ice and cold water", 15000],
      ["Cold Coffee", "Blended with vanilla ice cream", 18000],
      ["Fresh Lime Soda", "Sweet, salted or mixed", 9000],
    ],
  },
  {
    name: "All-Day Breakfast",
    items: [
      ["Masala Omelette Toast", "Three-egg omelette with onion, chilli, coriander, on sourdough", 19000],
      ["Poha", "Flattened rice with peanuts, curry leaves, sev and lime", 12000],
      ["Avocado Toast", "Smashed avocado, chilli flakes, feta, sourdough", 32000],
      ["Banana Pancakes", "Stack of three with maple syrup and butter", 24000],
      ["Akuri on Toast", "Parsi-style spiced scrambled eggs", 21000],
    ],
  },
  {
    name: "Bowls & Sandwiches",
    items: [
      ["Paneer Tikka Sandwich", "Grilled paneer, mint mayo, pickled onion", 22000],
      ["Chicken Tikka Wrap", "Tandoori chicken, salad, garlic sauce", 26000],
      ["Rajma Chawal Bowl", "Home-style rajma, jeera rice, salad", 23000],
      ["Kimchi Fried Rice", "With fried egg and spring onion", 27000],
    ],
  },
];

const TABLES = ["Table 1", "Table 2", "Table 3", "Table 4", "Table 5", "Table 6", "Window 1", "Window 2"];

async function seedMenu() {
  const { count } = await mine(db.from("menu_categories").select("*", { count: "exact", head: true }));
  if (count) return console.log(`menu: ${count} categories already exist, skipping`);
  for (const [ci, cat] of MENU.entries()) {
    const [row] = await must(db.from("menu_categories").insert({ cafe_id: cafe.id, name: cat.name, sort_order: (ci + 1) * 10 }).select());
    await must(
      db.from("menu_items").insert(
        cat.items.map(([name, description, price_paise], i) => ({
          category_id: row.id,
          name,
          description,
          price_paise,
          sort_order: (i + 1) * 10,
        })),
      ),
    );
  }
  console.log(`menu: added ${MENU.length} categories, ${MENU.flatMap((c) => c.items).length} items`);
}

async function seedTables() {
  const { count } = await mine(db.from("tables").select("*", { count: "exact", head: true }));
  if (count) return console.log(`tables: ${count} already exist, skipping`);
  await must(db.from("tables").insert(TABLES.map((name, i) => ({ cafe_id: cafe.id, name, sort_order: (i + 1) * 10 }))));
  console.log(`tables: added ${TABLES.length}`);
}

async function ensureUser(email, password, role) {
  if (!email || !password) return console.log(`users: no ${role} credentials in backend/.env, skipping`);
  let userId;
  const { data, error } = await db.auth.admin.createUser({ email, password, email_confirm: true });
  if (data?.user) userId = data.user.id;
  else if (error && /already/i.test(error.message)) {
    const { data: list } = await db.auth.admin.listUsers({ perPage: 1000 });
    userId = list.users.find((u) => u.email === email)?.id;
  } else throw new Error(error?.message);
  await must(db.from("staff").upsert({ user_id: userId, role, display_name: email.split("@")[0], cafe_id: cafe.id }));
  console.log(`users: ${email} → ${role}`);
}

// Discovery details for the demo menu (needs migration 20261020010000_menu_discovery.sql).
// Keyed by item name; safe to re-run.
const DISCOVERY = {
  "Masala Chai": { moods: ["drink"], is_bestseller: true, badge: "#1 ordered" },
  "Filter Coffee": { moods: ["drink"] },
  "Cappuccino": { moods: ["drink"] },
  "Iced Americano": { moods: ["drink"] },
  "Cold Coffee": { moods: ["drink"], is_bestseller: true, badge: "Crowd favourite" },
  "Fresh Lime Soda": { moods: ["drink"] },
  "Masala Omelette Toast": { diet: "egg", spice_level: 1, moods: ["meal"] },
  "Poha": { spice_level: 1, moods: ["meal", "share"] },
  "Avocado Toast": { moods: ["meal"], badge: "New" },
  "Banana Pancakes": { diet: "egg", moods: ["meal", "share"] },
  "Akuri on Toast": { diet: "egg", spice_level: 2, moods: ["meal"] },
  "Paneer Tikka Sandwich": { spice_level: 2, moods: ["meal"], is_bestseller: true, badge: "Try this first" },
  "Chicken Tikka Wrap": { diet: "nonveg", spice_level: 2, moods: ["meal", "share"], is_bestseller: true },
  "Rajma Chawal Bowl": { spice_level: 1, moods: ["meal"] },
  "Kimchi Fried Rice": { diet: "egg", spice_level: 3, moods: ["meal"] },
};
const COMBOS = [
  { name: "Chai + Poha", description: "Masala Chai with a plate of Poha. Save ₹20.", price_paise: 16000, diet: "veg", spice_level: 1 },
  { name: "Wrap + Cold Coffee", description: "Chicken Tikka Wrap with a Cold Coffee. Save ₹40.", price_paise: 40000, diet: "nonveg", spice_level: 2 },
];

async function seedDiscovery() {
  const { error } = await db.from("menu_items").select("diet").limit(1);
  if (error) return console.log("discovery: run migration 20261020010000_menu_discovery.sql first, skipping");
  for (const [name, fields] of Object.entries(DISCOVERY)) {
    await must(mine(db.from("menu_items").update(fields).eq("name", name)));
  }
  let { data: cat } = await mine(db.from("menu_categories").select("id").eq("name", "Combos")).maybeSingle();
  if (!cat) [cat] = await must(db.from("menu_categories").insert({ cafe_id: cafe.id, name: "Combos", sort_order: 5 }).select());
  for (const [i, c] of COMBOS.entries()) {
    const { data: exists } = await mine(db.from("menu_items").select("id").eq("name", c.name)).maybeSingle();
    if (!exists) {
      await must(db.from("menu_items").insert({ ...c, category_id: cat.id, is_combo: true, moods: ["meal"], sort_order: (i + 1) * 10 }));
    }
  }
  console.log(`discovery: tagged ${Object.keys(DISCOVERY).length} items, ${COMBOS.length} combos ready`);
}

await seedMenu();
await seedTables();
await seedDiscovery();
const staff = (process.env.STAFF_LOGINS ?? "").split(",").map((s) => s.trim()).filter(Boolean);
for (const pair of staff) {
  const [email, password] = pair.split(":");
  await ensureUser(email, password, "staff");
}
await ensureUser(process.env.KITCHEN_EMAIL, process.env.KITCHEN_PASSWORD, "kitchen");
console.log("done");
