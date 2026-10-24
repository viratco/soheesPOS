// Sohee's Kitchen REAL menu, read from the DotPe screen recording (24 Oct 2026).
// Items marked CHECK need the owner's confirmation before going live.
//
// Usage:  npm run load-sohees-menu            → prints a summary only (dry run)
//         npm run load-sohees-menu -- --yes   → replaces the live menu
//         npm run load-sohees-menu -- --md    → prints the review table (Markdown)
import { readFileSync } from "fs";
import { createClient } from "@supabase/supabase-js";
import ws from "ws";

// Photos copied from the café's DotPe menu into our Supabase storage (bucket "menu-photos").
const PHOTOS = JSON.parse(readFileSync(new URL("./sohees-menu-photos.json", import.meta.url), "utf8"));

// d = diet: v veg · e egg · n non-veg   |  opts: best (Best Seller), spicy, custom (has options on DotPe)
const v = "veg", e = "egg", n = "nonveg";

// Option group: name, min picks, max picks, [choice, extra ₹]
const O = (name, min, max, choices) => ({ name, min, max, choices: choices.map(([c, rs = 0]) => ({ name: c, price: rs * 100 })) });
const VEG_CHICKEN_PORK = (chicken, pork) => [O("Choice", 1, 1, [["Veg"], ["Chicken", chicken], ["Pork", pork]])];
const HALF_FULL_SAUCES = [
  O("Choice", 1, 1, [["Half"], ["Full", 140]]),
  O("Add On", 0, 3, [["Jja Jang Sauce", 50], ["Honey Butter", 50], ["Yum Yum Sauce", 50]]),
];

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
      "Milk Shake": [["Milk Shake", 290, v, null, { options: [O("Flavour", 1, 1, [["Taro"], ["Thai Tea"], ["Tiramisu"], ["Hazelnut"]])] }]],
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
      Bibimbap: [["Bibimbap", 460, v, null, { options: VEG_CHICKEN_PORK(50, 80) }]],
      Pastas: [
        ["Penne Arrabbiata", 410, v, null, { options: [O("Choice", 1, 1, [["Veg"], ["Non Veg", 60]])] }],
        ["Penne Alfredo", 410, v, null, { options: [O("Choice", 1, 1, [["Veg"], ["Non Veg", 60]])] }],
      ],
      "Jja Jangbap": [["Jja Jangbap", 390, v, null, { options: VEG_CHICKEN_PORK(60, 110) }]],
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
        ["Veg Pan Fried Chilli Mandu", 520, v, null, { spicy: true }],
        ["Chicken Pan Fried Chilli Mandu", 580, n, null, { spicy: true }],
      ],
      Tteokbokki: [
        ["Tteokbokki", 410, v, "Chewy Korean rice cakes simmered in a rich, spicy sauce", {
          options: [O("Sauce", 1, 1, [["Sweet & Spicy Sauce"], ["Cheese", 50], ["Jja Jang Sauce", 80]])],
        }],
      ],
      "Fried Chicken": [
        ["Chicken Wings", 350, n, null, { options: HALF_FULL_SAUCES }],
        ["Fried Chicken Boneless", 450, n, "Boneless", { best: true, options: HALF_FULL_SAUCES }],
      ],
      Onigiri: [["Onigiri", 440, v, null, { best: true, options: VEG_CHICKEN_PORK(50, 80) }]],
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
        ["Kimchi Ramen", 390, v, null, { custom: true, check: "Has options on DotPe. Please send a screenshot of them" }],
      ],
      Noodles: [
        ["Jja Jangmyeon", 410, n, null, { custom: true, check: "Has options on DotPe. Please send a screenshot of them" }],
        ["Japchae", 390, v, null, { custom: true, check: "Has options on DotPe. Please send a screenshot of them" }],
        ["Egg Fried Noodles", 440, e],
        ["Chicken Fried Noodles", 490, n],
        ["Veg Fried Noodles", 390, v],
        ["Bang Bang Noodles", 410, v, null, { best: true, custom: true, check: "Has options on DotPe. Please send a screenshot of them" }],
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
  {
    name: "Desserts",
    subs: { Desserts: [["Nutella Cloud", 300, v]] },
  },
];

