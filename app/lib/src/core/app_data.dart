import 'dart:async';
import 'dart:convert';

import 'package:doener_models/doener_models.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sembast/sembast.dart';
import 'package:uuid/uuid.dart';

import 'api.dart';
import 'reminders.dart';
import 'session.dart';

final _places = stringMapStoreFactory.store('places');

const placeCacheMaxAge = Duration(days: 30);
final _visits = stringMapStoreFactory.store('visits');
final _reviews = stringMapStoreFactory.store('reviews');
final _queue = intMapStoreFactory.store('queue');
final _favorites = StoreRef<String, bool>('favorites');

/// A shop whose review a link asked for (`https://…/b/<placeId>`), kept
/// through onboarding and login until its review sheet opens.
final pendingReviewRecord = settingsStore.record('pendingReview');

/// How long a check-in without a review stays on Start as "to review".
const toReviewWindow = Duration(days: 14);

class LocalVisit {
  final VisitDto dto;
  final bool pending;
  const LocalVisit(this.dto, {this.pending = false});
}

class LocalReview {
  final ReviewDto dto;
  final bool pending;

  /// A new photo waiting for upload; once on the server, [ReviewDto.photoId] points to it.
  final Uint8List? photo;
  const LocalReview(this.dto, {this.pending = false, this.photo});
}

/// Local-first data: everything the UI shows comes from here. The server is
/// the source of truth for the account's visits and reviews; changes made on
/// the device wait in a queue until they are confirmed.
class AppData extends ChangeNotifier {
  final Database _db;
  final Session session;
  final Reminders? reminders;

  AppData(this._db, this.session, {this.reminders});

  ApiClient get _api => session.api;

  final places = <String, PlaceDto>{};
  Iterable<PlaceDto> get activePlaces => places.values.where((p) => !p.isClosed);
  final favorites = <String>{};
  final reviews = <String, LocalReview>{};
  List<LocalVisit> visits = [];
  int pendingCount = 0;
  String? lastSyncError;

  /// Check-ins whose "Wie war's?" card was closed.
  Set<String> _dismissedToReview = {};

  /// See [pendingReviewRecord].
  final reviewRequest = ValueNotifier<String?>(null);

  Future<void> load() async {
    // Google allows caching place details for at most 30 days; older entries
    // (and entries from builds without a timestamp) are refetched on demand.
    final cutoff = DateTime.now().subtract(placeCacheMaxAge).millisecondsSinceEpoch;
    final expired = <String>[];
    for (final r in await _places.find(_db)) {
      final cachedAt = r.value['cachedAt'] as int?;
      if (cachedAt == null || cachedAt < cutoff) {
        expired.add(r.key);
      } else {
        places[r.key] = PlaceDto.fromJson((r.value['dto'] as Map).cast<String, dynamic>());
      }
    }
    await _places.records(expired).delete(_db);
    for (final r in await _favorites.find(_db)) {
      favorites.add(r.key);
    }
    for (final r in await _reviews.find(_db)) {
      reviews[r.key] = _reviewFromRecord(r.value);
    }
    visits = [for (final r in await _visits.find(_db)) _visitFromRecord(r.value)];
    _sortVisits();
    pendingCount = await _queue.count(_db);
    _dismissedToReview = {...?(await settingsStore.record('toReviewDismissed').get(_db) as List?)?.cast<String>()};
    reviewRequest.value = await pendingReviewRecord.get(_db) as String?;
    notifyListeners();
  }

  // MARK: - Places

  Future<void> loadArea({required double south, required double west, required double north, required double east}) async {
    final json = await _api.get('/places', query: {
      'minLat': '$south',
      'minLon': '$west',
      'maxLat': '$north',
      'maxLon': '$east',
      'includeClosed': 'true',
    });
    await _cachePlaces(json as List);
  }

