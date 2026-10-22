import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:sentry/sentry.dart';

class ApiException implements Exception {
  final int status;
  final String message;
  const ApiException(this.status, this.message);

  const ApiException.badRequest(this.message) : status = 400;
  const ApiException.unauthorized([this.message = 'Nicht angemeldet']) : status = 401;
  const ApiException.forbidden([this.message = 'Nicht erlaubt']) : status = 403;
  const ApiException.notFound([this.message = 'Nicht gefunden']) : status = 404;
  const ApiException.conflict(this.message) : status = 409;

  @override
  String toString() => 'ApiException($status, $message)';
}

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

Response json(Object? body, {int status = 200}) =>
    Response(status, body: jsonEncode(body), headers: _jsonHeaders);

Response noContent() => Response(204);

const _maxBodyBytes = 8 * 1024 * 1024;

Future<Map<String, dynamic>> readJson(Request request) async {
  final length = request.contentLength;
  if (length != null && length > _maxBodyBytes) {
    throw const ApiException(413, 'Anfrage zu groß');
  }
  final bytes = <int>[];
  await for (final chunk in request.read()) {
    bytes.addAll(chunk);
    if (bytes.length > _maxBodyBytes) throw const ApiException(413, 'Anfrage zu groß');
  }
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map<String, dynamic>) throw const ApiException.badRequest('JSON-Objekt erwartet');
  return decoded;
}

/// Decodes the body with [fromJson]; type errors become 400s.
Future<T> readBody<T>(Request request, T Function(Map<String, dynamic>) fromJson) async {
  final body = await readJson(request);
  try {
    return fromJson(body);
  } on TypeError {
    throw const ApiException.badRequest('Ungültiger Request-Body');
  } on FormatException {
    throw const ApiException.badRequest('Ungültiger Request-Body');
  } on ArgumentError {
    throw const ApiException.badRequest('Ungültiger Request-Body');
  }
}

double queryDouble(Request request, String name, {double? fallback}) {
  final raw = request.url.queryParameters[name];
  final value = raw == null ? fallback : double.tryParse(raw);
  if (value == null || !value.isFinite) throw ApiException.badRequest('Parameter "$name" fehlt oder ist ungültig');
  return value;
}

int queryInt(Request request, String name, {required int fallback, required int min, required int max}) {
  final raw = request.url.queryParameters[name];
  final value = raw == null ? fallback : int.tryParse(raw);
  if (value == null) throw ApiException.badRequest('Parameter "$name" ist ungültig');
  return value.clamp(min, max);
}

final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', caseSensitive: false);

String requireUuid(String value, [String name = 'id']) {
  if (!_uuid.hasMatch(value)) throw ApiException.badRequest('"$name" ist keine gültige UUID');
  return value.toLowerCase();
}

Middleware errorHandling() => (inner) => (request) async {
      try {
        return await inner(request);
      } on ApiException catch (e) {
        return json({'error': e.message}, status: e.status);
      } on FormatException {
        return json({'error': 'Ungültiges JSON'}, status: 400);
      } on UniqueViolationException {
        return json({'error': 'Existiert bereits'}, status: 409);
      } catch (e, st) {
        print('Unhandled error on ${request.method} ${request.requestedUri.path}: $e\n$st');
        unawaited(Sentry.captureException(e, stackTrace: st));
        return json({'error': 'Interner Fehler'}, status: 500);
      }
    };

Middleware cors(String? origin) => (inner) => (request) async {
      if (origin == null) return inner(request);
      const headers = {
        'access-control-allow-methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
        'access-control-allow-headers': 'authorization, content-type',
        'access-control-max-age': '600',
      };
      if (request.method == 'OPTIONS') {
        return Response.ok(null, headers: {...headers, 'access-control-allow-origin': origin});
      }
      final response = await inner(request);
      return response.change(headers: {...headers, 'access-control-allow-origin': origin});
    };

/// Coolify's Traefik sets X-Forwarded-For; its last entry is the address
/// Traefik saw. Without a proxy (tests, local compose) all share 'unknown'.
String clientIp(Request request) => request.headers['x-forwarded-for']?.split(',').last.trim() ?? 'unknown';

/// Stops taking connections and waits until the open ones are done. close()
/// alone returns once the port is closed, while requests still run.
Future<void> drain(HttpServer server) async {
  await server.close();
  while (server.connectionsInfo().total > 0) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