// Short description shown under each dish on the menu (owner can edit in Menu admin).
export const DESCRIPTIONS = {
  // Beverages · Hot
  Chai: "Kadak chai brewed with milk and warm spices",
  Americano: "Double espresso topped with hot water",
  Cappuccino: "Espresso with steamed milk and a thick foam",
  "Hot Choco": "Rich, creamy hot chocolate",
  "Hot Coffee": "Classic milky hot coffee",
  Espresso: "A short, strong shot of espresso",
  // Beverages · Cold
  "Cold Chocolate": "Chilled chocolate milk, thick and creamy",
  "Taro Coffee": "Iced coffee layered with sweet taro milk",
  "Peach Ice Tea": "Chilled tea with sweet peach",
  "Lemon Ice Tea": "Chilled tea with a squeeze of lemon",
  "Iced Americano": "Espresso over ice and cold water",
  "Iced Latte": "Espresso with cold milk over ice",
  Affogato: "Vanilla ice cream drowned in a hot espresso shot",
  "Coffee Lemonade": "Espresso over fizzy lemonade, zesty and bold",
  "Iced Espresso": "A shot of espresso poured over ice",
  "Boho Blush": "Our pink house cooler, fruity and refreshing",
  "Voodoo Mango": "Our tangy mango house cooler",
  "Son of a Beach": "Our tropical house cooler",
  "Milk Shake": "Thick, creamy shake in Taro, Thai Tea, Tiramisu or Hazelnut",
  // House favourites
  "Egg & Cheese Sandwich": "Toasted sandwich with fluffy egg and melted cheese",
  "Veg Sandwich": "Toasted sandwich loaded with fresh vegetables",
  "Chicken Sandwich": "Toasted sandwich with seasoned chicken",
  "Chicken Yam Yam Burger": "Crispy chicken patty glazed in our sweet-spicy yangnyeom sauce",
  "Chicken Burger": "Crispy chicken patty with fresh veggies and house sauce",
  "Veg Burger": "Crispy veg patty with fresh veggies and house sauce",
  "Veg Yam Yam Burger": "Crispy veg patty glazed in our sweet-spicy yangnyeom sauce",
  "Veg Fried Rice": "Wok-tossed rice with fresh vegetables",
  "Egg Fried Rice": "Wok-tossed rice with egg and spring onion",
  "Chicken Fried Rice": "Wok-tossed rice with tender chicken and vegetables",
  "Pork Kimchi Fried Rice": "Spicy kimchi fried rice with pork",
  "Veg Kimchi Fried Rice": "Spicy kimchi fried rice with vegetables",
  "Egg Kimchi Fried Rice": "Spicy kimchi fried rice with egg",
  "Chicken Kimchi Fried Rice": "Spicy kimchi fried rice with chicken",
  Bibimbap: "Korean rice bowl with sautéed vegetables, gochujang and sesame",
  "Penne Arrabbiata": "Penne in a spicy tomato and garlic sauce",
  "Penne Alfredo": "Penne in a creamy white cheese sauce",
  "Jja Jangbap": "Steamed rice topped with Korean black bean sauce",
  // Signatures
  "French Fries with Cheese & Bacon": "Crispy fries topped with melted cheese and bacon",
  "French Fries Salted": "Classic crispy salted fries",
  "Yam Yam Fries": "Fries tossed in our sweet-spicy yangnyeom sauce",
  "Veg Kimbap": "Korean seaweed rice rolls with fresh vegetables",
  "Chicken Kimbap": "Korean seaweed rice rolls with chicken and vegetables",
  "Cheese Kimbap": "Korean seaweed rice rolls with cheese and vegetables",
  "Egg Kimbap": "Korean seaweed rice rolls with egg and vegetables",
  "Chicken Mandu Momos": "Korean-style chicken dumplings, steamed or fried",
  "Veg Mandu Momos": "Korean-style veg dumplings, steamed or fried",
  "Veg Pan Fried Chilli Mandu": "Pan-fried veg dumplings tossed in spicy chilli sauce",
  "Chicken Pan Fried Chilli Mandu": "Pan-fried chicken dumplings tossed in spicy chilli sauce",
  Tteokbokki: "Chewy Korean rice cakes simmered in a rich, spicy sauce",
  "Chicken Wings": "Crispy Korean fried wings, half or full, with your pick of sauce",
  "Fried Chicken Boneless": "Crispy boneless Korean fried chicken, half or full",
  Onigiri: "Japanese rice triangles wrapped in seaweed",
  // Complete plates
  "Jeyuk Bokkeum": "Tender pork stir-fried in a rich, spicy Korean chilli sauce",
  "Chilli Chicken": "Crispy chicken tossed with peppers in a spicy chilli sauce",
  "Chilli Tofu": "Crispy tofu tossed with peppers in a spicy chilli sauce",
  "Kung Pao Chicken": "Chicken stir-fried with peanuts and dried chillies",
  "Kung Pao Chicken Rice Bowl": "Kung pao chicken served over steamed rice",
  "Veg Kimchi Jjigae": "Spicy Korean stew with kimchi, tofu and vegetables",
  "Pork Kimchi Jjigae": "Spicy Korean stew with kimchi, pork and vegetables",
  "Chicken Kimchi Jjigae": "Spicy Korean stew with kimchi, chicken and vegetables",
  "Chicken Katsu": "Golden fried chicken cutlet with a savoury sauce",
  // Ramen & more
  "Chicken Ramen": "Spicy Korean ramen with chicken",
  "Egg Ramen": "Spicy Korean ramen with egg",
  "Veg Ramen": "Spicy Korean ramen with vegetables",
  "Kimchi Ramen": "Spicy Korean ramen with tangy kimchi",
  "Jja Jangmyeon": "Noodles in savoury Korean black bean sauce",
  Japchae: "Stir-fried glass noodles with vegetables and sesame",
  "Egg Fried Noodles": "Wok-tossed noodles with egg and vegetables",
  "Chicken Fried Noodles": "Wok-tossed noodles with chicken and vegetables",
  "Veg Fried Noodles": "Wok-tossed noodles with fresh vegetables",
  "Bang Bang Noodles": "Noodles tossed in our spicy, creamy bang bang sauce",
  "Veg Carbonara Buldak": "Creamy, fiery Korean buldak noodles with vegetables",
  "Chicken Carbonara Buldak": "Creamy, fiery Korean buldak noodles with chicken",
  "Pork Carbonara Buldak": "Creamy, fiery Korean buldak noodles with pork",
  "Veg Chow Chow": "Stir-fried instant noodles with vegetables",
  "Chicken Chow Chow": "Stir-fried instant noodles with chicken",
  "Pork Chow Chow": "Stir-fried instant noodles with pork",
  "Veg Wai Wai Sandekho": "Crunchy Wai Wai noodle salad with onion, tomato and spices",
  "Veg Buldak Mandu Bowl": "Spicy buldak noodles with veg dumplings",
  "Chicken Buldak Mandu Bowl": "Spicy buldak noodles with chicken dumplings",
  // Desserts
  "Nutella Cloud": "Light, fluffy dessert layered with rich Nutella",
};

