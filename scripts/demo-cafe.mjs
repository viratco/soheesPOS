// Demo café for sales visits: "Brew & Bloom Café" (slug "demo"), a separate account with its own
// logins, 13 tables, a floor plan, a photo menu, ~30 days of paid bills, supplier purchases, and a
// few tables busy right now. Sohee's Kitchen (or any other café) is never touched.
//
// Usage:  npm run demo              → create it the first time, or refresh it (new history up to now,
//                                     fresh busy tables) — run this before each sales visit
//         npm run demo -- --menu    → also reload the demo menu
//
// Logins are written once, to print/demo-cafe-logins.txt (git-ignored).
// Dish photos are free Unsplash photos (unsplash.com/license), loaded straight from Unsplash.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { randomBytes, randomUUID } from "node:crypto";
import { arg, db, must } from "./lib/db.mjs";

const SLUG = "demo";
const PLAN = JSON.parse(readFileSync(new URL("./demo/floor-plan.json", import.meta.url), "utf8"));
const TABLES = PLAN.spots.map((s) => s.n);
const LOGINS_FILE = new URL("../../print/demo-cafe-logins.txt", import.meta.url);

const img = (id) => `https://images.unsplash.com/photo-${id}?w=640&q=70&auto=format&fit=crop`;
const v = "veg", e = "egg", n = "nonveg";
// Option group: name, min picks, max picks, [choice, extra ₹]
const O = (name, min, max, choices) => ({ name, min, max, choices: choices.map(([c, rs = 0]) => ({ name: c, price: rs * 100 })) });

