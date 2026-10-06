import 'package:doener_models/doener_models.dart';
import 'package:test/test.dart';

VisitDto _visit(String placeId, DateTime at) => VisitDto(
      id: '$placeId-${at.microsecondsSinceEpoch}',
      userId: 'u',
      userName: 'U',
      placeId: placeId,
      placeName: placeId,
      visitedAt: at,
    );

void main() {
  group('StampTier', () {
    test('picks highest reached tier', () {
      expect(StampTier.forStamps(0), StampTier.doenerneuling);
      expect(StampTier.forStamps(4), StampTier.doenerneuling);
      expect(StampTier.forStamps(5), StampTier.doenerfreund);
      expect(StampTier.forStamps(99), StampTier.doenermeister);
      expect(StampTier.forStamps(500), StampTier.doenerlegende);
      expect(StampTier.doenerlegende.nextTier, isNull);
    });
  });

  group('ProfileStats', () {
    test('counts places, cities and achievements', () {
      final base = DateTime(2026, 5, 1, 12);
      final visits = [
        for (var i = 0; i < 5; i++) _visit('a', base.add(Duration(days: i))),
        for (var i = 0; i < 4; i++) _visit('berlin$i', base),
        _visit('berlin4', DateTime(2026, 5, 2, 23)),
      ];
      final stats = ProfileStats.compute(
        visits: visits,
        reviewCount: 1,
        cityOf: (id) => id.startsWith('berlin') ? 'Berlin' : 'Freiburg',
      );
      expect(stats.totalVisits, 10);
      expect(stats.uniquePlaces, 6);
      expect(stats.maxVisitsToSamePlace, 5);
      expect(stats.uniquePlacesByCity, {'Freiburg': 1, 'Berlin': 5});
      expect(stats.stampTier, StampTier.doenerfreund);
      expect(stats.stampsToNextTier, 5);
      expect(stats.stampProgress, closeTo(0.5, 1e-9));
      expect(
        stats.unlockedAchievements(friendsCount: 5),
        {
          AchievementType.firstBite,
          AchievementType.critic,
          AchievementType.regular,
          AchievementType.berlinTour,
          AchievementType.nightOwl,
          AchievementType.socialButterfly,
        },
      );
    });

    test('empty stats unlock nothing', () {
      const stats = ProfileStats();
      expect(stats.unlockedAchievements(friendsCount: 0), isEmpty);
      expect(stats.stampProgress, 0);
    });
  });

  group('Validation', () {
    test('email', () {
      expect(Validation.isValidEmail(' Robin@Example.org '), isTrue);
      expect(Validation.normalizeEmail(' Robin@Example.org '), 'robin@example.org');
      expect(Validation.isValidEmail('no-at-sign'), isFalse);
      expect(Validation.isValidEmail('a@b'), isFalse);
    });

    test('display name and ratings', () {
      expect(Validation.displayNameError(' R '), isNotNull);
      expect(Validation.displayNameError('Robin'), isNull);
      expect(Validation.isGeneratedName(' Döner-Fan-4821 '), isTrue);
      expect(Validation.isGeneratedName('Döner-Fan-Robin'), isFalse);
      expect(Validation.displayNameError('Döner-Fan-4821'), isNotNull, reason: 'the placeholder is not a chosen name');
      expect(Validation.isValidRating(null), isTrue);
      expect(Validation.isValidRating(0), isFalse);
      expect(Validation.isValidRating(5), isTrue);
      expect(Validation.clean('  '), isNull);
    });

    test('photo types', () {
      expect(Validation.photoType([0xff, 0xd8, 0xff, 0xe0]), 'image/jpeg');
      expect(Validation.photoType([0x89, 0x50, 0x4e, 0x47, 0x0d]), 'image/png');
      expect(Validation.photoType([...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBP'.codeUnits]), 'image/webp');
      expect(Validation.photoType('GIF89a'.codeUnits), isNull);
      expect(Validation.photoType([0xff]), isNull);
    });
  });

  test('DTO JSON roundtrip', () {
    final item = FeedItem(
      id: '1',
      type: FeedItemType.review,
      user: const UserDto(id: 'u', displayName: 'Robin'),
      place: const PlaceDto(placeId: 'p', name: 'Laden', latitude: 48, longitude: 7.8, avgRating: 4),
      timestamp: DateTime.utc(2026, 9, 1, 12, 0, 0, 123, 456),
      fromFriend: true,
      ratings: const {RatingItem.sauce: 5, RatingItem.falafel: 4},
      photoId: 'photo',
      onSite: true,
    );
    final page = FeedPage.fromJson(FeedPage(items: [item], cursor: 'c', hasMore: true).toJson());
    expect(page.items.single.timestamp, item.timestamp);
    expect(page.items.single.place.avgRating, 4.0);
    expect(page.items.single.type, FeedItemType.review);
    expect(page.items.single.fromFriend, isTrue);
    expect(page.items.single.ratings, item.ratings);
    expect((page.items.single.photoId, page.items.single.onSite), ('photo', true));

    final ranking = RankingDto.fromJson(RankingDto(
      city: 'Freiburg im Breisgau',
      by: const RankBy.item(RatingItem.sauce),
      entries: [
        RankingEntryDto(
          place: item.place,
          average: 4,
          count: 2,
          friends: [FriendRatingDto(user: item.user, rating: 5)],
        ),
      ],
    ).toJson());
    expect(ranking.by, const RankBy.item(RatingItem.sauce));
    expect(ranking.entries.single.average, 4.0);
    expect(ranking.entries.single.friends.single.user.displayName, 'Robin');
  });

  test('weighted rating pulls places with few reviews towards the mean', () {
    const mean = 3.5;
    final single = weightedRating(5, 1, mean);
    final many = weightedRating(4.5, 10, mean);
    expect(single, closeTo((5 + 3 * mean) / 4, 1e-9));
    expect(many, greaterThan(single), reason: 'ten 4.5s beat a single 5');
    expect(weightedRating(mean, 7, mean), closeTo(mean, 1e-9));
  });

  group('menu', () {
    test('diets eat what suits them', () {
      expect(Diet.all.allows(Diet.all), isTrue);
      expect(Diet.vegetarian.allows(RatingItem.halloumi.diet), isTrue);
      expect(Diet.vegetarian.allows(RatingItem.fleisch.diet), isFalse);
      expect(Diet.vegan.allows(RatingItem.ayran.diet), isFalse);
      expect(Diet.vegan.allows(RatingItem.hummus.diet), isTrue);
      expect(FoodItem.forDiet(Diet.vegan).map((f) => f.id), ['falafel', 'veganDoener', 'pommes']);
    });

    test('main scores need the dish they are about', () {
      const ratings = {RatingItem.sauce: 5, RatingItem.fleisch: 4, RatingItem.brot: 3, RatingItem.ayran: 1};
      expect(Diet.all.score(ratings), 4, reason: 'ayran is no part of the Döner');
      expect(Diet.vegan.score(ratings), isNull);
      expect(Diet.all.score(const {RatingItem.brot: 5}), isNull, reason: 'bread alone is no Döner rating');
      expect(Diet.vegan.score(const {RatingItem.falafel: 4, RatingItem.hummus: 5, RatingItem.brot: 3}), 4);
      expect(Diet.vegetarian.score(const {RatingItem.halloumi: 5, RatingItem.sauce: 3}), 4);
    });

    test('headline falls back to what the review is about', () {
      const vegan = {RatingItem.veganDoener: 5, RatingItem.brot: 3};
      expect(Diet.all.headline(vegan), 4, reason: 'no Döner score, so the vegan one');
      expect(Diet.all.headline(const {RatingItem.pizza: 2, RatingItem.ayran: 5}), 2, reason: 'drinks only count alone');
      expect(Diet.all.headline(const {RatingItem.ayran: 5}), 5);
      expect(Diet.vegan.headline(const {}), isNull);
      expect(Diet.vegan.headline(const {RatingItem.sauce: 5, RatingItem.fleisch: 4}), isNull, reason: 'nothing vegan in it');
      expect(Diet.vegetarian.headline(const {RatingItem.fleisch: 2, RatingItem.sauce: 4}), 4, reason: 'only the sauce fits');
    });

    test('reviews from before the single items keep their overall score', () {
      final legacy = ReviewDto(
        id: 'r',
        userId: 'u',
        userName: 'Robin',
        placeId: 'p',
        placeName: 'Laden',
        rating: 4,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      expect(legacy.headline(Diet.all), 4);
      expect(legacy.headline(Diet.vegan), isNull, reason: 'an overall score was about the Döner');

      final setByHand = ReviewDto(
        id: 'r',
        userId: 'u',
        userName: 'Robin',
        placeId: 'p',
        placeName: 'Laden',
        rating: 5,
        ratings: const {RatingItem.sauce: 3, RatingItem.fleisch: 3},
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      expect(setByHand.headline(Diet.all), 5, reason: 'the score that counts for the place and the ranking');
    });

    test('rankings per diet', () {
      expect(RankBy.forDiet(Diet.vegan).first, const RankBy.score(Diet.vegan));
      expect(RankBy.forDiet(Diet.vegetarian).map((r) => r.key), isNot(contains('fleisch')));
      expect(RankBy.forDiet(Diet.all).first.key, 'overall', reason: 'the key older apps send');
      for (final diet in Diet.values) {
        for (final by in RankBy.forDiet(diet)) {
          expect(RankBy.parse(by.key), by);
        }
      }
      expect(RankBy.parse('zwiebel'), isNull);
      expect(RankBy.parse('all'), isNull);
    });
  });

  test('review JSON keeps sauce, meat and bread where older apps read them', () {
    final review = ReviewDto(
      id: 'r',
      userId: 'u',
      userName: 'Robin',
      placeId: 'p',
      placeName: 'Laden',
      rating: 4,
      ratings: const {RatingItem.sauce: 5, RatingItem.brot: 3, RatingItem.ayran: 5},
      ayranHomemade: true,
      ingredients: const [Ingredient.granatapfel, Ingredient.mais],
      meat: Meat.kalb,
      createdAt: DateTime.utc(2026, 10, 4),
      updatedAt: DateTime.utc(2026, 10, 4),
    );
    final json = review.toJson();
    expect(json['sauceRating'], 5);
    expect(json['items'], {'ayran': 5});
    final back = ReviewDto.fromJson(json);
    expect(back.ratings, review.ratings);
    expect(back.ingredients, review.ingredients);
    expect(back.meat, Meat.kalb);

    final legacy = ReviewDto.fromJson({...json}..remove('items')..remove('ingredients')..remove('meat'));
    expect(legacy.ratings, {RatingItem.sauce: 5, RatingItem.brot: 3}, reason: 'reviews stored by older builds');
    expect(() => UpsertReviewRequest.fromJson({'items': {'zwiebel': 3}}), throwsArgumentError);
  });

  test('account settings default for profiles cached by older builds', () {
    final account = AccountDto.fromJson(const {'id': 'u', 'displayName': 'Robin'});
    expect(account.diet, Diet.all);
    expect(account.expertMode, isFalse);
    expect(const UpdateMeRequest(diet: Diet.vegan).toJson(), {'diet': 'vegan'});
  });
}