const MOOD_BY_CATEGORY = { Desserts: ["share"], Beverages: ["drink"], SIGNATURES: ["share"], "HOUSE FAVORITES": ["meal"], "Complete Plates": ["meal"], "RAMEN & MORE": ["meal"] };

export function rows() {
  const out = [];
  for (const cat of MENU) {
    for (const [sub, items] of Object.entries(cat.subs)) {
      for (const [name, rupees, diet, desc, opts = {}] of items) {
        out.push({ category: cat.name, sub, name, rupees, diet, desc: DESCRIPTIONS[name] ?? desc ?? null, ...opts });
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
      console.log(`\n### ${cur}\n\n| Sub-category | Dish | Price | Type | Description | Notes |\n|---|---|---|---|---|---|`);
    }
    const opts = (r.options ?? []).map((g) => `${g.name}: ${g.choices.map((c) => (c.price ? `${c.name} +₹${c.price / 100}` : c.name)).join(" / ")}`).join(" · ");
    const notes = [r.best && "⭐ Best Seller", r.spicy && "🌶 Spicy", opts && `Options → ${opts}`, r.check && `❓ ${r.check}`].filter(Boolean).join(" · ");
    console.log(`| ${r.sub} | ${r.name} | ₹${r.rupees} | ${dietLabel[r.diet]} | ${r.desc ?? ""} | ${notes} |`);
  }
  process.exit(0);
}

console.log(`${MENU.length} categories · ${all.length} dishes · ${all.filter((r) => r.best).length} best sellers · ${all.filter((r) => r.options?.length).length} with options · ${all.filter((r) => r.check).length} to confirm`);
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

// Options need migration 20261025000000_options.sql; without it, load dishes at base price.
const { error: noOptions } = await db.from("menu_items").select("options").limit(1);
const hasOptions = !noOptions;

// Past orders keep their own name/price snapshots, so replacing the menu is safe.
await must(db.from("menu_items").delete().not("id", "is", null));
await must(db.from("menu_categories").delete().not("id", "is", null));

for (const [ci, cat] of MENU.entries()) {
  const [row] = await must(
    db.from("menu_categories").insert({ name: cat.name, sort_order: (ci + 1) * 10, image_url: PHOTOS.categories[cat.name] ?? null }).select(),
  );
  let i = 0;
  const items = Object.entries(cat.subs).flatMap(([sub, list]) =>
    list.map(([name, rupees, diet, desc, opts = {}]) => ({
      category_id: row.id,
      name,
      description: DESCRIPTIONS[name] ?? desc ?? null,
      image_url: PHOTOS.dishes[name] ?? null,
      price_paise: rupees * 100,
      diet,
      spice_level: opts.spicy ? 2 : 0,
      is_bestseller: !!opts.best,
      moods: MOOD_BY_CATEGORY[cat.name] ?? [],
      subcategory: sub,
      ...(hasOptions ? { options: opts.options ?? [] } : {}),
      sort_order: (++i) * 10,
    })),
  );
  await must(db.from("menu_items").insert(items));
}
console.log(`Live menu replaced: ${all.length} dishes.`);
if (!hasOptions) console.log("Note: options NOT loaded. Run RUN_THIS_options.sql, then run this again with --yes.");