// [name, ₹, diet, description, photo, { best, spicy, options, pop }]   pop = how often it's ordered
const MENU = [
  {
    name: "Coffee",
    poster: "1495774856032-8b90bbb32b32",
    items: [
      ["Espresso", 140, v, "A short, intense double shot from our house blend", "1572286258217-40142c1c6a70", { pop: 1 }],
      ["Cappuccino", 190, v, "Double espresso with velvety steamed milk and thick foam", "1514432324607-a09d9b4aefdd", { best: true, pop: 4 }],
      ["Café Latte", 210, v, "Smooth espresso with lots of silky milk", "1511920170033-f8396924c348",
        { pop: 3, options: [O("Milk", 1, 1, [["Regular"], ["Oat milk", 60]])] }],
      ["Iced Americano", 190, v, "Espresso over ice and cold water, clean and bold", "1517701550927-30cf4ba1dba5", { pop: 2 }],
      ["Iced Latte", 230, v, "Espresso, cold milk and ice", "1461023058943-07fcbe16d735", { pop: 3 }],
      ["Cold Brew", 240, v, "Steeped 16 hours for a smooth, chocolatey cold coffee", "1759259639356-6eee63241869", { pop: 2 }],
      ["Hazelnut Frappe", 260, v, "Blended iced coffee with hazelnut and whipped cream", "1718267050202-9b1b6bfb8545", { best: true, pop: 4 }],
    ],
  },
  {
    name: "Chai & Coolers",
    poster: "1556679343-c7306c1976bc",
    items: [
      ["Kulhad Masala Chai", 120, v, "Kadak chai with ginger and cardamom, served in a clay kulhad", "1761483281417-778013dc0177", { pop: 3 }],
      ["Iced Peach Tea", 180, v, "Black tea shaken with peach and lemon", "1556679343-c7306c1976bc", { pop: 2 }],
      ["Virgin Mojito", 170, v, "Fresh lime, mint and soda, crushed ice", "1546171753-97d7676e4602", { pop: 2 }],
    ],
  },
  {
    name: "All-Day Breakfast",
    poster: "1528699633788-424224dc89b5",
    items: [
      ["Smashed Avocado Toast", 320, v, "Sourdough, smashed avocado, cherry tomatoes, chilli flakes", "1783307525039-b92506474dc8", { pop: 2 }],
      ["Masala Omelette", 220, e, "Three-egg omelette with onion, chilli and coriander, toast on the side", "1510693206972-df098062cb71", { pop: 2, spicy: true }],
      ["Pancake Stack", 280, e, "Three fluffy pancakes with butter and maple syrup", "1528207776546-365bb710ee93",
        { pop: 2, options: [O("Toppings", 0, 2, [["Nutella", 60], ["Fresh berries", 80], ["Banana", 40]])] }],
      ["Sunny Breakfast Plate", 380, e, "Two sunny-side eggs, toast, sautéed mushrooms, hash brown and beans", "1529411081224-84ac0d0bf6ab", { pop: 1 }],
    ],
  },
  {
    name: "Sandwiches & Burgers",
    poster: "1568901346375-23c9450c58cd",
    items: [
      ["Corn & Cheese Grilled Sandwich", 240, v, "Sweet corn, cheddar and herbs, grilled golden", "1528735602780-2552fd46c7af", { pop: 3 }],
      ["Chicken Club Sandwich", 320, n, "Triple-decker with grilled chicken, egg, lettuce and mayo", "1553909489-cd47e0907980", { pop: 2 }],
      ["Classic Veg Burger", 240, v, "Crispy veg patty, lettuce, tomato and house sauce",  "1586190848861-99aa4a171e90",
        { pop: 2, options: [O("Make it better", 0, 2, [["Add cheese", 30], ["Fries + drink", 120]])] }],
      ["Crispy Chicken Burger", 290, n, "Buttermilk fried chicken, slaw and spicy mayo", "1606755962773-d324e0a13086",
        { best: true, pop: 4, spicy: true, options: [O("Make it better", 0, 2, [["Add cheese", 30], ["Fries + drink", 120]])] }],
      ["Peri Peri Fries", 180, v, "Crispy fries tossed in peri peri spice", "1630384060421-cb20d0e0649d", { pop: 4, spicy: true }],
    ],
  },
  {
    name: "Pasta & Bowls",
    poster: "1546549032-9571cd6b27df",
    items: [
      ["Penne Arrabbiata", 320, v, "Spicy tomato and garlic sauce, basil, parmesan", "1598866594230-a7c12756260f", { pop: 2, spicy: true }],
      ["Creamy Alfredo Pasta", 340, v, "Penne in a rich parmesan cream sauce", "1781332147533-aefdfe14dc2c",
        { best: true, pop: 3, options: [O("Choice", 1, 1, [["Veg"], ["Chicken", 80]])] }],
      ["Basil Pesto Pasta", 360, v, "Fresh basil pesto, cherry tomatoes and pine nuts", "1766706519060-d44bd9dc50f7", { pop: 1 }],
      ["Teriyaki Chicken Rice Bowl", 380, n, "Glazed chicken, sticky rice, sesame greens", "1679279726946-a158b8bcaa23", { pop: 2 }],
    ],
  },
  {
    name: "Wood-fired Pizza",
    poster: "1565299624946-b28f40a0ae38",
    items: [
      ["Margherita", 349, v, "San Marzano tomato, fresh mozzarella, basil", "1513104890138-7c749659a591",
        { pop: 3, options: [O("Size", 1, 1, [["Regular 9\""], ["Large 12\"", 150]])] }],
      ["Farmhouse Veggie", 399, v, "Peppers, onion, sweet corn, olives and jalapeños", "1788600018968-f759dbe30c9a",
        { pop: 2, options: [O("Size", 1, 1, [["Regular 9\""], ["Large 12\"", 150]])] }],
      ["Chicken Pepperoni", 449, n, "Chicken pepperoni and mozzarella", "1534308983496-4fabb1a015ee",
        { pop: 2, options: [O("Size", 1, 1, [["Regular 9\""], ["Large 12\"", 150]])] }],
    ],
  },
  {
    name: "Desserts",
    poster: "1567171466295-4afa63d45416",
    items: [
      ["Brownie with Ice Cream", 220, e, "Warm fudgy brownie, vanilla ice cream, chocolate sauce", "1606884285898-277317a7bf12", { best: true, pop: 3 }],
      ["Tiramisu", 280, e, "Espresso-soaked sponge and mascarpone cream", "1571877227200-a0d98ea607e9", { pop: 1 }],
      ["Blueberry Cheesecake", 300, e, "Baked New York cheesecake with blueberry compote", "1533134242443-d4fd215305ad", { pop: 2 }],
    ],
  },
];