  /// Shops around a position — enough to tell whether the user is at one.
  Future<void> loadAround(double lat, double lon) =>
      loadArea(south: lat - 0.0025, west: lon - 0.0025, north: lat + 0.0025, east: lon + 0.0025);

  /// Known places within [meters], nearest first.
  List<PlaceDto> placesWithin(double lat, double lon, double meters) {
    final distances = {
      for (final p in activePlaces) p.placeId: Geolocator.distanceBetween(lat, lon, p.latitude, p.longitude),
    };
    return [for (final e in distances.entries) if (e.value <= meters) places[e.key]!]
      ..sort((a, b) => distances[a.placeId]!.compareTo(distances[b.placeId]!));
  }

  /// Best around by the main score of [diet].
  Future<List<PlaceDto>> topNearby(double lat, double lon, Diet diet) async => _cachePlaces(await _api.get(
        '/places/top',
        query: {'lat': '$lat', 'lon': '$lon', 'limit': '3', 'by': RankBy.score(diet).key},
      ) as List);

  Future<List<PlaceDto>> trending(double lat, double lon) async =>
      _cachePlaces(await _api.get('/places/trending', query: {'lat': '$lat', 'lon': '$lon'}) as List);

  Future<List<CityDto>> cities() async =>
      [for (final c in await _api.get('/cities') as List) CityDto.fromJson(c as Map<String, dynamic>)];

  /// Opened lately around, and openings Google announced. Only the opened
  /// ones are real places for the map.
  Future<NewPlacesDto> newPlaces(double lat, double lon) async {
    final news = NewPlacesDto.fromJson(await _api.get('/places/new', query: {'lat': '$lat', 'lon': '$lon'}) as Map<String, dynamic>);
    await _storePlaces(news.opened);
    return news;
  }

  Future<RankingDto> ranking(double lat, double lon, RankBy by, {String? city, int? maxPrice, Ingredient? ingredient}) async {
    final json = await _api.get('/ranking', query: {
      'lat': '$lat',
      'lon': '$lon',
      'by': by.key,
      'city': ?city,
      if (maxPrice != null) 'maxPrice': '$maxPrice',
      'ingredient': ?ingredient?.name,
    });
    final ranking = RankingDto.fromJson(json as Map<String, dynamic>);
    await _storePlaces([for (final e in ranking.entries) e.place]);
    return ranking;
  }

  /// Every shop the server knows by name, nearest to [lat]/[lon] first.
  Future<List<PlaceDto>> searchPlaces(String query, {double? lat, double? lon}) async =>
      _cachePlaces(await _api.get('/places/search', query: {'q': query, 'lat': ?lat?.toString(), 'lon': ?lon?.toString()}) as List);

  /// Fresh community rating after the user reviewed a place, or its opening
  /// hours, which the server fetches when someone first opens it.
  Future<void> refreshPlace(String placeId) async =>
      _cachePlaces([await _api.get('/places/${Uri.encodeComponent(placeId)}')]);

  Future<List<PlaceDto>> _cachePlaces(List json) =>
      _storePlaces([for (final p in json) PlaceDto.fromJson(p as Map<String, dynamic>)]);

  /// Shown right away, the copy on disk follows: on the web, IndexedDB is slow
  /// enough to hold up the start screen.
  Future<List<PlaceDto>> _storePlaces(List<PlaceDto> list) async {
    for (final p in list) {
      places[p.placeId] = p;
    }
    notifyListeners();
    unawaited(_db.transaction((tx) async {
      for (final p in list) {
        await _places.record(p.placeId).put(tx, {'dto': p.toJson(), 'cachedAt': DateTime.now().millisecondsSinceEpoch});
      }
    }));
    return list;
  }

  Future<void> toggleFavorite(String placeId) async {
    if (favorites.remove(placeId)) {
      await _favorites.record(placeId).delete(_db);
    } else {
      favorites.add(placeId);
      await _favorites.record(placeId).put(_db, true);
    }
    notifyListeners();
  }

