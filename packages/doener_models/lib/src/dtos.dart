import 'menu.dart';

typedef Json = Map<String, dynamic>;

DateTime _date(Object? v) => DateTime.parse(v as String);
double? _doubleOrNull(Object? v) => (v as num?)?.toDouble();
DateTime? _dateOrNull(Object? v) => v == null ? null : DateTime.parse(v as String);
T? _enumOrNull<T extends Enum>(List<T> values, Object? name) => name == null ? null : values.byName(name as String);

Map<RatingItem, T> _itemMap<T>(Object? json, T Function(Object? value) value) => {
      for (final e in ((json as Map?) ?? const {}).entries) RatingItem.values.byName(e.key as String): value(e.value),
    };

/// Ratings go in half steps. Shipped clients read whole numbers from
/// `sauceRating`, `fleischRating`, `brotRating` and `items` (sauce, meat and
/// bread as fields of their own, as before there were other items), so those
/// carry rounded values and `ratings` the exact ones. [RatingItem.newItems]
/// go in `newRatings`, see there.
Map<RatingItem, double> _ratingsFromJson(Json j) => {
      ...j['ratings'] is Map
          ? _itemMap(j['ratings'], (v) => (v as num).toDouble())
          : {
              RatingItem.sauce: ?_doubleOrNull(j['sauceRating']),
              RatingItem.fleisch: ?_doubleOrNull(j['fleischRating']),
              RatingItem.brot: ?_doubleOrNull(j['brotRating']),
              ..._itemMap(j['items'], (v) => (v as num).toDouble()),
            },
      ..._itemMap(j['newRatings'], (v) => (v as num).toDouble()),
    };

Json _ratingsToJson(Map<RatingItem, double> ratings) => {
      'sauceRating': ratings[RatingItem.sauce]?.round(),
      'fleischRating': ratings[RatingItem.fleisch]?.round(),
      'brotRating': ratings[RatingItem.brot]?.round(),
      'items': {
        for (final e in ratings.entries)
          if (!RatingItem.classicItems.contains(e.key) && !RatingItem.newItems.contains(e.key)) e.key.name: e.value.round(),
      },
      'ratings': {for (final e in ratings.entries) if (!RatingItem.newItems.contains(e.key)) e.key.name: e.value},
      'newRatings': {for (final e in ratings.entries) if (RatingItem.newItems.contains(e.key)) e.key.name: e.value},
    };

/// A score in half steps: `score` exact, `rating` rounded for shipped clients.
double? _scoreFromJson(Json j) => _doubleOrNull(j.containsKey('score') ? j['score'] : j['rating']);

List<Ingredient>? _ingredientsFromJson(Object? v) =>
    v == null ? null : [for (final name in v as List) Ingredient.values.byName(name as String)];

// MARK: - Auth

/// [inviteCode] of a friend's link lets a new address in while sign-up is closed.
class LoginRequest {
  final String email;
  final String? inviteCode;
  const LoginRequest({required this.email, this.inviteCode});

  factory LoginRequest.fromJson(Json j) => LoginRequest(email: j['email'] as String, inviteCode: j['inviteCode'] as String?);
  Json toJson() => {'email': email, if (inviteCode != null) 'inviteCode': inviteCode};
}

/// An admin creates the account of a tester while sign-up is closed.
/// An admin lets a tester in. With [platform] `ios`, the address also gets a TestFlight invite.
class InviteRequest {
  final String email;
  final String? platform;
  const InviteRequest({required this.email, this.platform});

  factory InviteRequest.fromJson(Json j) => InviteRequest(email: j['email'] as String, platform: j['platform'] as String?);
  Json toJson() => {'email': email, 'platform': ?platform};
}

/// What an invite did: [testFlight] is null without an iPhone, false if Apple refused or isn't set up.
class InviteResult {
  final bool? testFlight;
  const InviteResult({this.testFlight});

  factory InviteResult.fromJson(Json j) => InviteResult(testFlight: j['testFlight'] as bool?);
  Json toJson() => {'testFlight': testFlight};
}

/// A request from the landing page to join the test, for admins. [invitedBy]
/// is the friend whose invite link brought the person there.
class TesterRequestDto {
  final String id;
  final String email;

  /// `ios` or `android`.
  final String platform;
  final String? invitedBy;
  final DateTime createdAt;