// Supplier bills: [supplier, every N days, items: [name, unit, min qty, max qty, ₹ per unit], usually paid by]
const SUPPLIERS = [
  ["Fresh Dairy Co.", 1, [["Full cream milk", "l", 14, 22, 66], ["Paneer", "kg", 0, 1, 380]], "upi"],
  ["Green Basket Vegetables", 2, [["Vegetables", "kg", 8, 14, 55], ["Lettuce", "kg", 1, 2, 160]], "cash"],
  ["Royal Poultry", 2, [["Boneless chicken", "kg", 4, 7, 260]], "credit"],
  ["City Bakery", 1, [["Burger buns", "pcs", 20, 36, 12], ["Sourdough loaf", "pcs", 2, 4, 140]], "cash"],
  ["Bean Brothers Roasters", 7, [["Coffee beans", "kg", 2, 3, 1450]], "bank"],
  ["Metro Cash & Carry", 6, [["Mozzarella", "kg", 3, 5, 520], ["Penne pasta", "kg", 3, 5, 190], ["Sauces & syrups", "bottle", 4, 8, 280]], "bank"],
];

/* ───────────────────────── helpers ───────────────────────── */

const rnd = (a, b) => a + Math.random() * (b - a);
const int = (a, b) => Math.floor(rnd(a, b + 1));
const chance = (p) => Math.random() < p;
const pickWeighted = (list, w) => {
  let r = Math.random() * list.reduce((s, x) => s + w(x), 0);
  for (const x of list) if ((r -= w(x)) <= 0) return x;
  return list.at(-1);
};
const IST = 5.5 * 3600_000;
const DAY = 86_400_000;
const istMidnight = (ms) => Math.floor((ms + IST) / DAY) * DAY - IST;
const istDate = (ms) => new Date(ms + IST).toISOString().slice(0, 10);
const fy = (ms) => {
  const d = new Date(ms + IST);
  const y = d.getUTCMonth() >= 3 ? d.getUTCFullYear() : d.getUTCFullYear() - 1;
  return `${y}-${String((y + 1) % 100).padStart(2, "0")}`;
};
async function inChunks(table, rows, size = 400) {
  for (let i = 0; i < rows.length; i += size) await must(db.from(table).insert(rows.slice(i, i + size)));
}

/* ───────────────────────── 1. the café and its logins ───────────────────────── */

let { data: cafe } = await db.from("cafes").select("*").eq("slug", SLUG).maybeSingle();
if (!cafe) {
  [cafe] = await must(
    db.from("cafes").insert({
      slug: SLUG,
      name: "Brew & Bloom Café",
      legal_name: "Brew & Bloom Hospitality (Demo)",
      address: "Demo café · Greater Noida, Uttar Pradesh",
      gstin: "09ABCDE1234F1Z5", // the standard sample GSTIN, not a real business
      fssai: "10000000000000",
      bill_footer: "Thank you! This is a demo bill.",
      invoice_prefix: "BB",
    }).select(),
  );
  console.log(`Created café: ${cafe.name}`);
}

