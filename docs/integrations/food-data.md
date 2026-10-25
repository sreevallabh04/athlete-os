# Food data: Open Food Facts & USDA FoodData Central

Athlete OS looks foods up **local-first** (foods you have saved, scanned or
created), then in **Open Food Facts** (packaged products, barcodes) and,
optionally, **USDA FoodData Central** (generic staples such as rice, dal,
paneer). Code: `lib/features/nutrition/data/`.

## Open Food Facts (OFF)

Official API only — no scraping.

| Use | Endpoint |
| --- | --- |
| Barcode lookup | `GET https://world.openfoodfacts.org/api/v3/product/{barcode}.json?fields=code,product_name,product_name_en,generic_name,brands,quantity,serving_size,serving_quantity,serving_quantity_unit,nutrition_data_per,nutriments` |
| Text search | `GET https://world.openfoodfacts.org/cgi/search.pl?search_terms=…&search_simple=1&action=process&json=1&page_size=20&fields=…` |

* **User-Agent is required**: `AthleteOS/1.0.0 (<OFF_CONTACT_EMAIL>)`. Set the
  contact address at build time with `--dart-define=OFF_CONTACT_EMAIL=you@…`
  (or in `config/dev.json`). The default placeholder must be replaced before
  release.
* **Rate limits** (per IP): **15 product reads/min** and **10 searches/min**.
  OFF bans IPs that abuse the API. The client enforces both limits locally
  (`RateLimiter`, sliding 60 s window) and the UI searches **only on submit**
  — never search-as-you-type.
* **Resilience**: 12 s timeout; up to 2 retries with exponential backoff
  (600 ms, 1.2 s) for HTTP 429/5xx and timeouts, honouring `Retry-After`
  (capped at 30 s). Offline/unreachable errors are shown as friendly messages
  and local foods keep working.
* **Not found**: v3 returns HTTP 404 with `result.id = product_not_found`; the
  app offers manual entry prefilled with the barcode.
* **Mapping** (per 100 g, or per 100 ml for liquids when
  `serving_quantity_unit = ml`): `energy-kcal_100g`, `proteins_100g`,
  `carbohydrates_100g`, `fat_100g`, `fiber_100g`; per serving `*_serving` and
  `serving_quantity`. If only kJ is present, kcal = kJ / 4.184 (flagged).
  When a labelled serving size exists the food is stored per serving
  (per-100 g × serving_quantity / 100) with `gramsPerServing` set, so both
  "servings" and "grams" entry work.
* **Missing values are never invented.** A product is *complete* only if
  energy, protein, carbs and fat are all known (per 100 g or per serving).
  Incomplete products cannot be logged directly; the user completes them from
  the label (saved as `user_entered`).
* The original OFF values (subset) are preserved in `foods.raw_json`.

### Licensing & attribution

* Database: **Open Database License (ODbL)**; individual contents: **Database
  Contents License (DbCL)**; product images: **CC BY-SA**.
* The app shows **"Data from Open Food Facts (ODbL)"** wherever OFF data is
  displayed (search results, review sheet, completion form).
* If we ever redistribute an extract of OFF data (e.g. sync to a backend
  shared with others), ODbL share-alike obligations apply.

### Regional coverage caveats

OFF is crowd-sourced. Coverage of **Indian products is partial** and entries
may be outdated, use a different pack size, or have typos. Always compare
against the package label; barcode results are labelled *Label (barcode)*
only when nutriments are complete, and can be edited after saving.

## USDA FoodData Central (optional)

Used only when `USDA_API_KEY` is supplied at build time
(`--dart-define=USDA_API_KEY=…`). Without it, search shows "USDA search is off"
and the integration status is `awaiting_credentials`.

* Endpoint: `GET https://api.nal.usda.gov/fdc/v1/foods/search?api_key=…&query=…&dataType=Foundation,SR Legacy&pageSize=20`
* Nutrients (per 100 g): Energy kcal **1008** (fallback Atwater
  general **2047** / specific **2048**, which Foundation foods often use),
  Protein **1003**, Carbohydrate **1005**, Fat **1004**, Fiber **1079**.
  Legacy `nutrientNumber` values 208/957/958/203/205/204/291 are also read.
* **Key setup**: get a free key at <https://fdc.nal.usda.gov/api-key-signup>
  (data.gov). Limits: 1,000 requests/hour per key; the shared `DEMO_KEY` allows
  only ~30 requests/hour and is not suitable for the app. The client also
  limits itself to 20 searches/min.
* **License**: USDA FDC data is public domain (**CC0 1.0**). Attribution is
  appreciated: "USDA FoodData Central".
* The key is a client-side compile-time value; it is never logged and is
  redacted from error messages. Moving USDA search behind the backend would
  keep the key off devices entirely.

## Verification levels (stored on every food and log entry)

| `verification` | Meaning | Shown as |
| --- | --- | --- |
| `verified_label` | Barcode scan → OFF product with complete nutriments | "Label (barcode)" |
| `database` | OFF text search or USDA generic food | "Database" |
| `user_entered` | Typed in or completed by the user (custom foods, exact quick add) | "Entered by you" |
| `estimate` | AI estimate, meal-photo estimate or quick add not marked exact | **ESTIMATE** badge |

`source` records the provider: `openfoodfacts`, `usda`, `custom`,
`ai_estimate`, `quick_add`, `recipe`. Recipes and saved meals inherit the
**weakest** verification of their ingredients.

### Estimate policy

* AI text/photo estimates go through `FoodTextEstimator` /
  `MealPhotoAnalyzer`. Defaults report "not configured" — nothing is faked.
* Every estimated item is shown with an **ESTIMATE** badge and must be
  **confirmed individually** before it is saved.
* Meal photos require explicit consent (`ai_photo_consent`, default off) with
  a disclosure that the photo is sent to a third-party AI provider.
* Day totals that include estimates show a notice ("Includes N estimated
  items. Totals are approximate.").
* All totals, remaining values, averages and adherence figures are computed by
  deterministic, unit-tested Dart code (`domain/nutrition_calc.dart`).
