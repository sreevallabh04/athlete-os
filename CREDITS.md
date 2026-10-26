# Credits & third-party data

Athlete OS's own source code is MIT-licensed (see [LICENSE](LICENSE)). The
following third-party content keeps its original licence and terms.

## Data

| Source | Used for | Licence / terms |
|---|---|---|
| **Indian food nutrition dataset** — `assets/data/indian_food_nutrition.csv` (1,014 dishes, values per 100 g: energy, carbohydrates, protein, fat, free sugar, fibre, sodium, calcium, iron, vitamin C, folate) | Offline "Indian dishes" search and grounding of AI food-log estimates | **Provenance not yet confirmed.** Supplied by the project owner from a publicly shared file (`Indian_Food_Nutrition_Processed.csv`); the original author and licence could not be identified. The dish list and nutrient columns resemble datasets derived from India's national nutrient databank. If you are the author or rights holder, please open an issue — the file will be credited properly or removed on request. Not covered by this repository's MIT licence. |
| [Open Food Facts](https://world.openfoodfacts.org) | Barcode and packaged-food search (fetched at runtime, not bundled) | Database: [ODbL](https://opendatacommons.org/licenses/odbl/1-0/); contents: DbCL; images: CC BY-SA. Attribution shown in-app. |
| [USDA FoodData Central](https://fdc.nal.usda.gov) | Generic food search (fetched at runtime) | Public domain (CC0); citation requested. |
| Strava, Hevy, Google Calendar, Health Connect | Optional user-connected integrations (runtime only) | Each provider's own API terms; Strava data is never sent to AI (Strava API Policy §5.3). |

## Fonts

Bundled in `assets/fonts/` under the [SIL Open Font License 1.1](assets/fonts/OFL.txt):
**Inter**, **Rajdhani** and **JetBrains Mono** (from the google/fonts repository).

## Software

Built with Flutter and the open-source packages listed in `pubspec.yaml`, each
under its own licence (viewable in-app at Settings › About › Licences).