  // MARK: - Visits & reviews

  List<LocalVisit> visitsAt(String placeId) => visits.where((v) => v.dto.placeId == placeId).toList();

  Future<void> checkIn(PlaceDto place, {String? foodType}) async {
    final user = session.user!;
    final request = CreateVisitRequest(id: const Uuid().v4(), visitedAt: DateTime.now().toUtc(), foodType: foodType);
    final visit = VisitDto(
      id: request.id,
      userId: user.id,
      userName: user.displayName,
      placeId: place.placeId,
      placeName: place.name,
      visitedAt: request.visitedAt,
      foodType: foodType,
    );
    await _putVisit(LocalVisit(visit, pending: true));
    await _enqueue('visit', place.placeId, request.toJson());
    sync();
    if (reminders case final r?) unawaited(r.schedule(place, request.visitedAt, rating: reviews[place.placeId]?.dto.headline(session.diet)));
  }

  /// Places checked in at lately and not reviewed since, latest first — one
  /// card each on Start. Built from the account's visits and reviews, which
  /// every device syncs, so a phone and the web app show the same. A check-in
  /// shows up when the reminder would come.
  List<LocalVisit> toReview(DateTime now) {
    final seen = <String>{};
    return [
      for (final visit in visits)
        if (seen.add(visit.dto.placeId) &&
            !_dismissedToReview.contains(visit.dto.id) &&
            now.difference(visit.dto.visitedAt) >= reminderDelay &&
            now.difference(visit.dto.visitedAt) <= toReviewWindow &&
            (reviews[visit.dto.placeId]?.dto.updatedAt.isBefore(visit.dto.visitedAt) ?? true))
          visit,
    ];
  }

  Future<void> dismissToReview(LocalVisit visit) async {
    final cutoff = DateTime.now().subtract(toReviewWindow);
    final recent = {for (final v in visits) if (v.dto.visitedAt.isAfter(cutoff)) v.dto.id};
    _dismissedToReview = {..._dismissedToReview.where(recent.contains), visit.dto.id};
    notifyListeners();
    await settingsStore.record('toReviewDismissed').put(_db, _dismissedToReview.toList());
  }

  /// Opens the review of [placeId] as soon as the app is past login (see [pendingReviewRecord]).
  Future<void> requestReview(String placeId) async {
    await pendingReviewRecord.put(_db, placeId);
    reviewRequest.value = placeId;
  }

  /// Takes the requested review; null if there is none.
  Future<String?> takeReviewRequest() async {
    final placeId = reviewRequest.value;
    if (placeId == null) return null;
    reviewRequest.value = null;
    await pendingReviewRecord.delete(_db);
    return placeId;
  }

  /// A place from the cache, otherwise from the server.
  Future<PlaceDto> place(String placeId) async {
    if (places[placeId] case final place?) return place;
    await refreshPlace(placeId);
    return places[placeId]!;
  }

  Future<void> saveReview(PlaceDto place, UpsertReviewRequest request) async {
    final user = session.user!;
    final now = DateTime.now().toUtc();
    final previous = reviews[place.placeId]?.dto;
    final review = ReviewDto(
      id: previous?.id ?? const Uuid().v4(),
      userId: user.id,
      userName: user.displayName,
      placeId: place.placeId,
      placeName: place.name,
      // As on the server: an older overall rating stays until sauce, meat or bread are rated.
      rating: RatingItem.classicItems.any((i) => request.ratings.containsKey(i) || (previous?.ratings.containsKey(i) ?? false))
          ? Diet.all.score(request.ratings)?.halfStep
          : previous?.rating,
      ratings: request.ratings,
      veganOptions: request.veganOptions,
      ayranHomemade: request.ayranHomemade,
      price: request.price,
      ingredients: request.ingredients,
      meat: request.meat,
      skewer: request.skewer,
      bread: request.bread,
      text: Validation.clean(request.text),
      photoId: request.photoBase64 != null || request.removePhoto ? null : previous?.photoId,
      onSite: (previous?.onSite ?? false) || visitsAt(place.placeId).isNotEmpty,
      createdAt: previous?.createdAt ?? now,
      updatedAt: now,
    );
    final photo = request.photoBase64 == null ? null : base64.decode(request.photoBase64!);
    await _putReview(LocalReview(review, pending: true, photo: photo));
    // Only the latest edit per place needs to reach the server.
    await _queue.delete(_db, finder: Finder(filter: Filter.and([Filter.equals('kind', 'review'), Filter.equals('placeId', place.placeId)])));
    await _enqueue('review', place.placeId, request.toJson());
    sync();
    if (reminders case final r?) unawaited(r.cancelFor(place.placeId));
  }

