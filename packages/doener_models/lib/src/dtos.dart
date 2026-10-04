import 'menu.dart';

typedef Json = Map<String, dynamic>;

DateTime _date(Object? v) => DateTime.parse(v as String);
double? _doubleOrNull(Object? v) => (v as num?)?.toDouble();
DateTime? _dateOrNull(Object? v) => v == null ? null : DateTime.parse(v as String);
T? _enumOrNull<T extends Enum>(List<T> values, Object? name) => name == null ? null : values.byName(name as String);

/// Sauce, meat and bread travel as fields of their own (as before there were
/// other items), everything else in `items`.
Map<RatingItem, int> _ratingsFromJson(Json j) => {
      RatingItem.sauce: ?j['sauceRating'] as int?,
      RatingItem.fleisch: ?j['fleischRating'] as int?,
      RatingItem.brot: ?j['brotRating'] as int?,
      for (final e in ((j['items'] as Map?) ?? const {}).entries) RatingItem.values.byName(e.key as String): e.value as int,
    };

Json _ratingsToJson(Map<RatingItem, int> ratings) => {
      'sauceRating': ratings[RatingItem.sauce],
      'fleischRating': ratings[RatingItem.fleisch],
      'brotRating': ratings[RatingItem.brot],
      'items': {for (final e in ratings.entries) if (!e.key.isDoener) e.key.name: e.value},
    };

List<Ingredient>? _ingredientsFromJson(Object? v) =>
    v == null ? null : [for (final name in v as List) Ingredient.values.byName(name as String)];

// MARK: - Auth

class LoginRequest {
  final String email;
  const LoginRequest({required this.email});

  factory LoginRequest.fromJson(Json j) => LoginRequest(email: j['email'] as String);
  Json toJson() => {'email': email};
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

  const AccountDto({required super.id, required super.displayName, this.diet = Diet.all, this.expertMode = false});

  factory AccountDto.fromJson(Json j) => AccountDto(
        id: j['id'] as String,
        displayName: j['displayName'] as String,
        diet: _enumOrNull(Diet.values, j['diet']) ?? Diet.all,
        expertMode: j['expertMode'] as bool? ?? false,
      );
  @override
  Json toJson() => {...super.toJson(), 'diet': diet.name, 'expertMode': expertMode};
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

  /// What most experts got with "mit allem".
  final List<Ingredient> ingredients;
  final Meat? meat;
  final Skewer? skewer;
  final Bread? bread;

  /// Reviews that told what came with "mit allem".
  final int experts;

  const PlaceSummaryDto({
    this.items = const {},
    this.ayranHomemade,
    this.ingredients = const [],
    this.meat,
    this.skewer,
    this.bread,
    this.experts = 0,
  });

  List<Ingredient> get specials => [for (final i in ingredients) if (i.isSpecial) i];

  factory PlaceSummaryDto.fromJson(Json j) => PlaceSummaryDto(
        items: {
          for (final e in (j['items'] as Map).entries)
            RatingItem.values.byName(e.key as String): ItemAverage.fromJson(e.value as Json),
        },
        ayranHomemade: j['ayranHomemade'] as bool?,
        ingredients: _ingredientsFromJson(j['ingredients']) ?? const [],
        meat: _enumOrNull(Meat.values, j['meat']),
        skewer: _enumOrNull(Skewer.values, j['skewer']),
        bread: _enumOrNull(Bread.values, j['bread']),
        experts: j['experts'] as int,
      );

  Json toJson() => {
        'items': {for (final e in items.entries) e.key.name: e.value.toJson()},
        'ayranHomemade': ayranHomemade,
        'ingredients': [for (final i in ingredients) i.name],
        'meat': meat?.name,
        'skewer': skewer?.name,
        'bread': bread?.name,
        'experts': experts,
      };
}

// MARK: - Review

/// [rating] is the Döner score, derived from sauce, meat and bread — null for
/// reviews about other food. Facts like [veganOptions] describe the place.
class ReviewDto {
  final String id;
  final String userId;
  final String userName;
  final String placeId;
  final String placeName;
  final int? rating;
  final Map<RatingItem, int> ratings;
  final bool? veganOptions;
  final bool? ayranHomemade;
  final List<Ingredient>? ingredients;
  final Meat? meat;
  final Skewer? skewer;
  final Bread? bread;
  final String? text;
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
    this.ingredients,
    this.meat,
    this.skewer,
    this.bread,
    this.text,
    required this.createdAt,
    required this.updatedAt,
  });

  /// What the review shows to someone with [diet]. For the Döner the stored
  /// [rating] counts: older reviews may only have that one, or one set by hand.
  double? headline(Diet diet) => diet == Diet.all && rating != null ? rating!.toDouble() : diet.headline(ratings);

  factory ReviewDto.fromJson(Json j) => ReviewDto(
        id: j['id'] as String,
        userId: j['userId'] as String,
        userName: j['userName'] as String,
        placeId: j['placeId'] as String,
        placeName: j['placeName'] as String,
        rating: j['rating'] as int?,
        ratings: _ratingsFromJson(j),
        veganOptions: j['veganOptions'] as bool?,
        ayranHomemade: j['ayranHomemade'] as bool?,
        ingredients: _ingredientsFromJson(j['ingredients']),
        meat: _enumOrNull(Meat.values, j['meat']),
        skewer: _enumOrNull(Skewer.values, j['skewer']),
        bread: _enumOrNull(Bread.values, j['bread']),
        text: j['text'] as String?,
        createdAt: _date(j['createdAt']),
        updatedAt: _date(j['updatedAt']),
      );

  Json toJson() => {
        'id': id,
        'userId': userId,
        'userName': userName,
        'placeId': placeId,
        'placeName': placeName,
        'rating': rating,
        ..._ratingsToJson(ratings),
        'veganOptions': veganOptions,
        'ayranHomemade': ayranHomemade,
        'ingredients': ingredients == null ? null : [for (final i in ingredients!) i.name],
        'meat': meat?.name,
        'skewer': skewer?.name,
        'bread': bread?.name,
        'text': text,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };
}

