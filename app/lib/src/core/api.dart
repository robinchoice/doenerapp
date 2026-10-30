import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

const _productionApi = 'https://doener-api.pleasance.org/api/v1';
const _apiFromBuild = String.fromEnvironment('API_BASE');

/// Build-time default: `--dart-define=API_BASE=…`, otherwise same origin on
/// web (the server hosts the web app) and production on mobile.
String get defaultApiBase {
  if (_apiFromBuild.isNotEmpty) return _apiFromBuild;
  if (kIsWeb) return '${Uri.base.origin}/api/v1';
  return _productionApi;
}

class ApiException implements Exception {
  final int status;
  final String message;
  const ApiException(this.status, this.message);

  @override
  String toString() => message;
}

/// No response from the server (offline, timeout, DNS…) — safe to retry later.
class OfflineException implements Exception {
  const OfflineException();

  @override
  String toString() => 'Keine Verbindung zum Server';
}

class ApiClient {
  final String Function() baseUrl;
  final String? Function() token;

  /// Called when the server rejects our session token.
  void Function()? onUnauthorized;
  final http.Client _client;

  ApiClient({required this.baseUrl, required this.token, http.Client? client}) : _client = client ?? http.Client();

  Future<dynamic> get(String path, {Map<String, String>? query}) => send('GET', path, query: query);

  /// Like [get], with the response headers.
  Future<(dynamic, Map<String, String>)> getWithHeaders(String path, {Map<String, String>? query}) async {
    final response = await _send('GET', path, query: query);
    return (_decode(response), response.headers);
  }

  Future<dynamic> post(String path, [Object? body]) => send('POST', path, body: body);
  Future<dynamic> put(String path, Object? body) => send('PUT', path, body: body);
  Future<dynamic> patch(String path, Object? body) => send('PATCH', path, body: body);
  Future<dynamic> delete(String path) => send('DELETE', path);

  Future<dynamic> send(String method, String path, {Object? body, Map<String, String>? query}) async =>
      _decode(await _send(method, path, body: body, query: query));

  Future<http.Response> _send(String method, String path, {Object? body, Map<String, String>? query}) async {
    final uri = Uri.parse('${baseUrl()}$path').replace(queryParameters: query);
    final auth = token();
    final request = http.Request(method, uri)
      ..headers['accept'] = 'application/json'
      ..headers['content-type'] = 'application/json';
    if (auth != null) request.headers['authorization'] = 'Bearer $auth';
    if (body != null) request.body = jsonEncode(body);

    final http.Response response;
    try {
      response = await http.Response.fromStream(await _client.send(request).timeout(const Duration(seconds: 20)));
    } catch (e) {
      debugPrint('API $method $path failed: $e');
      throw const OfflineException();
    }
    if (response.statusCode == 401 && auth != null) onUnauthorized?.call();
    return response;
  }

  dynamic _decode(http.Response response) {
    final text = utf8.decode(response.bodyBytes);
    if (response.statusCode >= 400) {
      String message;
      try {
        message = (jsonDecode(text) as Map<String, dynamic>)['error'] as String;
      } catch (_) {
        message = 'Serverfehler (${response.statusCode})';
      }
      throw ApiException(response.statusCode, message);
    }
    return text.isEmpty ? null : jsonDecode(text);
  }
}
