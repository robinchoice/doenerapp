import 'dart:convert';

import 'package:http/http.dart' as http;

import 'command.dart';

/// The same HTTP API as the app, with the token of this device as bearer.
/// Errors of the API come as `{error}` and keep their text.
class Client {
  final String url;
  final String? token;
  final http.Client _http;

  Client(this.url, this.token, this._http);

  Future<Object?> get(String path, [Map<String, String>? query]) => _send('GET', path, query: query);
  Future<Object?> post(String path, [Map<String, Object?>? body]) => _send('POST', path, body: body ?? const {});
  Future<Object?> put(String path, [Map<String, Object?>? body]) => _send('PUT', path, body: body ?? const {});
  Future<Object?> delete(String path) => _send('DELETE', path);

  Future<Object?> _send(String method, String path, {Map<String, String>? query, Object? body}) async {
    final request = http.Request(method, Uri.parse('$url/api/v1$path').replace(queryParameters: query));
    // The token never follows a redirect to another address
    request.followRedirects = false;
    if (token != null) request.headers['authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final http.Response res;
    try {
      res = await http.Response.fromStream(await _http.send(request));
    } on Exception {
      throw Failure('Keine Verbindung zu $url.', Exit.error);
    }
    Object? json;
    try {
      json = res.body.isEmpty ? null : jsonDecode(res.body);
    } on FormatException {
      throw const Failure('Unerwartete Antwort der API.', Exit.error);
    }
    if (res.statusCode >= 300) {
      final message = json is Map && json['error'] is String ? json['error'] as String : 'Fehler ${res.statusCode} der API.';
      throw Failure(message, res.statusCode == 401 ? Exit.loggedOut : Exit.error);
    }
    return json;
  }
}

/// Reads a list answer item by item, see [parse].
List<T> parseList<T>(Object? json, T Function(Map<String, dynamic>) fromJson) {
  if (json is! List) throw const Failure('Unerwartete Antwort der API.', Exit.error);
  return [for (final item in json) parse(item, fromJson)];
}

/// Reads an answer with a model's fromJson; anything unexpected is a bad answer.
T parse<T>(Object? json, T Function(Map<String, dynamic>) fromJson) {
  try {
    return fromJson(json as Map<String, dynamic>);
  } on TypeError {
    throw const Failure('Unerwartete Antwort der API.', Exit.error);
  }
}
