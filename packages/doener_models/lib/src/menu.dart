/// What someone eats. Food carries the strictest diet it suits: a vegan dish
/// suits everyone, a vegetarian one everyone but vegans.
enum Diet {
  all('Alles', '🍖'),
  vegetarian('Vegetarisch', '🧀'),
  vegan('Vegan', '🌱');

  final String label;
  final String emoji;
  const Diet(this.label, this.emoji);

  /// Whether this diet eats food suited to [food].
  bool allows(Diet food) => food.index >= index;

  /// The main score: the Döner for everyone, the meat-free or vegan food otherwise.
  String get scoreLabel => switch (this) { all => 'Gesamt', vegetarian => 'Ohne Fleisch', vegan => 'Vegan' };

  /// Items whose average makes up the main score.
  List<RatingItem> get scoreItems => switch (this) {
        all => const [RatingItem.sauce, RatingItem.fleisch, RatingItem.salat, RatingItem.brot],
        vegetarian => const [
            RatingItem.falafel,
            RatingItem.halloumi,
            RatingItem.veganDoener,
            RatingItem.sauce,
            RatingItem.salat,
            RatingItem.brot,
          ],
        vegan => const [
            RatingItem.falafel,
            RatingItem.veganDoener,
            RatingItem.veganSauce,
            RatingItem.hummus,
            RatingItem.salat,
            RatingItem.brot,
          ],
      };

  /// A review only counts for the main score once it rates one of these — a
  /// rated bread or salad alone says nothing about the Döner, the falafel or the vegan food.
  List<RatingItem> get scoreRequires => switch (this) {
        all => const [RatingItem.sauce, RatingItem.fleisch],
        vegetarian => const [RatingItem.falafel, RatingItem.halloumi, RatingItem.veganDoener],
        vegan => const [RatingItem.falafel, RatingItem.veganDoener, RatingItem.veganSauce, RatingItem.hummus],
      };

  /// Main score of one review: the average of its [scoreItems], or null if
  /// it rates none of [scoreRequires].
  double? score(Map<RatingItem, double> ratings) {
    if (!scoreRequires.any(ratings.containsKey)) return null;
    final rated = [for (final item in scoreItems) ?ratings[item]];
    return rated.reduce((a, b) => a + b) / rated.length;
  }

  /// The score a review shows to someone with this diet — only from food the
  /// diet eats: the own main score, else a stricter diet's one, else the
  /// average of the fitting dishes (drinks only when nothing else is rated).
  double? headline(Map<RatingItem, double> ratings) {
    for (final diet in Diet.values.skip(index)) {
      final value = diet.score(ratings);
      if (value != null) return value;
    }
    final fitting = {for (final e in ratings.entries) if (allows(e.key.diet)) e.key: e.value};
    final dishes = [for (final e in fitting.entries) if (e.key != RatingItem.ayran) e.value];
    final rest = dishes.isEmpty ? fitting.values.toList() : dishes;
    return rest.isEmpty ? null : rest.reduce((a, b) => a + b) / rest.length;
  }
}

/// Everything a review can rate, 1–5 each in half steps. Sauce, meat, salad
/// and bread are the Döner itself, everything else is optional.
enum RatingItem {
  sauce('Soße', '🥣', Diet.vegetarian),
  fleisch('Fleisch', '🥩', Diet.all),
  salat('Salat', '🥗', Diet.vegan),
  brot('Brot', '🍞', Diet.vegan),
  falafel('Falafel', '🧆', Diet.vegan),
  halloumi('Halloumi', '🧀', Diet.vegetarian),
  pizza('Pizza', '🍕', Diet.vegetarian),
  pide('Pide', '🥟', Diet.vegetarian),
  lahmacun('Lahmacun', '🫓', Diet.all),
  seele('Seele', '🥖', Diet.vegetarian),
  veganDoener('Veganer Döner', '🌱', Diet.vegan, hint: 'Seitan oder Soja'),
  veganSauce('Vegane Soße', '🥣', Diet.vegan),
  hummus('Hummus', '🫘', Diet.vegan),
  ayran('Ayran', '🥛', Diet.vegetarian, hint: 'selbstgemacht');

  final String label;
  final String emoji;

  /// The strictest diet the item suits.
  final Diet diet;
  final String? hint;
  const RatingItem(this.label, this.emoji, this.diet, {this.hint});

  static const doenerItems = [sauce, fleisch, salat, brot];

  /// Rated from the start: fields of their own in the JSON and columns of
  /// their own in the database. All other items are review_items.
  static const classicItems = [sauce, fleisch, brot];

  /// Unknown to clients before 1.1, which fail on item names they don't know.
  /// The JSON carries these in keys of their own that those clients don't read.
  static const newItems = [salat];

  /// "Was gab's noch?"
  static const extraItems = [falafel, halloumi, pizza, pide, lahmacun, seele];

  /// Rated once the place has vegan options.
  static const veganItems = [veganDoener, veganSauce, hummus];