  /// Replaces synced visits/reviews with the server's copy; pending ones stay.
  Future<void> refreshMine() async {
    if (!session.isLoggedIn) return;
    try {
      final results = await Future.wait([_api.get('/me/places'), _api.get('/me/visits'), _api.get('/me/reviews')]);
      await _cachePlaces(results[0] as List);
      final serverVisits = [for (final v in results[1] as List) VisitDto.fromJson(v as Map<String, dynamic>)];
      final serverReviews = [for (final r in results[2] as List) ReviewDto.fromJson(r as Map<String, dynamic>)];

      final serverVisitIds = serverVisits.map((v) => v.id).toSet();
      visits = [
        ...serverVisits.map((v) => LocalVisit(v)),
        ...visits.where((v) => v.pending && !serverVisitIds.contains(v.dto.id)),
      ];
      _sortVisits();
      final pendingReviews = {for (final e in reviews.entries.where((e) => e.value.pending)) e.key: e.value};
      reviews
        ..clear()
        ..addAll({for (final r in serverReviews) r.placeId: LocalReview(r)})
        ..addAll(pendingReviews);

      await _db.transaction((tx) async {
        await _visits.delete(tx);
        for (final v in visits) {
          await _visits.record(v.dto.id).put(tx, _visitRecord(v));
        }
        await _reviews.delete(tx);
        for (final r in reviews.values) {
          await _reviews.record(r.dto.placeId).put(tx, _reviewRecord(r));
        }
      });
      notifyListeners();
    } on OfflineException {
      // Cached data stays visible.
    } on ApiException catch (e) {
      debugPrint('refreshMine failed: $e');
    }
  }

  Future<void>? _runningSync;
  bool get syncing => _runningSync != null;

  /// Sends queued changes in order. Callers during a running sync get the
  /// running one. Stops at the first transient failure so ordering is kept;
  /// permanently rejected entries are dropped.
  Future<void> sync() {
    if (!session.isLoggedIn) return Future.value();
    return _runningSync ??= _sync().whenComplete(() {
      _runningSync = null;
      notifyListeners();
    });
  }

  Future<void> _sync() async {
    lastSyncError = null;
    notifyListeners();
    try {
      final ops = await _queue.find(_db, finder: Finder(sortOrders: [SortOrder(Field.key)]));
      for (final op in ops) {
        final kind = op.value['kind'] as String;
        final placeId = op.value['placeId'] as String;
        final body = op.value['body'];
        try {
          if (kind == 'visit') {
            final json = await _api.post('/places/$placeId/visits', body);
            await _putVisit(LocalVisit(VisitDto.fromJson(json as Map<String, dynamic>)));
          } else {
            final json = await _api.put('/places/$placeId/review', body);
            await _putReview(LocalReview(ReviewDto.fromJson(json as Map<String, dynamic>)));
          }
          await _queue.record(op.key).delete(_db);
        } on OfflineException catch (e) {
          lastSyncError = e.toString();
          break;
        } on ApiException catch (e) {
          if (e.status == 401 || e.status == 429 || e.status >= 500) {
            lastSyncError = e.message;
            break;
          }
          await _queue.record(op.key).delete(_db);
          await _dropPending(kind, placeId, (body as Map)['id'] as String?);
          lastSyncError = 'Eintrag verworfen: ${e.message}';
        }
      }
    } finally {
      pendingCount = await _queue.count(_db);
    }
  }

