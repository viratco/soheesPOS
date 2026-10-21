// Replaces the whole menu with Sohee's Kitchen categories + dishes.
// Past orders are unaffected (they store their own name/price snapshots).
// Usage: npm run load-menu
// PLACEHOLDER dishes/prices based on the DotPe posters. Edit in Menu admin.
import { createClient } from "@supabase/supabase-js";
import ws from "ws";

const db = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL, process.env.SUPABASE_SECRET_KEY, {
  auth: { persistSession: false },
  realtime: { transport: ws },
});

// [name, description, price ₹, diet, spice 0-3, bestseller, moods, subcategory]
// Prices marked * are taken from the DotPe menu; the rest are placeholders.
const MENU = [
  {
    name: "Beverages",
    items: [
      ["Hot Coffee", null, 220, "veg", 0, false, ["drink"], "Hot"], // *
      ["Cappuccino", null, 240, "veg", 0, false, ["drink"], "Hot"], // *
      ["Hot Choco", null, 250, "veg", 0, false, ["drink"], "Hot"], // *
      ["Espresso", null, 180, "veg", 0, false, ["drink"], "Hot"],
      ["Iced Americano", null, 220, "veg", 0, false, ["drink"], "Cold"],
      ["Matcha Bubble Tea", "Iced matcha latte with brown sugar pearls", 249, "veg", 0, true, ["drink"], "Cold"],
      ["Brown Sugar Boba Milk", "Fresh milk, brown sugar syrup, boba", 229, "veg", 0, false, ["drink"], "Cold"],
      ["Yuzu Ade", "Sparkling Korean citron", 199, "veg", 0, false, ["drink"], "Cold"],
      ["Chocolate Milk Shake", null, 260, "veg", 0, false, ["drink"], "Milk Shake"],
      ["Strawberry Milk Shake", null, 260, "veg", 0, false, ["drink"], "Milk Shake"],
    ],
  },
  {
    name: "HOUSE FAVORITES",
    items: [
      ["Yam Yam Chicken Burger", "Crispy fried chicken, yangnyeom glaze, slaw", 299, "nonveg", 2, false, ["meal"], "Burgers"],
      ["Crispy Veg Burger", "Crunchy veg patty, gochujang mayo", 249, "veg", 1, false, ["meal"], "Burgers"],
      ["Onigiri", null, 440, "veg", 0, true, ["share"], "Onigiri"], // *
      ["Korean Corn Dog", "Potato-crusted mozzarella dog, sugar dusted", 199, "veg", 0, false, ["share"], "Snacks"],
      ["Corn Cheese", "Sweet corn baked with mozzarella", 189, "veg", 0, false, ["share"], "Snacks"],
    ],
  },
  {
    name: "SIGNATURES",
    items: [
      ["French Fries with Cheese & Bacon", null, 390, "nonveg", 0, false, ["share"], "French Fries"], // *
      ["French Fries Salted", null, 310, "veg", 0, false, ["share"], "French Fries"], // *
      ["Yam Yam Fries", "Mixed with our special Yangnyeom Korean sauce", 350, "veg", 2, false, ["share"], "French Fries"], // *
      ["Veg Kimbap", "Korean rice rolls with pickled radish, carrot, spinach", 390, "veg", 0, false, ["share", "meal"], "Kimbap"],
      ["Chicken Kimbap", null, 440, "nonveg", 0, true, ["share", "meal"], "Kimbap"], // *
      ["Veg Mandu", "Korean dumplings, chilli-soy dip", 320, "veg", 1, false, ["share"], "Mandu (Momos)"],
      ["Chicken Mandu", "Korean dumplings, chilli-soy dip", 360, "nonveg", 1, false, ["share"], "Mandu (Momos)"],
      ["Tteokbokki", "Chewy rice cakes in sweet-spicy gochujang", 349, "veg", 3, false, ["share"], "tteokbokki"],
      ["Cheese Tteokbokki", "Tteokbokki under melted mozzarella", 389, "veg", 2, false, ["share"], "tteokbokki"],
      ["Fried Chicken Boneless", "Boneless", 450, "nonveg", 1, true, ["share", "meal"], "Fried Chicken"], // *
      ["Yam Yam Chicken", "Fried chicken in sweet-spicy yangnyeom sauce", 470, "nonveg", 2, false, ["share", "meal"], "Fried Chicken"],
    ],
  },
  {
    name: "Complete Plates",
    items: [
      ["Kimchi Jjigae", "Kimchi stew with tofu and enoki, with rice", 429, "veg", 3, false, ["meal"], null],
      ["Veg Bibimbap", "Rice bowl, sautéed vegetables, gochujang", 399, "veg", 1, false, ["meal"], null],
      ["Chicken Bulgogi Bowl", "Sweet-soy grilled chicken over rice", 449, "nonveg", 1, false, ["meal"], null],
      ["Kimchi Fried Rice", "With a fried egg on top", 379, "egg", 2, false, ["meal"], null],
    ],
  },
  {
    name: "RAMEN & MORE",
    items: [
      ["Veg Ramen", "Spicy Korean ramyun with vegetables", 299, "veg", 2, false, ["meal"], "Ramen"],
      ["Egg Ramen", "Spicy ramyun with a soft egg", 329, "egg", 2, false, ["meal"], "Ramen"],
      ["Chicken Ramen", "Spicy ramyun with shredded chicken", 369, "nonveg", 2, false, ["meal"], "Ramen"],
      ["Jjajangmyeon", "Noodles in black bean sauce", 349, "veg", 0, false, ["meal"], "More"],
    ],
  },
];

async function must(promise) {
  const { data, error } = await promise;
  if (error) throw new Error(error.message);
  return data;
}

// Discovery columns exist only after migration 20261020010000_menu_discovery.sql.
const { error: noDiscovery } = await db.from("menu_items").select("diet").limit(1);
const hasDiscovery = !noDiscovery;
const { error: noLayout } = await db.from("menu_items").select("subcategory").limit(1);
const hasLayout = !noLayout;

await must(db.from("menu_items").delete().not("id", "is", null));
await must(db.from("menu_categories").delete().not("id", "is", null));

for (const [ci, cat] of MENU.entries()) {
  const [row] = await must(db.from("menu_categories").insert({ name: cat.name, sort_order: (ci + 1) * 10 }).select());
  await must(
    db.from("menu_items").insert(
      cat.items.map(([name, description, rupees, diet, spice_level, is_bestseller, moods, subcategory], i) => ({
        category_id: row.id,
        name,
        description,
        price_paise: rupees * 100,
        sort_order: (i + 1) * 10,
        ...(hasDiscovery ? { diet, spice_level, is_bestseller, moods } : {}),
        ...(hasLayout ? { subcategory } : {}),
      })),
    ),
  );
}

console.log(`menu: ${MENU.length} categories, ${MENU.flatMap((c) => c.items).length} dishes loaded`);
if (!hasDiscovery || !hasLayout) {
  console.log("note: run migrations 20261020010000_menu_discovery.sql and 20261020020000_menu_layout.sql,");
  console.log("      then `npm run load-menu` again for veg marks, Best Seller and sub-category tabs");
}