  bool get isDoener => doenerItems.contains(this);
}

enum IngredientGroup {
  salad('Salat & Gemüse'),
  special('Besonderheiten'),
  sauce('Soßen');

  final String label;
  const IngredientGroup(this.label);
}

/// What "mit allem" can mean. Experts tick what came in their Döner.
enum Ingredient {
  eisberg('Eisberg', IngredientGroup.salad),
  tomate('Tomate', IngredientGroup.salad),
  gurke('Gurke', IngredientGroup.salad),
  zwiebel('Zwiebel', IngredientGroup.salad),
  rotkohl('Rotkohl', IngredientGroup.salad),
  weisskohl('Weißkohl', IngredientGroup.salad),
  karotte('Karotte', IngredientGroup.salad),
  petersilie('Petersilie', IngredientGroup.salad),
  peperoni('Peperoni', IngredientGroup.salad),
  mais('Mais', IngredientGroup.special),
  granatapfel('Granatapfelkerne', IngredientGroup.special),
  feta('Feta', IngredientGroup.special),
  oliven('Oliven', IngredientGroup.special),
  minze('Minze', IngredientGroup.special),
  sumach('Sumach-Zwiebeln', IngredientGroup.special),
  rucola('Rucola', IngredientGroup.special),
  grillgemuese('Gegrilltes Gemüse', IngredientGroup.special),
  pommes('Pommes im Döner', IngredientGroup.special),
  jalapenos('Jalapeños', IngredientGroup.special),
  kraeuter('Kräuter', IngredientGroup.sauce),
  knoblauch('Knoblauch', IngredientGroup.sauce),
  scharf('Scharf', IngredientGroup.sauce),
  cocktail('Cocktail', IngredientGroup.sauce),
  tzatziki('Tzatziki', IngredientGroup.sauce),
  tahini('Tahini', IngredientGroup.sauce);

  final String label;
  final IngredientGroup group;
  const Ingredient(this.label, this.group);

  bool get isSpecial => group == IngredientGroup.special;
}

enum Meat {
  kalb('Kalb'),
  rind('Rind'),
  haehnchen('Hähnchen'),
  pute('Pute'),
  lamm('Lamm'),
  gemischt('Gemischt');

  final String label;
  const Meat(this.label);
}

enum Skewer {
  homemade('Selbst gesteckt'),
  industrial('Fertigspieß');

  final String label;
  const Skewer(this.label);
}

enum Bread {
  homemade('Selbst gebacken'),
  bought('Gekauft');

  final String label;
  const Bread(this.label);
}

/// What a ranking sorts by: a diet's main score or a single item. On the wire
/// it is the item's name, `overall` for the Döner or the diet's name.
class RankBy {
  final Diet? diet;
  final RatingItem? item;
  const RankBy.score(Diet this.diet) : item = null;
  const RankBy.item(RatingItem this.item) : diet = null;

  static const overall = RankBy.score(Diet.all);

  String get key => item?.name ?? (diet == Diet.all ? 'overall' : diet!.name);
  String get label => item?.label ?? diet!.scoreLabel;

  static RankBy? parse(String key) {
    if (key == overall.key) return overall;
    for (final diet in [Diet.vegetarian, Diet.vegan]) {
      if (key == diet.name) return RankBy.score(diet);
    }
    final item = RatingItem.values.asNameMap()[key];
    return item == null ? null : RankBy.item(item);
  }

  /// The rankings someone with [diet] gets to see, the main score first.
  static List<RankBy> forDiet(Diet diet) => switch (diet) {
        Diet.all => [
            overall,
            for (final i in [RatingItem.sauce, RatingItem.fleisch, RatingItem.salat, RatingItem.brot, RatingItem.falafel, RatingItem.halloumi])
              RankBy.item(i),
            const RankBy.score(Diet.vegan),
            for (final i in [RatingItem.pizza, RatingItem.pide, RatingItem.lahmacun, RatingItem.seele, RatingItem.ayran]) RankBy.item(i),
          ],
        Diet.vegetarian => [
            const RankBy.score(Diet.vegetarian),
            for (final i in [RatingItem.falafel, RatingItem.halloumi]) RankBy.item(i),
            const RankBy.score(Diet.vegan),
            for (final i in [RatingItem.sauce, RatingItem.salat, RatingItem.brot, RatingItem.pizza, RatingItem.pide, RatingItem.seele, RatingItem.ayran])
              RankBy.item(i),
          ],
        Diet.vegan => [
            const RankBy.score(Diet.vegan),
            for (final i in [RatingItem.veganDoener, RatingItem.falafel, RatingItem.hummus, RatingItem.veganSauce, RatingItem.salat, RatingItem.brot])
              RankBy.item(i),
          ],
      };

  @override
  bool operator ==(Object other) => other is RankBy && other.diet == diet && other.item == item;
  @override
  int get hashCode => Object.hash(diet, item);
}