  /// Called after every successful login.
  Future<void> onSignedIn(String userId) async {
    final previous = await settingsStore.record('accountUserId').get(_db);
    if (previous != null && previous != userId) await clearAccountData();
    await settingsStore.record('accountUserId').put(_db, userId);
    await sync();
    await refreshMine();
  }

  Future<void> clearAccountData() async {
    await _db.transaction((tx) async {
      await _visits.delete(tx);
      await _reviews.delete(tx);
      await _queue.delete(tx);
      await settingsStore.record('accountUserId').delete(tx);
    });
    visits = [];
    reviews.clear();
    pendingCount = 0;
    notifyListeners();
  }

  /// Drops cached places that nothing on this device refers to.
  Future<void> clearMapCache() async {
    final keep = {...favorites, ...reviews.keys, ...visits.map((v) => v.dto.placeId)};
    places.removeWhere((id, _) => !keep.contains(id));
    await _places.delete(_db, finder: Finder(filter: Filter.custom((r) => !keep.contains(r.key))));
    notifyListeners();
  }

  Future<void> clearDeviceData() async {
    await clearAccountData();
    await _db.transaction((tx) async {
      await _favorites.delete(tx);
      await _places.delete(tx);
    });
    favorites.clear();
    places.clear();
    notifyListeners();
  }

  // MARK: - Persistence helpers

  Future<void> _enqueue(String kind, String placeId, Map<String, dynamic> body) async {
    await _queue.add(_db, {'kind': kind, 'placeId': placeId, 'body': body});
    pendingCount = await _queue.count(_db);
    notifyListeners();
  }

  Future<void> _putVisit(LocalVisit visit) async {
    visits = [...visits.where((v) => v.dto.id != visit.dto.id), visit];
    _sortVisits();
    await _visits.record(visit.dto.id).put(_db, _visitRecord(visit));
    notifyListeners();
  }

  Future<void> _putReview(LocalReview review) async {
    reviews[review.dto.placeId] = review;
    await _reviews.record(review.dto.placeId).put(_db, _reviewRecord(review));
    notifyListeners();
  }

  Future<void> _dropPending(String kind, String placeId, String? visitId) async {
    if (kind == 'visit' && visitId != null) {
      visits = visits.where((v) => v.dto.id != visitId).toList();
      await _visits.record(visitId).delete(_db);
    } else if (kind == 'review' && reviews[placeId]?.pending == true) {
      reviews.remove(placeId);
      await _reviews.record(placeId).delete(_db);
    }
    notifyListeners();
  }

  void _sortVisits() => visits.sort((a, b) => b.dto.visitedAt.compareTo(a.dto.visitedAt));

  static Map<String, Object?> _visitRecord(LocalVisit v) => {'dto': v.dto.toJson(), 'pending': v.pending};
  static Map<String, Object?> _reviewRecord(LocalReview r) =>
      {'dto': r.dto.toJson(), 'pending': r.pending, if (r.photo != null) 'photo': base64.encode(r.photo!)};

  static LocalVisit _visitFromRecord(Map<String, Object?> r) =>
      LocalVisit(VisitDto.fromJson((r['dto'] as Map).cast<String, dynamic>()), pending: r['pending'] as bool);
  static LocalReview _reviewFromRecord(Map<String, Object?> r) => LocalReview(
        ReviewDto.fromJson((r['dto'] as Map).cast<String, dynamic>()),
        pending: r['pending'] as bool,
        photo: r['photo'] == null ? null : base64.decode(r['photo'] as String),
      );
}