  const TesterRequestDto({required this.id, required this.email, required this.platform, this.invitedBy, required this.createdAt});

  factory TesterRequestDto.fromJson(Json j) => TesterRequestDto(
        id: j['id'] as String,
        email: j['email'] as String,
        platform: j['platform'] as String,
        invitedBy: j['invitedBy'] as String?,
        createdAt: _date(j['createdAt']),
      );

  Json toJson() => {
        'id': id,
        'email': email,
        'platform': platform,
        'invitedBy': invitedBy,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };
}

/// Either [email] + [code] (typed in by the user) or [token] (from the
/// magic link) must be set. [inviteCode] remembers whose invite link brought
/// a new account in.
class VerifyRequest {
  final String? email;
  final String? code;
  final String? token;
  final String? inviteCode;
  const VerifyRequest({this.email, this.code, this.token, this.inviteCode});

  factory VerifyRequest.fromJson(Json j) => VerifyRequest(
        email: j['email'] as String?,
        code: j['code'] as String?,
        token: j['token'] as String?,
        inviteCode: j['inviteCode'] as String?,
      );
  Json toJson() => {'email': email, 'code': code, 'token': token, 'inviteCode': inviteCode};
}

class AuthResponse {
  final String token;
  final AccountDto user;
  final bool isNewUser;
  const AuthResponse({required this.token, required this.user, required this.isNewUser});

  factory AuthResponse.fromJson(Json j) => AuthResponse(
        token: j['token'] as String,
        user: AccountDto.fromJson(j['user'] as Json),
        isNewUser: j['isNewUser'] as bool,
      );
  Json toJson() => {'token': token, 'user': user.toJson(), 'isNewUser': isNewUser};
}

/// Changes only what is set.
class UpdateMeRequest {
  final String? displayName;
  final Diet? diet;
  final bool? expertMode;
  const UpdateMeRequest({this.displayName, this.diet, this.expertMode});

  factory UpdateMeRequest.fromJson(Json j) => UpdateMeRequest(
        displayName: j['displayName'] as String?,
        diet: _enumOrNull(Diet.values, j['diet']),
        expertMode: j['expertMode'] as bool?,
      );
  Json toJson() => {'displayName': ?displayName, 'diet': ?diet?.name, 'expertMode': ?expertMode};
}

// MARK: - User

class UserDto {
  final String id;
  final String displayName;
  const UserDto({required this.id, required this.displayName});

  factory UserDto.fromJson(Json j) => UserDto(id: j['id'] as String, displayName: j['displayName'] as String);
  Json toJson() => {'id': id, 'displayName': displayName};

  @override
  bool operator ==(Object other) => other is UserDto && other.id == id && other.displayName == displayName;
  @override
  int get hashCode => Object.hash(id, displayName);
}

/// The signed-in user with the settings that follow the account.
class AccountDto extends UserDto {
  final Diet diet;

  /// Asks and shows what "mit allem" means, meat, skewer and bread.
  final bool expertMode;

  /// May invite testers while sign-up is closed (`ADMIN_EMAILS` on the server).
  final bool admin;

  const AccountDto({
    required super.id,
    required super.displayName,
    this.diet = Diet.all,
    this.expertMode = false,
    this.admin = false,
  });

  factory AccountDto.fromJson(Json j) => AccountDto(
        id: j['id'] as String,
        displayName: j['displayName'] as String,
        diet: _enumOrNull(Diet.values, j['diet']) ?? Diet.all,
        expertMode: j['expertMode'] as bool? ?? false,
        admin: j['admin'] as bool? ?? false,
      );
  @override
  Json toJson() => {...super.toJson(), 'diet': diet.name, 'expertMode': expertMode, 'admin': admin};
}

// MARK: - Place

/// [placeId] is the Google Place ID — the only place identifier clients see.
/// [avgRating] and [reviewCount] are the Döner score, next to them the
/// scores for vegetarians and vegans.
class PlaceDto {
  final String placeId;
  final String name;
  final double latitude;
  final double longitude;
  final String? address;
  final String? postalCode;
  final String? city;
  final String? openingHours;
  final double? avgRating;
  final int reviewCount;
  final double? avgVegetarian;
  final int vegetarianCount;
  final double? avgVegan;
  final int veganCount;