const { count: loginCount } = await db.from("staff").select("*", { count: "exact", head: true }).eq("cafe_id", cafe.id);
if (!loginCount) {
  const owner = arg("--owner", "demo.owner@example.com");
  const kitchen = arg("--kitchen", "demo.kitchen@example.com");
  const lines = [`Demo café logins (${cafe.name}) — created ${new Date().toISOString().slice(0, 10)}`, ""];
  for (const [email, role] of [[owner, "staff"], [kitchen, "kitchen"]]) {
    const password = randomBytes(9).toString("base64url");
    const { data, error } = await db.auth.admin.createUser({ email, password, email_confirm: true });
    if (error) throw new Error(`${email}: ${error.message}`);
    await must(db.from("staff").insert({ user_id: data.user.id, role, display_name: role === "kitchen" ? "kitchen" : "demo", cafe_id: cafe.id }));
    lines.push(`${role === "staff" ? "Owner / counter" : "Kitchen tablet"}: ${email}`, `  password: ${password}`, "");
  }
  mkdirSync(new URL(".", LOGINS_FILE), { recursive: true });
  writeFileSync(LOGINS_FILE, lines.join("\n"));
  console.log(`Logins created → print/demo-cafe-logins.txt`);
}

/* ───────────────────────── 2. tables + floor plan ───────────────────────── */

await must(
  db.from("tables").upsert(
    TABLES.map((t) => ({ cafe_id: cafe.id, name: `Table ${t}`, is_active: true, sort_order: t * 10 })),
    { onConflict: "cafe_id,name" },
  ),
);
const tables = await must(db.from("tables").select("id, name").eq("cafe_id", cafe.id));
const tableId = new Map(tables.map((t) => [Number(t.name.replace(/\D/g, "")), t.id]));

const { error: planError } = await db.from("cafes").update({ floor_plan: PLAN }).eq("id", cafe.id);
if (planError) console.log("Floor plan not saved yet — run RUN_THIS_floor_plan.sql in Supabase, then `npm run demo` again.");

/* ───────────────────────── 3. menu ───────────────────────── */

const { count: dishCount } = await db.from("menu_items").select("*", { count: "exact", head: true }).eq("cafe_id", cafe.id);
if (!dishCount || process.argv.includes("--menu")) {
  // Old demo bills keep their own dish names and prices, so the menu can be replaced safely.
  await must(db.from("menu_items").delete().eq("cafe_id", cafe.id));
  await must(db.from("menu_categories").delete().eq("cafe_id", cafe.id));
  for (const [ci, cat] of MENU.entries()) {
    const [row] = await must(db.from("menu_categories").insert({ cafe_id: cafe.id, name: cat.name, sort_order: (ci + 1) * 10, image_url: img(cat.poster) }).select());
    await must(
      db.from("menu_items").insert(
        cat.items.map(([name, rs, diet, description, photo, o = {}], i) => ({
          category_id: row.id,
          name,
          description,
          price_paise: rs * 100,
          diet,
          image_url: img(photo),
          is_bestseller: !!o.best,
          spice_level: o.spicy ? 2 : 0,
          options: o.options ?? [],
          moods: cat.name === "Coffee" || cat.name === "Chai & Coolers" ? ["drink"] : ["meal"],
          sort_order: (i + 1) * 10,
        })),
      ),
    );
  }
  console.log(`Menu loaded: ${MENU.flatMap((c) => c.items).length} dishes`);
}
const dishes = await must(db.from("menu_items").select("id, name, price_paise, options").eq("cafe_id", cafe.id));
const pop = new Map(MENU.flatMap((c) => c.items).map(([name, , , , , o = {}]) => [name, o.pop ?? 1]));

/* ───────────────────────── 4. wipe old demo orders and purchases ───────────────────────── */

for (const t of ["payments", "order_items", "order_guests", "orders", "invoice_counters", "purchases"]) {
  await must(db.from(t).delete().eq("cafe_id", cafe.id));
}

/* ───────────────────────── 5. ~30 days of paid bills ───────────────────────── */

