import 'gamification.dart';
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
/// {emoji: count} of [reactionEmojis], absent or empty when nobody reacted.
Map<String, int> _reactionsFromJson(Object? j) => {
      if (j is Map)
        for (final e in j.entries) e.key as String: e.value as int,
    };

List<Reactor> _reactorsFromJson(Object? j) => [if (j is List) for (final r in j) Reactor.fromJson(r as Json)];

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

/// Null if neither key is there: the reviewer said nothing about ingredients.
/// In menu order, which the split into two keys would lose.
List<Ingredient>? _ingredientsFromJson(Json j) => j['ingredients'] == null && j['newIngredients'] == null
    ? null
    : ([for (final name in [...?j['ingredients'] as List?, ...?j['newIngredients'] as List?]) Ingredient.values.byName(name as String)]
        ..sort((a, b) => a.index.compareTo(b.index)));

/// Shipped clients fail on ingredients they don't know, see Ingredient.newIngredients.
Json _ingredientsToJson(List<Ingredient>? ingredients) => {
      'ingredients': ingredients == null ? null : [for (final i in ingredients) if (!Ingredient.newIngredients.contains(i)) i.name],
      if (ingredients?.where(Ingredient.newIngredients.contains) case final news? when news.isNotEmpty)
        'newIngredients': [for (final i in news) i.name],
    };

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

/// What an invite did for TestFlight: null without an iPhone, otherwise
/// `invited`, `failed` (Apple refused) or `off` (no App Store Connect key).
class InviteResult {
  final String? testFlight;
  const InviteResult({this.testFlight});

  factory InviteResult.fromJson(Json j) => InviteResult(testFlight: j['testFlight'] as String?);
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
  final bool? pushFriends;
  final bool? pushNewPlaces;
  final bool? updateMails;

  /// Pushes pause until then; a time that has passed resumes them.
  final DateTime? pushPausedUntil;
  final bool? quietHours;
  final int? quietDays;
  final int? quietStart;
  final int? quietEnd;
  const UpdateMeRequest({
    this.displayName,
    this.diet,
    this.expertMode,
    this.pushFriends,
    this.pushNewPlaces,
    this.updateMails,
    this.pushPausedUntil,
    this.quietHours,
    this.quietDays,
    this.quietStart,
    this.quietEnd,
  });

  factory UpdateMeRequest.fromJson(Json j) => UpdateMeRequest(
        displayName: j['displayName'] as String?,
        diet: _enumOrNull(Diet.values, j['diet']),
        expertMode: j['expertMode'] as bool?,
        pushFriends: j['pushFriends'] as bool?,
        pushNewPlaces: j['pushNewPlaces'] as bool?,
        updateMails: j['updateMails'] as bool?,
        pushPausedUntil: _dateOrNull(j['pushPausedUntil']),
        quietHours: j['quietHours'] as bool?,
        quietDays: j['quietDays'] as int?,
        quietStart: j['quietStart'] as int?,
        quietEnd: j['quietEnd'] as int?,
      );
  Json toJson() => {
        'displayName': ?displayName,
        'diet': ?diet?.name,
        'expertMode': ?expertMode,
        'pushFriends': ?pushFriends,
        'pushNewPlaces': ?pushNewPlaces,
        'updateMails': ?updateMails,
        'pushPausedUntil': ?pushPausedUntil?.toUtc().toIso8601String(),
        'quietHours': ?quietHours,
        'quietDays': ?quietDays,
        'quietStart': ?quietStart,
        'quietEnd': ?quietEnd,
      };
}

// MARK: - User

/// [reviewedPlaces] gives the [tier] shown next to the name.
class UserDto {
  final String id;
  final String displayName;
  final int reviewedPlaces;
  const UserDto({required this.id, required this.displayName, this.reviewedPlaces = 0});

  Tier get tier => Tier.forReviewedPlaces(reviewedPlaces);

  factory UserDto.fromJson(Json j) => UserDto(
        id: j['id'] as String,
        displayName: j['displayName'] as String,
        reviewedPlaces: j['reviewedPlaces'] as int? ?? 0,
      );
  Json toJson() => {'id': id, 'displayName': displayName, 'reviewedPlaces': reviewedPlaces};

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

  /// Push when friends check in, and when a shop opens in the user's city.
  final bool pushFriends;
  final bool pushNewPlaces;

