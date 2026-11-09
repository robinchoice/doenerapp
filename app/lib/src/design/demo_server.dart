import 'dart:convert';

import 'package:doener_models/doener_models.dart';
import 'package:http/http.dart' as http;

/// Made-up API answers for the design studio, so every screen has something
/// to show without a server or an account.
class DemoServer {
  static const me = AccountDto(id: 'u1', displayName: 'Robin');
  static const _tom = UserDto(id: 'u2', displayName: 'Tom', reviewedPlaces: 14);
  static const _ina = UserDto(id: 'u3', displayName: 'Ina', reviewedPlaces: 3);
  static const _mo = UserDto(id: 'u4', displayName: 'Mo', reviewedPlaces: 31);

  static const places = [
    PlaceDto(
      placeId: 'p1',
      name: 'Bosporus Grill',
      latitude: 47.9965,
      longitude: 7.8495,
      address: 'Bertoldstraße 12',
      city: 'Freiburg im Breisgau',
      openingHours: 'Mo–So 11:00–23:00',
      avgRating: 4.6,
      reviewCount: 23,
      avgVegetarian: 4.2,
      vegetarianCount: 9,
      avgVegan: 3.9,
      veganCount: 4,
      veganOptions: true,
    ),
    PlaceDto(
      placeId: 'p2',
      name: 'Mardin Döner',
      latitude: 47.9978,
      longitude: 7.8521,
      address: 'Kaiser-Joseph-Straße 201',
      city: 'Freiburg im Breisgau',
      avgRating: 4.3,
      reviewCount: 17,
      avgVegetarian: 4.0,
      vegetarianCount: 5,
      veganOptions: false,
    ),
    PlaceDto(
      placeId: 'p3',
      name: 'Yufka-Ecke',
      latitude: 47.9951,
      longitude: 7.8462,
      address: 'Rempartstraße 3',
      city: 'Freiburg im Breisgau',
      avgRating: 3.9,
      reviewCount: 8,
      avgVegan: 4.4,
      veganCount: 6,
      veganOptions: true,
    ),
    PlaceDto(placeId: 'p4', name: 'Anatolia Grill', latitude: 47.9990, longitude: 7.8440, city: 'Freiburg im Breisgau'),
  ];

  final _start = DateTime.now().toUtc();