  /// What most reviewers say — null if nobody did or it's a tie.
  final bool? veganOptions;

  /// When a place Google had announced opened.
  final DateTime? openedOn;

  /// Announced opening: `YYYY-MM-DD`, or `YYYY-MM` without a day.
  final String? opensOn;

  const PlaceDto({
    required this.placeId,
    required this.name,
    required this.latitude,
    required this.longitude,
    this.address,
    this.postalCode,
    this.city,
    this.openingHours,
    this.avgRating,
    this.reviewCount = 0,
    this.avgVegetarian,
    this.vegetarianCount = 0,
    this.avgVegan,
    this.veganCount = 0,
    this.veganOptions,
    this.openedOn,
    this.opensOn,
  });

  /// Average and count of the main score for [diet].
  ({double? average, int count}) score(Diet diet) => switch (diet) {
        Diet.all => (average: avgRating, count: reviewCount),
        Diet.vegetarian => (average: avgVegetarian, count: vegetarianCount),
        Diet.vegan => (average: avgVegan, count: veganCount),
      };

  factory PlaceDto.fromJson(Json j) => PlaceDto(
        placeId: j['placeId'] as String,
        name: j['name'] as String,
        latitude: (j['latitude'] as num).toDouble(),
        longitude: (j['longitude'] as num).toDouble(),
        address: j['address'] as String?,
        postalCode: j['postalCode'] as String?,
        city: j['city'] as String?,
        openingHours: j['openingHours'] as String?,
        avgRating: _doubleOrNull(j['avgRating']),
        reviewCount: j['reviewCount'] as int? ?? 0,
        avgVegetarian: _doubleOrNull(j['avgVegetarian']),
        vegetarianCount: j['vegetarianCount'] as int? ?? 0,
        avgVegan: _doubleOrNull(j['avgVegan']),
        veganCount: j['veganCount'] as int? ?? 0,
        veganOptions: j['veganOptions'] as bool?,
        openedOn: _dateOrNull(j['openedOn']),
        opensOn: j['opensOn'] as String?,
      );

  Json toJson() => {
        'placeId': placeId,
        'name': name,
        'latitude': latitude,
        'longitude': longitude,
        'address': address,
        'postalCode': postalCode,
        'city': city,
        'openingHours': openingHours,
        'avgRating': avgRating,
        'reviewCount': reviewCount,
        'avgVegetarian': avgVegetarian,
        'vegetarianCount': vegetarianCount,
        'avgVegan': avgVegan,
        'veganCount': veganCount,
        'veganOptions': veganOptions,
        'openedOn': openedOn?.toIso8601String().substring(0, 10),
        'opensOn': opensOn,
      };
}

class ItemAverage {
  final double average;
  final int count;
  const ItemAverage(this.average, this.count);

  factory ItemAverage.fromJson(Json j) => ItemAverage((j['average'] as num).toDouble(), j['count'] as int);
  Json toJson() => {'average': average, 'count': count};
}

/// What the community says about a place, computed from its reviews.
class PlaceSummaryDto {
  final Map<RatingItem, ItemAverage> items;

  /// What most reviewers say — null if nobody did or it's a tie.
  final bool? ayranHomemade;

  /// Median of what reviewers paid for a Döner, in cents.
  final int? price;

  /// What most experts got with "mit allem".
  final List<Ingredient> ingredients;
  final Meat? meat;
  final Skewer? skewer;
  final Bread? bread;

  /// Reviews that told what came with "mit allem".
  final int experts;

  /// The place's seals from the latest best-of lists.
  final List<AwardDto> awards;

  const PlaceSummaryDto({
    this.items = const {},
    this.ayranHomemade,
    this.price,
    this.ingredients = const [],
    this.meat,
    this.skewer,
    this.bread,
    this.experts = 0,
    this.awards = const [],
  });

  List<Ingredient> get specials => [for (final i in ingredients) if (i.isSpecial) i];

  factory PlaceSummaryDto.fromJson(Json j) => PlaceSummaryDto(
        items: {
          ..._itemMap(j['items'], (v) => ItemAverage.fromJson(v as Json)),
          ..._itemMap(j['newItems'], (v) => ItemAverage.fromJson(v as Json)),
        },
        ayranHomemade: j['ayranHomemade'] as bool?,
        price: j['price'] as int?,
        ingredients: _ingredientsFromJson(j['ingredients']) ?? const [],
        meat: _enumOrNull(Meat.values, j['meat']),
        skewer: _enumOrNull(Skewer.values, j['skewer']),
        bread: _enumOrNull(Bread.values, j['bread']),
        experts: j['experts'] as int,
        awards: [for (final a in (j['awards'] as List?) ?? const []) AwardDto.fromJson(a as Json)],
      );