  /// Opted in to news by mail ("Neuigkeiten per Mail"), off by default.
  final bool updateMails;

  /// No pushes until then; null when they aren't paused.
  final DateTime? pushPausedUntil;

  /// No pushes from [quietStart] to [quietEnd] (minutes after midnight) on the
  /// [quietDays] (bit 0 is Monday) a window starts, in the phone's time zone.
  final bool quietHours;
  final int quietDays;
  final int quietStart;
  final int quietEnd;

  const AccountDto({
    required super.id,
    required super.displayName,
    this.diet = Diet.all,
    this.expertMode = false,
    this.admin = false,
    this.pushFriends = true,
    this.pushNewPlaces = true,
    this.updateMails = false,
    this.pushPausedUntil,
    this.quietHours = true,
    this.quietDays = allDays,
    this.quietStart = 22 * 60,
    this.quietEnd = 8 * 60,
  });

  /// [quietDays] with every day of the week.
  static const allDays = 127;

  bool get pushPaused => pushPausedUntil?.isAfter(DateTime.now()) ?? false;

  factory AccountDto.fromJson(Json j) => AccountDto(
        id: j['id'] as String,
        displayName: j['displayName'] as String,
        diet: _enumOrNull(Diet.values, j['diet']) ?? Diet.all,
        expertMode: j['expertMode'] as bool? ?? false,
        admin: j['admin'] as bool? ?? false,
        pushFriends: j['pushFriends'] as bool? ?? true,
        pushNewPlaces: j['pushNewPlaces'] as bool? ?? true,
        updateMails: j['updateMails'] as bool? ?? false,
        pushPausedUntil: _dateOrNull(j['pushPausedUntil']),
        quietHours: j['quietHours'] as bool? ?? true,
        quietDays: j['quietDays'] as int? ?? allDays,
        quietStart: j['quietStart'] as int? ?? 22 * 60,
        quietEnd: j['quietEnd'] as int? ?? 8 * 60,
      );
  @override
  Json toJson() => {
        ...super.toJson(),
        'diet': diet.name,
        'expertMode': expertMode,
        'admin': admin,
        'pushFriends': pushFriends,
        'pushNewPlaces': pushNewPlaces,
        'updateMails': updateMails,
        'pushPausedUntil': ?pushPausedUntil?.toUtc().toIso8601String(),
        'quietHours': quietHours,
        'quietDays': quietDays,
        'quietStart': quietStart,
        'quietEnd': quietEnd,
      };
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
  final bool isClosed;
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
    this.isClosed = false,
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
        isClosed: j['isClosed'] as bool? ?? false,
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
        'isClosed': isClosed,
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
        ingredients: _ingredientsFromJson(j) ?? const [],
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
        ..._ingredientsToJson(ingredients),
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

  /// Gives the author's [Tier].
  final int userReviewedPlaces;
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

  /// Friends' reactions, only on one's own reviews (`/me/reviews`), never on the shop page.
  final Map<String, int> reactions;
  final List<Reactor> reactors;

  const ReviewDto({
    required this.id,
    required this.userId,
    required this.userName,
    this.userReviewedPlaces = 0,
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
    this.reactions = const {},
    this.reactors = const [],
  });

  /// What the review shows to someone with [diet]. For the Döner the stored
  /// [rating] counts: older reviews may only have that one, or one set by hand.
  double? headline(Diet diet) => diet == Diet.all && rating != null ? rating! : diet.headline(ratings);

  factory ReviewDto.fromJson(Json j) => ReviewDto(
        id: j['id'] as String,
        userId: j['userId'] as String,
        userName: j['userName'] as String,
        userReviewedPlaces: j['userReviewedPlaces'] as int? ?? 0,
        placeId: j['placeId'] as String,
        placeName: j['placeName'] as String,
        rating: _scoreFromJson(j),
        ratings: _ratingsFromJson(j),
        veganOptions: j['veganOptions'] as bool?,
        ayranHomemade: j['ayranHomemade'] as bool?,
        price: j['price'] as int?,
        ingredients: _ingredientsFromJson(j),
        meat: _enumOrNull(Meat.values, j['meat']),
        skewer: _enumOrNull(Skewer.values, j['skewer']),
        bread: _enumOrNull(Bread.values, j['bread']),
        text: j['text'] as String?,
        photoId: j['photoId'] as String?,
        onSite: j['onSite'] as bool? ?? false,
        regular: j['regular'] as bool? ?? false,
        createdAt: _date(j['createdAt']),
        updatedAt: _date(j['updatedAt']),
        reactions: _reactionsFromJson(j['reactions']),
        reactors: _reactorsFromJson(j['reactors']),
      );