  Future<http.Response> handle(http.Request request) async {
    http.Response json(Object? body) =>
        http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    final path = request.url.path.replaceFirst('/api/v1', '');
    final now = _start;
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    PlaceDto place(String id) => places.firstWhere((p) => p.placeId == id, orElse: () => places.first);

    final reviews = [
      _review('r1', _tom, places[0], 4.8, 'Die Soße ist der Wahnsinn, Brot frisch aus dem Ofen.', now.subtract(const Duration(hours: 3))),
      _review('r2', _ina, places[0], 4.4, 'Viel Salat, faire Preise.', now.subtract(const Duration(days: 2))),
      _review('r3', _mo, places[1], 4.1, null, now.subtract(const Duration(days: 4))),
    ];
    final myReviews = [_review('m1', me, places[0], 4.7, 'Mein Stammladen.', now.subtract(const Duration(days: 6)))];
    final myVisits = [
      VisitDto(id: 'v1', userId: me.id, userName: me.displayName, placeId: 'p1', placeName: places[0].name, visitedAt: now.subtract(const Duration(days: 1)), foodType: 'doener'),
      VisitDto(id: 'v2', userId: me.id, userName: me.displayName, placeId: 'p2', placeName: places[1].name, visitedAt: now.subtract(const Duration(days: 5)), foodType: 'yufka'),
    ];

    if (request.method == 'POST' && path.endsWith('/visits')) {
      final body = CreateVisitRequest.fromJson(jsonDecode(request.body) as Map<String, dynamic>);
      final p = place(segments[1]);
      return json(VisitDto(id: body.id, userId: me.id, userName: me.displayName, placeId: p.placeId, placeName: p.name, visitedAt: body.visitedAt, foodType: body.foodType).toJson());
    }
    if (request.method == 'PUT' && path.endsWith('/review')) return json(myReviews.first.toJson());

    if (segments.length == 2 && segments[0] == 'places' && !const ['top', 'new', 'trending', 'search'].contains(segments[1])) {
      return json(place(segments[1]).toJson());
    }
    if (segments.length == 3 && segments[0] == 'places' && segments[2] == 'summary') {
      return json(const PlaceSummaryDto(
        items: {
          RatingItem.sauce: ItemAverage(4.7, 21),
          RatingItem.fleisch: ItemAverage(4.5, 19),
          RatingItem.salat: ItemAverage(4.2, 20),
          RatingItem.brot: ItemAverage(4.8, 22),
        },
        ayranHomemade: true,
        price: 750,
        experts: 0,
        awards: [AwardDto(year: 2025, category: BestOfCategory.overall, rank: 1, average: 4.6, count: 23, city: 'Freiburg im Breisgau', path: '/bestenliste/freiburg-im-breisgau/2025')],
      ).toJson());
    }
    if (segments.length == 3 && segments[0] == 'places' && segments[2] == 'reviews') {
      return json([for (final r in reviews) if (r.placeId == segments[1]) r.toJson()]);
    }
    if (segments.length == 3 && segments[0] == 'users' && segments[2] == 'profile') {
      final user = [_tom, _ina, _mo].firstWhere((u) => u.id == segments[1], orElse: () => me);
      return json(ProfileDto(
        user: user,
        since: DateTime(2026, 4, 12),
        reviews: [for (final r in reviews) if (r.userId == user.id) r],
        checkIns: 12,
        visits: const [],
      ).toJson());
    }

    return switch (path) {
      '/auth/verify' => json(const AuthResponse(token: 'demo', user: me, isNewUser: false).toJson()),
      '/auth/me' || '/users/me' => json(me.toJson()),
      '/me/inbox' => json(InboxDto(seenAt: now.subtract(const Duration(hours: 1)), items: [
          InboxItemDto(type: 'friend_visit', id: 'i1', timestamp: now, title: 'Tom hat bei Bosporus Grill eingecheckt', placeId: 'p1', userId: 'u2', userName: 'Tom'),
          InboxItemDto(type: 'news', id: 'n1', timestamp: now.subtract(const Duration(days: 2)), title: 'Neu bei Lieblingsdöner', body: 'Die Glocke'),
        ]).toJson()),
      '/updates/current' => json(const UpdateDto(id: 'n1', title: 'Neuigkeiten in der App', features: ['Bewerten per Wischen über die Gabeln', 'Die Glocke auf Start']).toJson()),
      '/places/new' => json(NewPlacesDto(
          opened: [PlaceDto(placeId: 'p4', name: 'Anatolia Grill', latitude: 47.999, longitude: 7.844, city: 'Freiburg', openedOn: now.subtract(const Duration(days: 5)))],
          upcoming: const [PlaceDto(placeId: 'p5', name: 'Grillhaus Dreisam', latitude: 47.99, longitude: 7.87, opensOn: '2026-12')],
        ).toJson()),
      '/places/top' || '/places/trending' || '/places' || '/me/places' || '/places/search' => json([for (final p in places) p.toJson()]),
      '/feed' => json(FeedPage(hasMore: false, items: [
          FeedItem(id: 'f1', type: FeedItemType.visit, user: _tom, place: places[0], timestamp: now.subtract(const Duration(minutes: 20)), fromFriend: true, foodType: 'yufka'),
          FeedItem(id: 'f2', type: FeedItemType.review, user: _ina, place: places[0], timestamp: now.subtract(const Duration(hours: 5)), fromFriend: true, rating: 4.4, ratings: const {RatingItem.sauce: 4.5, RatingItem.brot: 5}, text: 'Viel Salat, faire Preise.'),
          FeedItem(id: 'f3', type: FeedItemType.review, user: _mo, place: places[1], timestamp: now.subtract(const Duration(days: 1)), fromFriend: false, rating: 4.1, ratings: const {RatingItem.fleisch: 4}),
        ]).toJson()),
      '/feed/live' => json([LiveStatusDto(user: _tom, placeId: 'p1', placeName: places[0].name, foodType: 'yufka', until: now.add(const Duration(minutes: 40))).toJson()]),
      '/ranking' => json(RankingDto(
          city: 'Freiburg im Breisgau',
          by: RankBy.parse(request.url.queryParameters['by'] ?? '') ?? RankBy.score(Diet.all),
          entries: [
            RankingEntryDto(place: places[0], average: 4.6, count: 23, friends: const [FriendRatingDto(user: _tom, rating: 5)]),
            RankingEntryDto(place: places[1], average: 4.3, count: 17),
            RankingEntryDto(place: places[2], average: 3.9, count: 8),
          ],
          bestOf: const BestOfDto(year: 2025, city: 'Freiburg im Breisgau', category: BestOfCategory.overall, path: '/bestenliste/freiburg-im-breisgau/2025', entries: [
            BestOfEntryDto(rank: 1, placeId: 'p1', name: 'Bosporus Grill'),
            BestOfEntryDto(rank: 2, placeId: 'p2', name: 'Mardin Döner'),
            BestOfEntryDto(rank: 3, placeId: 'p3', name: 'Yufka-Ecke'),
          ]),
        ).toJson()),
      '/friends' => json([
          FriendshipDto(id: 'fr1', user: _tom, status: FriendshipStatus.accepted, direction: FriendshipDirection.outgoing, createdAt: now).toJson(),
          FriendshipDto(id: 'fr2', user: _ina, status: FriendshipStatus.accepted, direction: FriendshipDirection.incoming, createdAt: now).toJson(),
          FriendshipDto(id: 'fr3', user: _mo, status: FriendshipStatus.pending, direction: FriendshipDirection.incoming, createdAt: now).toJson(),
        ]),
      '/me/visits' => json([for (final v in myVisits) v.toJson()]),
      '/me/reviews' => json([for (final r in myReviews) r.toJson()]),
      '/me/invite' => json(const InviteDto(code: 'demo', url: 'https://doener-api.pleasance.org/i/demo').toJson()),
      '/cities' => json([const CityDto(name: 'Freiburg im Breisgau', latitude: 47.999, longitude: 7.842, ratedPlaces: 42).toJson()]),
      _ => json(request.method == 'GET' ? [] : {}),
    };
  }

  static ReviewDto _review(String id, UserDto user, PlaceDto place, double rating, String? text, DateTime at) => ReviewDto(
        id: id,
        userId: user.id,
        userName: user.displayName,
        userReviewedPlaces: user.reviewedPlaces,
        placeId: place.placeId,
        placeName: place.name,
        rating: rating,
        ratings: {RatingItem.sauce: rating, RatingItem.fleisch: rating - 0.3, RatingItem.salat: 4, RatingItem.brot: 5},
        text: text,
        onSite: true,
        regular: id == 'm1',
        createdAt: at,
        updatedAt: at,
      );
}