  Json toJson() => {
        // Shipped clients fail on items they don't know, see RatingItem.newItems.
        'items': {for (final e in items.entries) if (!RatingItem.newItems.contains(e.key)) e.key.name: e.value.toJson()},
        'newItems': {for (final e in items.entries) if (RatingItem.newItems.contains(e.key)) e.key.name: e.value.toJson()},
        'ayranHomemade': ayranHomemade,
        'price': price,
        'ingredients': [for (final i in ingredients) i.name],
        'meat': meat?.name,
        'skewer': skewer?.name,
        'bread': bread?.name,
        'experts': experts,
        'awards': [for (final a in awards) a.toJson()],
      };
}

// MARK: - Review

/// Days with a check-in at a place that make the reviewer a regular there.
const regularVisits = 3;

/// [rating] is the Döner score, derived from sauce, meat and bread — null for
/// reviews about other food. Facts like [veganOptions] describe the place.
class ReviewDto {
  final String id;
  final String userId;
  final String userName;
  final String placeId;
  final String placeName;
  final double? rating;
  final Map<RatingItem, double> ratings;
  final bool? veganOptions;
  final bool? ayranHomemade;

  /// What the Döner cost, in cents.
  final int? price;
  final List<Ingredient>? ingredients;
  final Meat? meat;
  final Skewer? skewer;
  final Bread? bread;
  final String? text;

  /// Served at `/photos/<photoId>`; a new photo gets a new id.
  final String? photoId;

  /// The reviewer has checked in at the place, as a [regular] on at least [regularVisits] days.
  final bool onSite;
  final bool regular;
  final DateTime createdAt;
  final DateTime updatedAt;

  const ReviewDto({
    required this.id,
    required this.userId,
    required this.userName,
    required this.placeId,
    required this.placeName,
    this.rating,
    this.ratings = const {},
    this.veganOptions,
    this.ayranHomemade,
    this.price,
    this.ingredients,
    this.meat,
    this.skewer,
    this.bread,
    this.text,
    this.photoId,
    this.onSite = false,
    this.regular = false,
    required this.createdAt,
    required this.updatedAt,
  });

  /// What the review shows to someone with [diet]. For the Döner the stored
  /// [rating] counts: older reviews may only have that one, or one set by hand.
  double? headline(Diet diet) => diet == Diet.all && rating != null ? rating! : diet.headline(ratings);

  factory ReviewDto.fromJson(Json j) => ReviewDto(
        id: j['id'] as String,
        userId: j['userId'] as String,
        userName: j['userName'] as String,
        placeId: j['placeId'] as String,
        placeName: j['placeName'] as String,
        rating: _scoreFromJson(j),
        ratings: _ratingsFromJson(j),
        veganOptions: j['veganOptions'] as bool?,
        ayranHomemade: j['ayranHomemade'] as bool?,
        price: j['price'] as int?,
        ingredients: _ingredientsFromJson(j['ingredients']),
        meat: _enumOrNull(Meat.values, j['meat']),
        skewer: _enumOrNull(Skewer.values, j['skewer']),
        bread: _enumOrNull(Bread.values, j['bread']),
        text: j['text'] as String?,
        photoId: j['photoId'] as String?,
        onSite: j['onSite'] as bool? ?? false,
        regular: j['regular'] as bool? ?? false,
        createdAt: _date(j['createdAt']),
        updatedAt: _date(j['updatedAt']),
      );

  Json toJson() => {
        'id': id,
        'userId': userId,
        'userName': userName,
        'placeId': placeId,
        'placeName': placeName,
        'rating': rating?.round(),
        'score': rating,
        ..._ratingsToJson(ratings),
        'veganOptions': veganOptions,
        'ayranHomemade': ayranHomemade,
        'price': price,
        'ingredients': ingredients == null ? null : [for (final i in ingredients!) i.name],
        'meat': meat?.name,
        'skewer': skewer?.name,
        'bread': bread?.name,
        'text': text,
        'photoId': photoId,
        'onSite': onSite,
        'regular': regular,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };
}

