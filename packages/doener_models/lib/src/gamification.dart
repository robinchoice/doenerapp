import 'menu.dart';

/// What someone eats at a check-in.
class FoodItem {
  final String id;
  final String emoji;
  final String label;

  /// The strictest diet the food suits.
  final Diet diet;
  const FoodItem(this.id, this.emoji, this.label, this.diet);

  static const all = [
    FoodItem('doener', '🥙', 'Döner', Diet.all),
    FoodItem('yufka', '🌯', 'Yufka', Diet.all),
    FoodItem('lahmacun', '🫓', 'Lahmacun', Diet.all),
    FoodItem('teller', '🍽️', 'Teller', Diet.all),
    // Without meat the wheel starts at the falafel, not the fries.
    FoodItem('falafel', '🧆', 'Falafel', Diet.vegan),
    FoodItem('veganDoener', '🌱', 'Veganer Döner', Diet.vegan),
    FoodItem('halloumi', '🧀', 'Halloumi', Diet.vegetarian),
    FoodItem('pizza', '🍕', 'Pizza', Diet.vegetarian),
    FoodItem('pide', '🥟', 'Pide', Diet.vegetarian),
    FoodItem('seele', '🥖', 'Seele', Diet.vegetarian),
    FoodItem('pommes', '🍟', 'Pommes', Diet.vegan),
  ];

  static List<FoodItem> forDiet(Diet diet) => [for (final f in all) if (diet.allows(f.diet)) f];

  static FoodItem? byId(String? id) {
    for (final item in all) {
      if (item.id == id) return item;
    }
    return null;
  }
}

/// The level next to someone's name, by how many places they reviewed.
enum Tier {
  doenerneuling(0, 'Dönerneuling'),
  doenerfreund(3, 'Dönerfreund'),
  doenerfan(10, 'Dönerfan'),
  doenerprofi(25, 'Dönerprofi'),
  doenermeister(50, 'Dönermeister'),
  doenerlegende(100, 'Dönerlegende');

  final int reviewedPlaces;
  final String displayName;
  const Tier(this.reviewedPlaces, this.displayName);

  Tier? get next => index + 1 < values.length ? values[index + 1] : null;

  static Tier forReviewedPlaces(int count) => values.lastWhere((t) => count >= t.reviewedPlaces);
}