/// One review per user and place — PUT replaces the previous one. The scores
/// are derived on the server.
class UpsertReviewRequest {
  final Map<RatingItem, int> ratings;
  final bool? veganOptions;
  final bool? ayranHomemade;

  /// Set by experts: what came with "mit allem".
  final List<Ingredient>? ingredients;
  final Meat? meat;
  final Skewer? skewer;
  final Bread? bread;
  final String? text;

  const UpsertReviewRequest({
    this.ratings = const {},
    this.veganOptions,
    this.ayranHomemade,
    this.ingredients,
    this.meat,
    this.skewer,
    this.bread,
    this.text,
  });

  factory UpsertReviewRequest.fromJson(Json j) => UpsertReviewRequest(
        ratings: _ratingsFromJson(j),
        veganOptions: j['veganOptions'] as bool?,
        ayranHomemade: j['ayranHomemade'] as bool?,
        ingredients: _ingredientsFromJson(j['ingredients']),
        meat: _enumOrNull(Meat.values, j['meat']),
        skewer: _enumOrNull(Skewer.values, j['skewer']),
        bread: _enumOrNull(Bread.values, j['bread']),
        text: j['text'] as String?,
      );

  Json toJson() => {
        ..._ratingsToJson(ratings),
        'veganOptions': veganOptions,
        'ayranHomemade': ayranHomemade,
        'ingredients': ingredients == null ? null : [for (final i in ingredients!) i.name],
        'meat': meat?.name,
        'skewer': skewer?.name,
        'bread': bread?.name,
        'text': text,
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
  final int? rating;
  final Map<RatingItem, int> ratings;
  final String? text;
  final String? foodType;

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
  });

  /// See [ReviewDto.headline].
  double? headline(Diet diet) => diet == Diet.all && rating != null ? rating!.toDouble() : diet.headline(ratings);

  factory FeedItem.fromJson(Json j) => FeedItem(
        id: j['id'] as String,
        type: FeedItemType.values.byName(j['type'] as String),
        user: UserDto.fromJson(j['user'] as Json),
        place: PlaceDto.fromJson(j['place'] as Json),
        timestamp: _date(j['timestamp']),
        fromFriend: j['fromFriend'] as bool,
        rating: j['rating'] as int?,
        ratings: _ratingsFromJson(j),
        text: j['text'] as String?,
        foodType: j['foodType'] as String?,
      );

  Json toJson() => {
        'id': id,
        'type': type.name,
        'user': user.toJson(),
        'place': place.toJson(),
        'timestamp': timestamp.toUtc().toIso8601String(),
        'fromFriend': fromFriend,
        'rating': rating,
        ..._ratingsToJson(ratings),
        'text': text,
        'foodType': foodType,
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
  final int rating;
  const FriendRatingDto({required this.user, required this.rating});

  factory FriendRatingDto.fromJson(Json j) =>
      FriendRatingDto(user: UserDto.fromJson(j['user'] as Json), rating: j['rating'] as int);
  Json toJson() => {'user': user.toJson(), 'rating': rating};
}

/// [average] and [count] are the real numbers; the order comes from [weightedRating].
class RankingEntryDto {
  final PlaceDto place;
  final double average;
  final int count;
  final List<FriendRatingDto> friends;

  const RankingEntryDto({required this.place, required this.average, required this.count, this.friends = const []});

  factory RankingEntryDto.fromJson(Json j) => RankingEntryDto(
        place: PlaceDto.fromJson(j['place'] as Json),
        average: (j['average'] as num).toDouble(),
        count: j['count'] as int,
        friends: (j['friends'] as List).map((e) => FriendRatingDto.fromJson(e as Json)).toList(),
      );

  Json toJson() => {
        'place': place.toJson(),
        'average': average,
        'count': count,
        'friends': friends.map((e) => e.toJson()).toList(),
      };
}

/// Places of one [city] (as in their address), best first. [city] is null
/// when no place near the requested position is known.
class RankingDto {
  final String? city;
  final RankBy by;
  final List<RankingEntryDto> entries;

  const RankingDto({this.city, required this.by, required this.entries});

  factory RankingDto.fromJson(Json j) => RankingDto(
        city: j['city'] as String?,
        by: RankBy.parse(j['by'] as String) ?? (throw FormatException('Unknown ranking ${j['by']}')),
        entries: (j['entries'] as List).map((e) => RankingEntryDto.fromJson(e as Json)).toList(),
      );

  Json toJson() => {'city': city, 'by': by.key, 'entries': entries.map((e) => e.toJson()).toList()};
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