/// One review per user and place — PUT replaces the previous one. The scores
/// are derived on the server.
class UpsertReviewRequest {
  final Map<RatingItem, double> ratings;
  final bool? veganOptions;
  final bool? ayranHomemade;

  /// What the Döner cost, in cents.
  final int? price;

  /// Set by experts: what came with "mit allem".
  final List<Ingredient>? ingredients;
  final Meat? meat;
  final Skewer? skewer;
  final Bread? bread;
  final String? text;

  /// A new photo (JPEG, PNG or WebP). Without it, the previous photo stays
  /// unless [removePhoto] is set.
  final String? photoBase64;
  final bool removePhoto;

  const UpsertReviewRequest({
    this.ratings = const {},
    this.veganOptions,
    this.ayranHomemade,
    this.price,
    this.ingredients,
    this.meat,
    this.skewer,
    this.bread,
    this.text,
    this.photoBase64,
    this.removePhoto = false,
  });

  factory UpsertReviewRequest.fromJson(Json j) => UpsertReviewRequest(
        ratings: _ratingsFromJson(j),
        veganOptions: j['veganOptions'] as bool?,
        ayranHomemade: j['ayranHomemade'] as bool?,
        price: j['price'] as int?,
        ingredients: _ingredientsFromJson(j['ingredients']),
        meat: _enumOrNull(Meat.values, j['meat']),
        skewer: _enumOrNull(Skewer.values, j['skewer']),
        bread: _enumOrNull(Bread.values, j['bread']),
        text: j['text'] as String?,
        photoBase64: j['photoBase64'] as String?,
        removePhoto: j['removePhoto'] as bool? ?? false,
      );

  Json toJson() => {
        ..._ratingsToJson(ratings),
        'veganOptions': veganOptions,
        'ayranHomemade': ayranHomemade,
        'price': price,
        'ingredients': ingredients == null ? null : [for (final i in ingredients!) i.name],
        'meat': meat?.name,
        'skewer': skewer?.name,
        'bread': bread?.name,
        'text': text,
        'photoBase64': photoBase64,
        'removePhoto': removePhoto,
      };
}

// MARK: - Visit

class VisitDto {
  final String id;
  final String userId;
  final String userName;
  final String placeId;
  final String placeName;
  final DateTime visitedAt;
  final String? foodType;

  const VisitDto({
    required this.id,
    required this.userId,
    required this.userName,
    required this.placeId,
    required this.placeName,
    required this.visitedAt,
    this.foodType,
  });

  factory VisitDto.fromJson(Json j) => VisitDto(
        id: j['id'] as String,
        userId: j['userId'] as String,
        userName: j['userName'] as String,
        placeId: j['placeId'] as String,
        placeName: j['placeName'] as String,
        visitedAt: _date(j['visitedAt']),
        foodType: j['foodType'] as String?,
      );

  Json toJson() => {
        'id': id,
        'userId': userId,
        'userName': userName,
        'placeId': placeId,
        'placeName': placeName,
        'visitedAt': visitedAt.toUtc().toIso8601String(),
        'foodType': foodType,
      };
}

/// [id] is generated on the client so offline retries are idempotent.
class CreateVisitRequest {
  final String id;
  final DateTime visitedAt;
  final String? foodType;

  const CreateVisitRequest({required this.id, required this.visitedAt, this.foodType});

  factory CreateVisitRequest.fromJson(Json j) => CreateVisitRequest(
        id: j['id'] as String,
        visitedAt: _date(j['visitedAt']),
        foodType: j['foodType'] as String?,
      );

  Json toJson() => {
        'id': id,
        'visitedAt': visitedAt.toUtc().toIso8601String(),
        'foodType': foodType,
      };
}

// MARK: - Feed

enum FeedItemType { visit, review }

/// Check-ins come from friends only; reviews from friends and from everyone
/// around — [fromFriend] tells them apart.
class FeedItem {
  final String id;
  final FeedItemType type;
  final UserDto user;
  final PlaceDto place;
  final DateTime timestamp;
  final bool fromFriend;

  /// The review's Döner score, the only one reviews from before the single items have.
  final double? rating;
  final Map<RatingItem, double> ratings;
  final String? text;
  final String? foodType;

