import 'dart:convert';
import 'dart:typed_data';

import 'package:doener_app/src/core/app_data.dart';
import 'package:doener_app/src/core/session.dart';
import 'package:doener_models/doener_models.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sembast/sembast_memory.dart';

const _place = PlaceDto(placeId: 'p1', name: 'Kebap Haus', latitude: 48, longitude: 7.85);
const _user = AccountDto(id: 'u1', displayName: 'Robin');

/// Server stand-in: [mode] decides how write requests are answered.
class FakeServer {
  String mode = 'ok';
  final requests = <String>[];
  Map<String, dynamic>? lastBody;

  http.Response _json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path.replaceFirst('/api/v1', '');
    requests.add('${request.method} $path');
    if (path == '/auth/verify') return _json(AuthResponse(token: 't', user: _user, isNewUser: false).toJson());
    if (path.startsWith('/me/')) return _json([]);
    if (mode == 'offline') throw http.ClientException('offline');
    if (mode == '401') return _json({'error': 'Sitzung abgelaufen'}, 401);
    if (mode == '400') return _json({'error': 'Ungültig'}, 400);

    final body = lastBody = jsonDecode(request.body) as Map<String, dynamic>;
    final now = DateTime.now().toUtc();
    if (path.endsWith('/visits')) {
      return _json(VisitDto(
        id: body['id'] as String,
        userId: _user.id,
        userName: _user.displayName,
        placeId: _place.placeId,
        placeName: _place.name,
        visitedAt: DateTime.parse(body['visitedAt'] as String),
        foodType: body['foodType'] as String?,
      ).toJson(), 201);
    }
    return _json(ReviewDto(
      id: 'r1',
      userId: _user.id,
      userName: _user.displayName,
      placeId: _place.placeId,
      placeName: _place.name,
      ratings: UpsertReviewRequest.fromJson(body).ratings,
      photoId: body['photoBase64'] == null ? null : 'ph1',
      createdAt: now,
      updatedAt: now,
    ).toJson());
  }
}

void main() {
  late FakeServer server;
  late Database db;
  late Session session;
  late AppData data;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeServer();
    db = await newDatabaseFactoryMemory().openDatabase('test.db');
    session = Session(db, httpClient: MockClient(server.handle));
    await session.load();
    data = AppData(db, session);
    await data.load();
    await session.verify(const VerifyRequest(email: 'r@example.org', code: '123456'));
    await data.onSignedIn(_user.id);
  });

  test('offline check-ins wait in the queue and sync later', () async {
    server.mode = 'offline';
    await data.checkIn(_place, foodType: 'yufka');
    await data.sync();
    expect(data.pendingCount, 1);
    expect(data.visits.single.pending, isTrue);
    expect(data.lastSyncError, isNotNull);

    server.mode = 'ok';
    await data.sync();
    expect(data.pendingCount, 0);
    expect(data.visits.single.pending, isFalse);
    expect(data.visits.single.dto.foodType, 'yufka');
  });

  test('an expired session keeps queued entries', () async {
    server.mode = '401';
    await data.checkIn(_place);
    await data.sync();
    expect(session.isLoggedIn, isFalse);
    expect(session.expired, isTrue);
    expect(data.pendingCount, 1);

    server.mode = 'ok';
    await session.verify(const VerifyRequest(email: 'r@example.org', code: '123456'));
    await data.onSignedIn(_user.id);
    expect(data.pendingCount, 0, reason: 'same account — queue is sent after re-login');
  });

  test('only the latest review edit is queued; rejected ones are dropped', () async {
    server.mode = 'offline';
    await data.saveReview(_place, const UpsertReviewRequest(ratings: {RatingItem.sauce: 3}));
    await data.saveReview(_place, const UpsertReviewRequest(ratings: {RatingItem.sauce: 5, RatingItem.falafel: 4}));
    await data.sync();
    expect(data.pendingCount, 1);
    expect(data.reviews['p1']!.dto.ratings, {RatingItem.sauce: 5, RatingItem.falafel: 4});
    expect(data.reviews['p1']!.dto.rating, 5, reason: 'the Döner score is derived right away');

    server.mode = '400';
    await data.sync();
    expect(data.pendingCount, 0);
    expect(data.reviews, isEmpty);
    expect(data.lastSyncError, contains('verworfen'));
  });

  test('a review photo waits with the review, also across a restart', () async {
    server.mode = 'offline';
    final photo = Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 1]);
    await data.checkIn(_place);
    await data.saveReview(_place, UpsertReviewRequest(ratings: const {RatingItem.sauce: 4}, photoBase64: base64.encode(photo)));
    expect(data.reviews['p1']!.dto.onSite, isTrue, reason: 'checked in here');

    final restarted = AppData(db, session);
    await restarted.load();
    expect(restarted.reviews['p1']!.photo, photo);

    server.mode = 'ok';
    await restarted.sync();
    expect(server.lastBody?['photoBase64'], base64.encode(photo));
    expect(restarted.reviews['p1']!.photo, isNull, reason: 'uploaded');
    expect(restarted.reviews['p1']!.dto.photoId, 'ph1');
  });

  test('places within the check-in radius, nearest first', () async {
    data.places['p1'] = _place;
    data.places['near'] = const PlaceDto(placeId: 'near', name: 'Nebenan', latitude: 48.0005, longitude: 7.85);
    data.places['far'] = const PlaceDto(placeId: 'far', name: 'Weit weg', latitude: 48.01, longitude: 7.85);
    expect(data.placesWithin(48.0001, 7.85, 150).map((p) => p.placeId), ['p1', 'near']);
  });

  test('logging in as someone else clears the previous account data', () async {
    server.mode = 'offline';
    await data.checkIn(_place);
    await data.onSignedIn('someone-else');
    expect(data.visits, isEmpty);
    expect(data.pendingCount, 0);
  });
}
