// Sohee's Kitchen REAL menu, read from the DotPe screen recording (24 Oct 2026).
// Items marked CHECK need the owner's confirmation before going live.
//
// Usage:  npm run load-sohees-menu            → prints a summary only (dry run)
//         npm run load-sohees-menu -- --yes   → replaces the live menu
//         npm run load-sohees-menu -- --md    → prints the review table (Markdown)
import { createClient } from "@supabase/supabase-js";
import ws from "ws";

// d = diet: v veg · e egg · n non-veg   |  opts: best (Best Seller), spicy, custom (has options on DotPe)
const v = "veg", e = "egg", n = "nonveg";

export const MENU = [
  {
    name: "Beverages",
    subs: {
      Hot: [
        ["Chai", 190, v],
        ["Americano", 220, v],
        ["Cappuccino", 240, v],
        ["Hot Choco", 250, v],
        ["Hot Coffee", 220, v],
        ["Espresso", 190, v],
      ],
      Cold: [
        ["Cold Chocolate", 250, v],
        ["Taro Coffee", 290, v],
        ["Peach Ice Tea", 220, v, null, { best: true }],
        ["Lemon Ice Tea", 220, v],
        ["Iced Americano", 220, v, null, { check: "Shown as 'Americano' under Cold on DotPe; renamed so it isn't confused with the hot one" }],
        ["Iced Latte", 250, v],
        ["Affogato", 310, v],
        ["Coffee Lemonade", 250, v],
        ["Iced Espresso", 190, v],
        ["Boho Blush", 235, v],
        ["Voodoo Mango", 235, v, null, { check: "Spelled 'Vodoo Mango' on DotPe" }],
        ["Son of a Beach", 300, v],
      ],
      "Milk Shake": [["Milk Shake", 290, v, null, { custom: true }]],
    },
  },
  {
    name: "HOUSE FAVORITES",
    subs: {
      Sandwiches: [
        ["Egg & Cheese Sandwich", 390, e],
        ["Veg Sandwich", 360, v],
        ["Chicken Sandwich", 440, n, null, { best: true }],
      ],
      Burgers: [
        ["Chicken Yam Yam Burger", 490, n, "Stir-fried chicken patty with our special yangnyeom sauce"],
        ["Chicken Burger", 460, n, null, { best: true }],
        ["Veg Burger", 415, v],
        ["Veg Yam Yam Burger", 445, v, "Stir-fried veg patty with our special yangnyeom sauce"],
      ],
      "Fried Rice": [
        ["Veg Fried Rice", 320, v],
        ["Egg Fried Rice", 360, e],
        ["Chicken Fried Rice", 420, n],
      ],
      "Kimchi Fried Rice": [
        ["Pork Kimchi Fried Rice", 470, n],
        ["Veg Kimchi Fried Rice", 340, v],
        ["Egg Kimchi Fried Rice", 370, e],
        ["Chicken Kimchi Fried Rice", 430, n],
      ],
      Bibimbap: [["Bibimbap", 460, v, null, { custom: true }]],
      Pastas: [
        ["Penne Arrabbiata", 410, v, null, { custom: true }],
        ["Penne Alfredo", 410, v, null, { custom: true }],
      ],
      "Jja Jangbap": [["Jja Jangbap", 390, v, null, { custom: true }]],
    },
  },
  {
    name: "SIGNATURES",
    subs: {
      "French Fries": [
        ["French Fries with Cheese & Bacon", 390, n, null, { check: "Marked VEG on DotPe, but bacon is non-veg. Set to non-veg here" }],
        ["French Fries Salted", 310, v],
        ["Yam Yam Fries", 350, v, "Tossed in our special yangnyeom Korean sauce"],
      ],
      Kimbap: [
        ["Veg Kimbap", 350, v],
        ["Chicken Kimbap", 440, n, null, { best: true }],
        ["Cheese Kimbap", 390, v],
        ["Egg Kimbap", 360, e],
      ],
      "Mandu (Momos)": [
        ["Chicken Mandu Momos", 470, n, "Korean-style dumplings, steamed or fried"],
        ["Veg Mandu Momos", 390, v, "Korean-style dumplings, steamed or fried"],
        ["Bang Bang Mandus", 430, v, null, { best: true, custom: true, check: "₹430 VEG here, but the Best Seller list shows ₹370 NON-VEG. Which is right (or are they two dishes)?" }],
        ["Veg Pan Fried Chilli Mandu", 520, v, null, { spicy: true }],
        ["Chicken Pan Fried Chilli Mandu", 580, n, null, { spicy: true }],
      ],
      Tteokbokki: [["Tteokbokki", 410, v, "Chewy Korean rice cakes simmered in a rich, spicy sauce", { custom: true }]],
      "Fried Chicken": [
        ["Chicken Wings", 350, n, null, { custom: true }],
        ["Fried Chicken Boneless", 450, n, "Boneless", { best: true, custom: true }],
      ],
      Onigiri: [["Onigiri", 440, v, null, { best: true, custom: true, check: "VEG mark in Best Seller, NON-VEG mark under Signatures. Which is it?" }]],
    },
  },
  {
    name: "Complete Plates",
    subs: {
      "Stir Fry": [
        ["Jeyuk Bokkeum", 590, n, "Tender pork stir-fried in a rich, spicy Korean chilli sauce"],
        ["Chilli Chicken", 450, n],
        ["Chilli Tofu", 390, v],
        ["Kung Pao Chicken", 560, n],
        ["Kung Pao Chicken Rice Bowl", 660, n, null, { best: true, check: "Only seen in the Best Seller list. Placed under Stir Fry. OK?" }],
      ],
      "Kimchi Jjigae": [
        ["Veg Kimchi Jjigae", 470, v, "Spicy Korean stew with kimchi and vegetables", { check: "DotPe's description for the veg one mentions pork; changed to 'kimchi and vegetables'" }],
        ["Pork Kimchi Jjigae", 590, n, "Spicy Korean stew with kimchi, pork and vegetables"],
        ["Chicken Kimchi Jjigae", 520, n, "Spicy Korean stew with kimchi, chicken and vegetables"],
      ],
      "Chicken Katsu": [["Chicken Katsu", 530, n, "Golden fried chicken cutlet with a savoury sauce"]],
    },
  },
  {
    name: "RAMEN & MORE",
    subs: {
      Ramen: [
        ["Chicken Ramen", 450, n],
        ["Egg Ramen", 390, e],
        ["Veg Ramen", 360, v],
        ["Kimchi Ramen", 390, v, null, { custom: true }],
      ],
      Noodles: [
        ["Jja Jangmyeon", 410, n, null, { custom: true }],
        ["Japchae", 390, v, null, { custom: true }],
        ["Egg Fried Noodles", 440, e],
        ["Chicken Fried Noodles", 490, n],
        ["Veg Fried Noodles", 390, v],
        ["Bang Bang Noodles", 410, v, null, { best: true, custom: true }],
        ["Veg Carbonara Buldak", 360, v],
        ["Chicken Carbonara Buldak", 410, n],
        ["Pork Carbonara Buldak", 500, n],
        ["Veg Chow Chow", 290, v],
        ["Chicken Chow Chow", 350, n],
        ["Pork Chow Chow", 410, n],
        ["Veg Wai Wai Sandekho", 250, v],
        ["Veg Buldak Mandu Bowl", 600, v],
        ["Chicken Buldak Mandu Bowl", 700, n],
      ],
    },
  },
  // Desserts: there's a "Desserts" tile on DotPe, but the recording didn't open it. Items needed.
];