  /// See [ReviewDto.photoId], [ReviewDto.onSite] and [ReviewDto.regular].
  final String? photoId;
  final bool onSite;
  final bool regular;

  const FeedItem({
    required this.id,
    required this.type,
    required this.user,
    required this.place,
    required this.timestamp,
    required this.fromFriend,
    this.rating,
    this.ratings = const {},
    this.text,
    this.foodType,
    this.photoId,
    this.onSite = false,
    this.regular = false,
  });

  /// See [ReviewDto.headline].
  double? headline(Diet diet) => diet == Diet.all && rating != null ? rating! : diet.headline(ratings);

  factory FeedItem.fromJson(Json j) => FeedItem(
        id: j['id'] as String,
        type: FeedItemType.values.byName(j['type'] as String),
        user: UserDto.fromJson(j['user'] as Json),
        place: PlaceDto.fromJson(j['place'] as Json),
        timestamp: _date(j['timestamp']),
        fromFriend: j['fromFriend'] as bool,
        rating: _scoreFromJson(j),
        ratings: _ratingsFromJson(j),
        text: j['text'] as String?,
        foodType: j['foodType'] as String?,
        photoId: j['photoId'] as String?,
        onSite: j['onSite'] as bool? ?? false,
        regular: j['regular'] as bool? ?? false,
      );

  Json toJson() => {
        'id': id,
        'type': type.name,
        'user': user.toJson(),
        'place': place.toJson(),
        'timestamp': timestamp.toUtc().toIso8601String(),
        'fromFriend': fromFriend,
        'rating': rating?.round(),
        'score': rating,
        ..._ratingsToJson(ratings),
        'text': text,
        'foodType': foodType,
        'photoId': photoId,
        'onSite': onSite,
        'regular': regular,
      };
}

class FeedPage {
  final List<FeedItem> items;
  final String? cursor;
  final bool hasMore;

  const FeedPage({required this.items, this.cursor, required this.hasMore});

  factory FeedPage.fromJson(Json j) => FeedPage(
        items: (j['items'] as List).map((e) => FeedItem.fromJson(e as Json)).toList(),
        cursor: j['cursor'] as String?,
        hasMore: j['hasMore'] as bool,
      );

  Json toJson() => {'items': items.map((e) => e.toJson()).toList(), 'cursor': cursor, 'hasMore': hasMore};
}

class LiveStatusDto {
  final UserDto user;
  final String placeId;
  final String placeName;
  final String? foodType;
  final DateTime until;

  const LiveStatusDto({
    required this.user,
    required this.placeId,
    required this.placeName,
    this.foodType,
    required this.until,
  });

  factory LiveStatusDto.fromJson(Json j) => LiveStatusDto(
        user: UserDto.fromJson(j['user'] as Json),
        placeId: j['placeId'] as String,
        placeName: j['placeName'] as String,
        foodType: j['foodType'] as String?,
        until: _date(j['until']),
      );

  Json toJson() => {
        'user': user.toJson(),
        'placeId': placeId,
        'placeName': placeName,
        'foodType': foodType,
        'until': until.toUtc().toIso8601String(),
      };
}

// MARK: - Ranking

/// A friend's rating of a ranked place, in what the ranking sorts by.
class FriendRatingDto {
  final UserDto user;
  final double rating;
  const FriendRatingDto({required this.user, required this.rating});

  factory FriendRatingDto.fromJson(Json j) => FriendRatingDto(user: UserDto.fromJson(j['user'] as Json), rating: _scoreFromJson(j)!);
  Json toJson() => {'user': user.toJson(), 'rating': rating.round(), 'score': rating};
}

/// [average] and [count] are the real numbers; the order comes from [weightedRating].
class RankingEntryDto {
  final PlaceDto place;
  final double average;
  final int count;
  final List<FriendRatingDto> friends;

  /// Median of what reviewers paid for a Döner here, in cents.
  final int? price;

  const RankingEntryDto({required this.place, required this.average, required this.count, this.friends = const [], this.price});

  factory RankingEntryDto.fromJson(Json j) => RankingEntryDto(
        place: PlaceDto.fromJson(j['place'] as Json),
        average: (j['average'] as num).toDouble(),
        count: j['count'] as int,
        friends: (j['friends'] as List).map((e) => FriendRatingDto.fromJson(e as Json)).toList(),
        price: j['price'] as int?,
      );