// A random dish line, with random options where the dish has them.
function line(orderId, status, at, source = chance(0.7) ? "customer" : "staff") {
  const d = pickWeighted(dishes, (x) => pop.get(x.name) ?? 1);
  const picks = [];
  let extra = 0;
  for (const g of d.options ?? []) {
    const k = Math.min(g.max, Math.max(g.min, chance(0.5) ? 1 : 0));
    for (const c of [...g.choices].sort(() => Math.random() - 0.5).slice(0, k)) {
      picks.push({ group: g.name, name: c.name, price: c.price });
      extra += c.price;
    }
  }
  const accepted = source === "customer" ? at + int(1, 4) * 60_000 : at;
  return {
    id: randomUUID(),
    order_id: orderId,
    menu_item_id: d.id,
    name_snapshot: d.name,
    price_paise_snapshot: d.price_paise + extra,
    qty: chance(0.15) ? 2 : 1,
    status,
    source,
    options: picks.length ? picks : null,
    created_at: new Date(at).toISOString(),
    accepted_at: status === "new" ? null : new Date(accepted).toISOString(),
    ready_at: status === "ready" || status === "served" ? new Date(accepted + int(8, 18) * 60_000).toISOString() : null,
  };
}

const HOUR_WEIGHT = { 9: 1, 10: 2, 11: 3, 12: 6, 13: 8, 14: 6, 15: 3, 16: 3, 17: 4, 18: 6, 19: 8, 20: 9, 21: 7, 22: 3 };
const now = Date.now();
const today = istMidnight(now);
const bills = [];
for (let d = 30; d >= 0; d--) {
  const day = today - d * DAY;
  const weekday = new Date(day + IST).getUTCDay();
  const busy = weekday === 0 || weekday === 6 ? 1.5 : weekday === 5 ? 1.2 : 1;
  const count = Math.round(22 * busy * rnd(0.75, 1.25));
  for (let i = 0; i < count; i++) {
    const hour = Number(pickWeighted(Object.keys(HOUR_WEIGHT), (h) => HOUR_WEIGHT[h]));
    const created = day + hour * 3600_000 + int(0, 59) * 60_000;
    const closed = created + int(30, 75) * 60_000;
    if (closed > now - 10 * 60_000) continue; // later today hasn't happened yet
    bills.push({ created, closed, table: TABLES[int(0, TABLES.length - 1)] });
  }
}
bills.sort((a, b) => a.closed - b.closed);

const orders = [], items = [], payments = [], counters = new Map();
for (const b of bills) {
  const id = randomUUID();
  const lines = Array.from({ length: pickWeighted([1, 2, 3, 4, 5], (k) => [2, 5, 5, 3, 1][k - 1]) }, () => line(id, "served", b.created));
  if (chance(0.04)) lines.push({ ...line(id, "void", b.created), accepted_at: null, ready_at: null }); // a rejected extra
  items.push(...lines);
  const subtotal = lines.filter((l) => l.status === "served").reduce((s, l) => s + l.price_paise_snapshot * l.qty, 0);
  const discount = chance(0.08) ? Math.floor((subtotal * 1000 + 5000) / 10000) : 0;
  const gst = Math.floor(((subtotal - discount) * 500 + 5000) / 10000);
  const year = fy(b.closed);
  const no = (counters.get(year) ?? 0) + 1;
  counters.set(year, no);
  orders.push({
    id,
    table_id: tableId.get(b.table),
    status: "paid",
    created_at: new Date(b.created).toISOString(),
    closed_at: new Date(b.closed).toISOString(),
    subtotal_paise: subtotal,
    discount_paise: discount,
    discount_reason: discount ? pickWeighted(["Regular guest", "Birthday", "Student"], () => 1) : null,
    gst_rate_bps: 500,
    gst_paise: gst,
    total_paise: subtotal - discount + gst,
    invoice_no: `${cafe.invoice_prefix}/${year}/${String(no).padStart(5, "0")}`,
  });
  payments.push({ order_id: id, method: chance(0.68) ? "upi" : "cash", amount_paise: subtotal - discount + gst, received_at: new Date(b.closed).toISOString() });
}