const MOOD_BY_CATEGORY = { Beverages: ["drink"], SIGNATURES: ["share"], "HOUSE FAVORITES": ["meal"], "Complete Plates": ["meal"], "RAMEN & MORE": ["meal"] };

export function rows() {
  const out = [];
  for (const cat of MENU) {
    for (const [sub, items] of Object.entries(cat.subs)) {
      for (const [name, rupees, diet, desc, opts = {}] of items) {
        out.push({ category: cat.name, sub, name, rupees, diet, desc: desc ?? null, ...opts });
      }
    }
  }
  return out;
}

const args = process.argv.slice(2);
const all = rows();

if (args.includes("--md")) {
  const dietLabel = { veg: "🟢 Veg", egg: "🟡 Egg", nonveg: "🔴 Non-veg" };
  let cur = "";
  for (const r of all) {
    if (r.category !== cur) {
      cur = r.category;
      console.log(`\n### ${cur}\n\n| Sub-category | Dish | Price | Type | Notes |\n|---|---|---|---|---|`);
    }
    const notes = [r.best && "⭐ Best Seller", r.spicy && "🌶 Spicy", r.custom && "has options on DotPe", r.check && `❓ ${r.check}`].filter(Boolean).join(" · ");
    console.log(`| ${r.sub} | ${r.name} | ₹${r.rupees} | ${dietLabel[r.diet]} | ${notes} |`);
  }
  process.exit(0);
}

console.log(`${MENU.length} categories · ${all.length} dishes · ${all.filter((r) => r.best).length} best sellers · ${all.filter((r) => r.check).length} to confirm`);
if (!args.includes("--yes")) {
  console.log("Dry run. Nothing changed. Run with --yes to replace the live menu.");
  process.exit(0);
}

const db = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL, process.env.SUPABASE_SECRET_KEY, {
  auth: { persistSession: false },
  realtime: { transport: ws },
});
async function must(p) {
  const { data, error } = await p;
  if (error) throw new Error(error.message);
  return data;
}

// Past orders keep their own name/price snapshots, so replacing the menu is safe.
await must(db.from("menu_items").delete().not("id", "is", null));
await must(db.from("menu_categories").delete().not("id", "is", null));

for (const [ci, cat] of MENU.entries()) {
  const [row] = await must(db.from("menu_categories").insert({ name: cat.name, sort_order: (ci + 1) * 10 }).select());
  let i = 0;
  const items = Object.entries(cat.subs).flatMap(([sub, list]) =>
    list.map(([name, rupees, diet, desc, opts = {}]) => ({
      category_id: row.id,
      name,
      description: desc ?? null,
      price_paise: rupees * 100,
      diet,
      spice_level: opts.spicy ? 2 : 0,
      is_bestseller: !!opts.best,
      moods: MOOD_BY_CATEGORY[cat.name] ?? [],
      subcategory: sub,
      sort_order: (++i) * 10,
    })),
  );
  await must(db.from("menu_items").insert(items));
}
console.log("Live menu replaced.");