  Json toJson() => {
        'place': place.toJson(),
        'average': average,
        'count': count,
        'friends': friends.map((e) => e.toJson()).toList(),
        'price': price,
      };
}

/// Places of one [city] (as in their address), best first. [city] is null
/// when no place near the requested position is known.
class RankingDto {
  final String? city;
  final RankBy by;
  final List<RankingEntryDto> entries;

  /// The city's latest best-of list: vegan when ranking by the vegan score, else overall.
  final BestOfDto? bestOf;

  const RankingDto({this.city, required this.by, required this.entries, this.bestOf});

  factory RankingDto.fromJson(Json j) => RankingDto(
        city: j['city'] as String?,
        by: RankBy.parse(j['by'] as String) ?? (throw FormatException('Unknown ranking ${j['by']}')),
        entries: (j['entries'] as List).map((e) => RankingEntryDto.fromJson(e as Json)).toList(),
        bestOf: j['bestOf'] == null ? null : BestOfDto.fromJson(j['bestOf'] as Json),
      );

  Json toJson() => {
        'city': city,
        'by': by.key,
        'entries': entries.map((e) => e.toJson()).toList(),
        if (bestOf != null) 'bestOf': bestOf!.toJson(),
      };
}

// MARK: - Best of

enum BestOfCategory { overall, vegan }

/// A seal: [rank] in the best-of list of [city] for [year]. [average] and
/// [count] are the reviews of that year; [path] is the list's public page.
class AwardDto {
  final int year;
  final String city;
  final BestOfCategory category;
  final int rank;
  final double average;
  final int count;
  final String path;

  const AwardDto({
    required this.year,
    required this.city,
    required this.category,
    required this.rank,
    required this.average,
    required this.count,
    required this.path,
  });

  factory AwardDto.fromJson(Json j) => AwardDto(
        year: j['year'] as int,
        city: j['city'] as String,
        category: BestOfCategory.values.byName(j['category'] as String),
        rank: j['rank'] as int,
        average: (j['average'] as num).toDouble(),
        count: j['count'] as int,
        path: j['path'] as String,
      );

  Json toJson() => {
        'year': year,
        'city': city,
        'category': category.name,
        'rank': rank,
        'average': average,
        'count': count,
        'path': path,
      };
}

class BestOfEntryDto {
  final int rank;
  final String placeId;
  final String name;
  const BestOfEntryDto({required this.rank, required this.placeId, required this.name});

  factory BestOfEntryDto.fromJson(Json j) =>
      BestOfEntryDto(rank: j['rank'] as int, placeId: j['placeId'] as String, name: j['name'] as String);
  Json toJson() => {'rank': rank, 'placeId': placeId, 'name': name};
}

/// The awarded places of a best-of list, best first.
class BestOfDto {
  final int year;
  final String city;
  final BestOfCategory category;
  final String path;
  final List<BestOfEntryDto> entries;

  const BestOfDto({required this.year, required this.city, required this.category, required this.path, required this.entries});

  factory BestOfDto.fromJson(Json j) => BestOfDto(
        year: j['year'] as int,
        city: j['city'] as String,
        category: BestOfCategory.values.byName(j['category'] as String),
        path: j['path'] as String,
        entries: [for (final e in j['entries'] as List) BestOfEntryDto.fromJson(e as Json)],
      );

  Json toJson() => {
        'year': year,
        'city': city,
        'category': category.name,
        'path': path,
        'entries': [for (final e in entries) e.toJson()],
      };
}

/// Around a position: places that opened lately (newest first) and openings
/// Google announced.
class NewPlacesDto {
  final List<PlaceDto> opened;
  final List<PlaceDto> upcoming;
  const NewPlacesDto({this.opened = const [], this.upcoming = const []});

  factory NewPlacesDto.fromJson(Json j) => NewPlacesDto(
        opened: [for (final p in j['opened'] as List) PlaceDto.fromJson(p as Json)],
        upcoming: [for (final p in j['upcoming'] as List) PlaceDto.fromJson(p as Json)],
      );

  Json toJson() => {'opened': [for (final p in opened) p.toJson()], 'upcoming': [for (final p in upcoming) p.toJson()]};
}

// MARK: - Friends