/* ───────────────────────── 6. tables busy right now ───────────────────────── */

const LIVE = [
  // table, state, minutes since they sat down, dishes
  [3, "new", 3, 2],
  [6, "pending", 11, 3],
  [1, "ready", 19, 2],
  [10, "served", 38, 4],
  [12, "pending", 7, 3],
];
for (const [t, state, mins, k] of LIVE) {
  const id = randomUUID();
  const at = now - mins * 60_000;
  // Same columns as the paid bills (one batch insert needs every row to have them all).
  orders.push({
    id, table_id: tableId.get(t), status: "open", created_at: new Date(at).toISOString(), closed_at: null,
    subtotal_paise: null, discount_paise: 0, discount_reason: null, gst_rate_bps: null, gst_paise: null, total_paise: null, invoice_no: null,
  });
  for (let i = 0; i < k; i++) items.push(line(id, state, at, state === "new" ? "customer" : undefined));
}

await inChunks("orders", orders);
await inChunks("order_items", items);
await inChunks("payments", payments);
for (const [year, last] of counters) await must(db.from("invoice_counters").insert({ cafe_id: cafe.id, fy: year, last }));

/* ───────────────────────── 7. supplier purchases ───────────────────────── */

// Scales supplier bills so stock lands near 30% of sales, typical for a café.
const STOCK_SCALE = 1.35;

const purchases = [], purchaseItems = [];
for (let d = 30; d >= 0; d--) {
  for (const [supplier, every, list, pay] of SUPPLIERS) {
    if (d % every !== 0) continue;
    const id = randomUUID();
    const lines = list
      .map(([name, unit, min, max, rate]) => {
        const qty = int(min, max);
        return qty > 0 ? { id: randomUUID(), purchase_id: id, cafe_id: cafe.id, name, qty, unit, amount_paise: Math.round(qty * rate * STOCK_SCALE * rnd(0.95, 1.05)) * 100 } : null;
      })
      .filter(Boolean);
    if (!lines.length) continue;
    purchaseItems.push(...lines);
    purchases.push({
      id,
      cafe_id: cafe.id,
      supplier,
      purchased_on: istDate(today - d * DAY),
      // Old pay-later bills have been settled; the last few days' are still owed.
      payment: pay === "credit" && d > 4 ? "bank" : pay,
      bill_no: `${supplier.split(" ")[0].toUpperCase().slice(0, 4)}-${int(1000, 9999)}`,
      total_paise: lines.reduce((s, l) => s + l.amount_paise, 0),
    });
  }
}
const { error: noPurchases } = await db.from("purchases").select("id").limit(1);
if (noPurchases) console.log("Purchases not set up in this database, skipping them.");
else {
  await inChunks("purchases", purchases);
  await inChunks("purchase_items", purchaseItems);
}

/* ───────────────────────── done ───────────────────────── */

const rupees = (p) => "₹" + Math.round(p / 100).toLocaleString("en-IN");
const net = orders.filter((o) => o.status === "paid").reduce((s, o) => s + o.total_paise - o.gst_paise, 0);
const spend = purchases.reduce((s, p) => s + p.total_paise, 0);
console.log(`
${cafe.name} is ready for a demo
  ${payments.length} paid bills over 31 days · net sales ${rupees(net)}
  ${purchases.length} supplier bills · stock ${rupees(spend)} (${Math.round((spend / net) * 100)}% of sales)
  Busy right now: ${LIVE.map(([t, s]) => `Table ${t} (${s === "new" ? "new order" : s === "pending" ? "in kitchen" : s === "ready" ? "food ready" : "served"})`).join(", ")}
  Logins: print/demo-cafe-logins.txt
`);