  Json toJson() => {
        'id': id,
        'userId': userId,
        'userName': userName,
        'userReviewedPlaces': userReviewedPlaces,
        'placeId': placeId,
        'placeName': placeName,
        'rating': rating?.round(),
        'score': rating,
        ..._ratingsToJson(ratings),
        'veganOptions': veganOptions,
        'ayranHomemade': ayranHomemade,
        'price': price,
        ..._ingredientsToJson(ingredients),
        'meat': meat?.name,
        'skewer': skewer?.name,
        'bread': bread?.name,
        'text': text,
        'photoId': photoId,
        'onSite': onSite,
        'regular': regular,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        if (reactions.isNotEmpty) 'reactions': reactions,
        if (reactors.isNotEmpty) 'reactors': [for (final r in reactors) r.toJson()],
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
        ingredients: _ingredientsFromJson(j),
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
        ..._ingredientsToJson(ingredients),
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

  /// Friends' reactions, only on one's own check-ins (`/me/visits`).
  final Map<String, int> reactions;
  final List<Reactor> reactors;

  const VisitDto({
    required this.id,
    required this.userId,
    required this.userName,
    required this.placeId,
    required this.placeName,
    required this.visitedAt,
    this.foodType,
    this.reactions = const {},
    this.reactors = const [],
  });

  factory VisitDto.fromJson(Json j) => VisitDto(
        id: j['id'] as String,
        userId: j['userId'] as String,
        userName: j['userName'] as String,
        placeId: j['placeId'] as String,
        placeName: j['placeName'] as String,
        visitedAt: _date(j['visitedAt']),
        foodType: j['foodType'] as String?,
        reactions: _reactionsFromJson(j['reactions']),
        reactors: _reactorsFromJson(j['reactors']),
      );

  Json toJson() => {
        'id': id,
        'userId': userId,
        'userName': userName,
        'placeId': placeId,
        'placeName': placeName,
        'visitedAt': visitedAt.toUtc().toIso8601String(),
        'foodType': foodType,
        if (reactions.isNotEmpty) 'reactions': reactions,
        if (reactors.isNotEmpty) 'reactors': [for (final r in reactors) r.toJson()],
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

/// What friends react with to each other's check-ins and reviews, one per person and post.
const reactionEmojis = ['🤤', '🥙', '🙋'];

/// Who reacted with what. Named are only friends of whoever looks, never oneself;
/// the others only count in the reactions.
class Reactor {
  final String emoji;
  final UserDto user;
  const Reactor({required this.emoji, required this.user});

  factory Reactor.fromJson(Json j) => Reactor(emoji: j['emoji'] as String, user: UserDto.fromJson(j['user'] as Json));

  Json toJson() => {'emoji': emoji, 'user': user.toJson()};
}

class ReactionRequest {
  final String emoji;
  const ReactionRequest(this.emoji);

  factory ReactionRequest.fromJson(Json j) => ReactionRequest(j['emoji'] as String);

  Json toJson() => {'emoji': emoji};
}

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

  /// {emoji: count} and the own pick; only on posts of friends, who are the only ones to react.
  final Map<String, int> reactions;
  final String? myReaction;
  final List<Reactor> reactors;

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
    this.reactions = const {},
    this.myReaction,
    this.reactors = const [],
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
        reactions: _reactionsFromJson(j['reactions']),
        myReaction: j['myReaction'] as String?,
        reactors: _reactorsFromJson(j['reactors']),
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
        'reactions': reactions,
        'myReaction': myReaction,
        'reactors': [for (final r in reactors) r.toJson()],
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

  /// The user gets no push when this friend checks in.
  final bool muted;

  const FriendshipDto({
    required this.id,
    required this.user,
    required this.status,
    required this.direction,
    required this.createdAt,
    this.muted = false,
  });

  factory FriendshipDto.fromJson(Json j) => FriendshipDto(
        id: j['id'] as String,
        user: UserDto.fromJson(j['user'] as Json),
        status: FriendshipStatus.values.byName(j['status'] as String),
        direction: FriendshipDirection.values.byName(j['direction'] as String),
        createdAt: _date(j['createdAt']),
        muted: j['muted'] as bool? ?? false,
      );

  Json toJson() => {
        'id': id,
        'user': user.toJson(),
        'status': status.name,
        'direction': direction.name,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'muted': muted,
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

// MARK: - Profile

/// Someone's public profile. [since] is their first check-in or review.
/// [checkIns] and [visits] are only there for friends and oneself.
class ProfileDto {
  final UserDto user;
  final DateTime? since;
  final List<ReviewDto> reviews;
  final int? checkIns;
  final List<VisitDto>? visits;

  const ProfileDto({required this.user, this.since, this.reviews = const [], this.checkIns, this.visits});

  factory ProfileDto.fromJson(Json j) => ProfileDto(
        user: UserDto.fromJson(j['user'] as Json),
        since: _dateOrNull(j['since']),
        reviews: [for (final r in j['reviews'] as List) ReviewDto.fromJson(r as Json)],
        checkIns: j['checkIns'] as int?,
        visits: (j['visits'] as List?)?.map((v) => VisitDto.fromJson(v as Json)).toList(),
      );

  Json toJson() => {
        'user': user.toJson(),
        'since': since?.toUtc().toIso8601String(),
        'reviews': [for (final r in reviews) r.toJson()],
        'checkIns': checkIns,
        'visits': visits?.map((v) => v.toJson()).toList(),
      };
}

// MARK: - Push

/// The device's FCM token. With a position the server learns the user's city
/// for "a new shop opened". [fetchKey] lets the device read what its pushes
/// are about ([PushEventDto]) without the session; shipped clients send none
/// and get a neutral notification instead.
class PushTokenRequest {
  final String token;
  final String platform;
  final double? latitude;
  final double? longitude;
  final String? fetchKey;

  /// IANA name such as `Europe/Berlin`, for the quiet hours.
  final String? timeZone;
  const PushTokenRequest({required this.token, required this.platform, this.latitude, this.longitude, this.fetchKey, this.timeZone});

  factory PushTokenRequest.fromJson(Json j) => PushTokenRequest(
        token: j['token'] as String,
        platform: j['platform'] as String,
        latitude: _doubleOrNull(j['latitude']),
        longitude: _doubleOrNull(j['longitude']),
        fetchKey: j['fetchKey'] as String?,
        timeZone: j['timeZone'] as String?,
      );
  Json toJson() =>
      {'token': token, 'platform': platform, 'latitude': latitude, 'longitude': longitude, 'fetchKey': ?fetchKey, 'timeZone': ?timeZone};
}

/// What a push is about. The push itself carries only its type and event ID.
class PushEventDto {
  final String type;
  final String title;
  final String body;
  final String? placeId;

  /// Who checked in, for "Weniger davon"; the first one of several.
  final String? actorId;
  final String? actorName;
  const PushEventDto({required this.type, required this.title, required this.body, this.placeId, this.actorId, this.actorName});

  factory PushEventDto.fromJson(Json j) => PushEventDto(
        type: j['type'] as String,
        title: j['title'] as String,
        body: j['body'] as String,
        placeId: j['placeId'] as String?,
        actorId: j['actorId'] as String?,
        actorName: j['actorName'] as String?,
      );
  Json toJson() =>
      {'type': type, 'title': title, 'body': body, 'placeId': ?placeId, 'actorId': ?actorId, 'actorName': ?actorName};
}

/// What happened lately, for the bell on Start: friends' check-ins and
/// reviews, reactions to the user's posts, friend requests, new shops in the
/// user's city and news. [type] is one of [InboxItemDto.types].
class InboxItemDto {
  static const types = ['friend_visit', 'friend_review', 'reaction', 'friend_request', 'new_place', 'news'];

  final String type;
  final String id;
  final DateTime timestamp;
  final String title;
  final String? body;
  final String? placeId;

  /// The friend it is about, for "Weniger davon" and friend requests.
  final String? userId;
  final String? userName;

  const InboxItemDto({
    required this.type,
    required this.id,
    required this.timestamp,
    required this.title,
    this.body,
    this.placeId,
    this.userId,
    this.userName,
  });

  factory InboxItemDto.fromJson(Json j) => InboxItemDto(
        type: j['type'] as String,
        id: j['id'] as String,
        timestamp: _date(j['timestamp']),
        title: j['title'] as String,
        body: j['body'] as String?,
        placeId: j['placeId'] as String?,
        userId: j['userId'] as String?,
        userName: j['userName'] as String?,
      );
  Json toJson() => {
        'type': type,
        'id': id,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'title': title,
        'body': ?body,
        'placeId': ?placeId,
        'userId': ?userId,
        'userName': ?userName,
      };
}

/// The last 7 days, newest first. Items after [seenAt] are new; it is the
/// same on every device. [loadedAt] is the server's time of the answer,
/// sent back when the bell was opened.
class InboxDto {
  final List<InboxItemDto> items;
  final DateTime? seenAt;
  final DateTime? loadedAt;
  const InboxDto({required this.items, this.seenAt, this.loadedAt});

  int get unread => items.where((i) => seenAt == null || i.timestamp.isAfter(seenAt!)).length;

  factory InboxDto.fromJson(Json j) => InboxDto(
        items: [for (final i in j['items'] as List) InboxItemDto.fromJson(i as Json)],
        seenAt: _dateOrNull(j['seenAt']),
        loadedAt: _dateOrNull(j['loadedAt']),
      );
  Json toJson() => {
        'items': [for (final i in items) i.toJson()],
        'seenAt': ?seenAt?.toUtc().toIso8601String(),
        'loadedAt': ?loadedAt?.toUtc().toIso8601String(),
      };
}

/// What the notification says when the details can't be loaded: the type only.
(String, String) neutralPushText(String? type) => switch (type) {
      'friend_check_in' => ('Döner App', 'Ein Freund ist gerade beim Döner. Öffne die App für Details.'),
      'new_place' => ('Döner App', 'Ein neuer Döner hat aufgemacht. Öffne die App für Details.'),
      _ => ('Döner App', 'Es gibt Neues in der Döner App.'),
    };

// MARK: - News

/// News about the app: a card on Start and, for those who opted in, a mail.
class UpdateDto {
  final String id;
  final String title;
  final List<String> features;
  final bool inApp;
  final bool byMail;
  final DateTime? publishedAt;

  /// Mail deliveries, for admins.
  final int sent;
  final int pending;
  final int failed;

  const UpdateDto({
    required this.id,
    required this.title,
    required this.features,
    this.inApp = true,
    this.byMail = true,
    this.publishedAt,
    this.sent = 0,
    this.pending = 0,
    this.failed = 0,
  });

  factory UpdateDto.fromJson(Json j) => UpdateDto(
        id: j['id'] as String,
        title: j['title'] as String,
        features: [for (final f in j['features'] as List) f as String],
        inApp: j['inApp'] as bool? ?? true,
        byMail: j['byMail'] as bool? ?? true,
        publishedAt: _dateOrNull(j['publishedAt']),
        sent: j['sent'] as int? ?? 0,
        pending: j['pending'] as int? ?? 0,
        failed: j['failed'] as int? ?? 0,
      );
  Json toJson() => {
        'id': id,
        'title': title,
        'features': features,
        'inApp': inApp,
        'byMail': byMail,
        'publishedAt': publishedAt?.toIso8601String(),
        'sent': sent,
        'pending': pending,
        'failed': failed,
      };
}

/// A draft as the admin writes it.
class UpdateDraftRequest {
  final String title;
  final List<String> features;
  final bool inApp;
  final bool byMail;
  const UpdateDraftRequest({required this.title, required this.features, this.inApp = true, this.byMail = true});

  factory UpdateDraftRequest.fromJson(Json j) => UpdateDraftRequest(
        title: j['title'] as String,
        features: [for (final f in j['features'] as List) f as String],
        inApp: j['inApp'] as bool? ?? true,
        byMail: j['byMail'] as bool? ?? true,
      );
  Json toJson() => {'title': title, 'features': features, 'inApp': inApp, 'byMail': byMail};
}

/// The admin's list of news, with how many get the mail.
class AdminUpdatesDto {
  final int subscribers;
  final List<UpdateDto> updates;
  const AdminUpdatesDto({required this.subscribers, required this.updates});

  factory AdminUpdatesDto.fromJson(Json j) => AdminUpdatesDto(
        subscribers: j['subscribers'] as int,
        updates: [for (final u in j['updates'] as List) UpdateDto.fromJson(u as Json)],
      );
  Json toJson() => {'subscribers': subscribers, 'updates': [for (final u in updates) u.toJson()]};
}
