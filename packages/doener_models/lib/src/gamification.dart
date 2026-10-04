import 'dtos.dart';
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

enum StampTier {
  doenerneuling(0, 'Dönerneuling'),
  doenerfreund(5, 'Dönerfreund'),
  doenerfan(15, 'Dönerfan'),
  doenerprofi(30, 'Dönerprofi'),
  doenermeister(60, 'Dönermeister'),
  doenerlegende(100, 'Dönerlegende');

  final int stampsRequired;
  final String displayName;
  const StampTier(this.stampsRequired, this.displayName);

  StampTier? get nextTier => index + 1 < values.length ? values[index + 1] : null;

  static StampTier forStamps(int count) =>
      values.lastWhere((t) => count >= t.stampsRequired, orElse: () => doenerneuling);
}

enum AchievementType {
  firstBite('First Bite', 'Check bei deinem ersten Döner-Laden ein'),
  critic('Kritiker', 'Schreibe deine erste Bewertung'),
  regular('Stammgast', 'Besuche denselben Laden 5 Mal'),
  explorer('Entdecker', 'Besuche 10 verschiedene Läden'),
  connoisseur('Kenner', 'Besuche 50 verschiedene Läden'),
  berlinTour('Berlin Döner Tour', 'Besuche 5 Döner-Läden in Berlin'),
  hamburgTour('Hamburg Döner Tour', 'Besuche 5 Döner-Läden in Hamburg'),
  stampCollectorSilver('Silber-Sammler', 'Erreiche die Stufe Dönerfan'),
  stampCollectorGold('Gold-Sammler', 'Erreiche die Stufe Dönermeister'),
  nightOwl('Nachtschwärmer', 'Checke nach 22 Uhr ein'),
  socialButterfly('Schmetterling', 'Füge 5 Freunde hinzu');

  final String title;
  final String description;
  const AchievementType(this.title, this.description);
}

/// Aggregated numbers behind the profile, stamp card and achievements.
class ProfileStats {
  final int totalVisits;
  final int totalReviews;
  final int uniquePlaces;
  final int maxVisitsToSamePlace;
  final bool hasNightVisit;
  final Map<String, int> uniquePlacesByCity;
  final DateTime? firstVisit;

  const ProfileStats({
    this.totalVisits = 0,
    this.totalReviews = 0,
    this.uniquePlaces = 0,
    this.maxVisitsToSamePlace = 0,
    this.hasNightVisit = false,
    this.uniquePlacesByCity = const {},
    this.firstVisit,
  });

  /// [cityOf] resolves a place ID to its city (null if unknown).
  factory ProfileStats.compute({
    required List<VisitDto> visits,
    required int reviewCount,
    required String? Function(String placeId) cityOf,
  }) {
    final perPlace = <String, int>{};
    for (final v in visits) {
      perPlace[v.placeId] = (perPlace[v.placeId] ?? 0) + 1;
    }
    final byCity = <String, int>{};
    for (final placeId in perPlace.keys) {
      final city = cityOf(placeId);
      if (city != null && city.isNotEmpty) byCity[city] = (byCity[city] ?? 0) + 1;
    }
    DateTime? first;
    for (final v in visits) {
      if (first == null || v.visitedAt.isBefore(first)) first = v.visitedAt;
    }
    return ProfileStats(
      totalVisits: visits.length,
      totalReviews: reviewCount,
      uniquePlaces: perPlace.length,
      maxVisitsToSamePlace: perPlace.values.fold(0, (a, b) => a > b ? a : b),
      hasNightVisit: visits.any((v) => v.visitedAt.toLocal().hour >= 22),
      uniquePlacesByCity: byCity,
      firstVisit: first,
    );
  }

  StampTier get stampTier => StampTier.forStamps(totalVisits);

  int? get stampsToNextTier {
    final next = stampTier.nextTier;
    return next == null ? null : next.stampsRequired - totalVisits;
  }

  /// 0…1 progress within the current tier.
  double get stampProgress {
    final next = stampTier.nextTier;
    if (next == null) return 1;
    final range = next.stampsRequired - stampTier.stampsRequired;
    return (totalVisits - stampTier.stampsRequired) / range;
  }

  Set<AchievementType> unlockedAchievements({required int friendsCount}) => {
        if (totalVisits >= 1) AchievementType.firstBite,
        if (totalReviews >= 1) AchievementType.critic,
        if (maxVisitsToSamePlace >= 5) AchievementType.regular,
        if (uniquePlaces >= 10) AchievementType.explorer,
        if (uniquePlaces >= 50) AchievementType.connoisseur,
        if ((uniquePlacesByCity['Berlin'] ?? 0) >= 5) AchievementType.berlinTour,
        if ((uniquePlacesByCity['Hamburg'] ?? 0) >= 5) AchievementType.hamburgTour,
        if (stampTier.index >= StampTier.doenerfan.index) AchievementType.stampCollectorSilver,
        if (stampTier.index >= StampTier.doenermeister.index) AchievementType.stampCollectorGold,
        if (hasNightVisit) AchievementType.nightOwl,
        if (friendsCount >= 5) AchievementType.socialButterfly,
      };
}