enum FriendshipStatus { pending, accepted }

enum FriendshipDirection { incoming, outgoing }

class FriendshipDto {
  final String id;
  final UserDto user;
  final FriendshipStatus status;
  final FriendshipDirection direction;
  final DateTime createdAt;

  const FriendshipDto({
    required this.id,
    required this.user,
    required this.status,
    required this.direction,
    required this.createdAt,
  });

  factory FriendshipDto.fromJson(Json j) => FriendshipDto(
        id: j['id'] as String,
        user: UserDto.fromJson(j['user'] as Json),
        status: FriendshipStatus.values.byName(j['status'] as String),
        direction: FriendshipDirection.values.byName(j['direction'] as String),
        createdAt: _date(j['createdAt']),
      );

  Json toJson() => {
        'id': id,
        'user': user.toJson(),
        'status': status.name,
        'direction': direction.name,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };
}

class FriendRequestBody {
  final String userId;
  const FriendRequestBody({required this.userId});

  factory FriendRequestBody.fromJson(Json j) => FriendRequestBody(userId: j['userId'] as String);
  Json toJson() => {'userId': userId};
}

/// Personal invite link — whoever opens it and signs in becomes a friend.
class InviteDto {
  final String code;
  final String url;
  const InviteDto({required this.code, required this.url});

  factory InviteDto.fromJson(Json j) => InviteDto(code: j['code'] as String, url: j['url'] as String);
  Json toJson() => {'code': code, 'url': url};
}

// MARK: - Feedback & shop reports

class FeedbackRequest {
  final String message;
  final String? screenshotBase64;
  final String? appVersion;
  final String? buildNumber;
  final String? platform;

  const FeedbackRequest({
    required this.message,
    this.screenshotBase64,
    this.appVersion,
    this.buildNumber,
    this.platform,
  });

  factory FeedbackRequest.fromJson(Json j) => FeedbackRequest(
        message: j['message'] as String,
        screenshotBase64: j['screenshotBase64'] as String?,
        appVersion: j['appVersion'] as String?,
        buildNumber: j['buildNumber'] as String?,
        platform: j['platform'] as String?,
      );

  Json toJson() => {
        'message': message,
        'screenshotBase64': screenshotBase64,
        'appVersion': appVersion,
        'buildNumber': buildNumber,
        'platform': platform,
      };
}

class ShopReportRequest {
  final String name;
  final String? hint;
  final double? latitude;
  final double? longitude;
  final String? note;

  const ShopReportRequest({required this.name, this.hint, this.latitude, this.longitude, this.note});

  factory ShopReportRequest.fromJson(Json j) => ShopReportRequest(
        name: j['name'] as String,
        hint: j['hint'] as String?,
        latitude: _doubleOrNull(j['latitude']),
        longitude: _doubleOrNull(j['longitude']),
        note: j['note'] as String?,
      );

  Json toJson() => {'name': name, 'hint': hint, 'latitude': latitude, 'longitude': longitude, 'note': note};
}

// MARK: - Moderation

/// Why a review is reported.
enum ReportReason {
  offensive('Beleidigend oder unangemessen'),
  spam('Spam oder Werbung'),
  fake('Fake, nicht echt'),
  other('Etwas anderes');

  final String label;
  const ReportReason(this.label);
}

class ReportRequest {
  final ReportReason reason;
  final String? note;
  const ReportRequest({required this.reason, this.note});

  factory ReportRequest.fromJson(Json j) =>
      ReportRequest(reason: ReportReason.values.byName(j['reason'] as String), note: j['note'] as String?);
  Json toJson() => {'reason': reason.name, 'note': note};
}

// MARK: - Cities

/// A city with rated places, to look around in from anywhere.
class CityDto {
  final String name;
  final double latitude;
  final double longitude;
  final int ratedPlaces;

  const CityDto({required this.name, required this.latitude, required this.longitude, required this.ratedPlaces});

  factory CityDto.fromJson(Json j) => CityDto(
        name: j['name'] as String,
        latitude: (j['latitude'] as num).toDouble(),
        longitude: (j['longitude'] as num).toDouble(),
        ratedPlaces: j['ratedPlaces'] as int,
      );

  Json toJson() => {'name': name, 'latitude': latitude, 'longitude': longitude, 'ratedPlaces': ratedPlaces};
}
