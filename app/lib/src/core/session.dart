import 'package:doener_models/doener_models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:sembast/sembast.dart';

import 'api.dart';

final settingsStore = StoreRef<String, Object?>('settings');

/// Login state. The token lives in the platform keychain / keystore; the
/// user profile is cached so the app works offline after a restart.
class Session extends ChangeNotifier {
  final Database _db;
  final _secure = const FlutterSecureStorage();
  late final ApiClient api;

  Session(this._db, {http.Client? httpClient}) {
    api = ApiClient(baseUrl: () => apiBase, token: () => _token, client: httpClient)..onUnauthorized = _expire;
  }

  String? _token;
  AccountDto? user;
  String apiBase = defaultApiBase;

  /// Set when the server rejected our token; the UI offers to log in again.
  bool expired = false;

  bool get isLoggedIn => _token != null && user != null;

  Diet get diet => user?.diet ?? Diet.all;
  bool get expertMode => user?.expertMode ?? false;

  Future<void> load() async {
    apiBase = await settingsStore.record('apiBaseOverride').get(_db) as String? ?? defaultApiBase;
    _token = await _secure.read(key: 'session_token');
    final cached = await settingsStore.record('user').get(_db) as Map<String, Object?>?;
    if (_token != null && cached != null) user = AccountDto.fromJson(cached.cast<String, dynamic>());
  }

  /// Refreshes the profile. Offline or server errors keep the cached login —
  /// only a 401 (handled via [_expire]) ends the session.
  Future<void> refresh() async {
    if (_token == null) return;
    try {
      await _setUser(AccountDto.fromJson(await api.get('/auth/me') as Map<String, dynamic>));
    } on OfflineException {
      // keep cached user
    } on ApiException {
      // 401 already handled; other errors are transient
    }
  }

  Future<void> requestCode(String email, {String? inviteCode}) =>
      api.post('/auth/login', LoginRequest(email: email, inviteCode: inviteCode).toJson());

  Future<AuthResponse> verify(VerifyRequest request) async {
    final response = AuthResponse.fromJson(await api.post('/auth/verify', request.toJson()) as Map<String, dynamic>);
    _token = response.token;
    await _secure.write(key: 'session_token', value: response.token);
    expired = false;
    await _setUser(response.user);
    return response;
  }

  Future<void> updateDisplayName(String name) async {
    final json = await api.patch('/users/me', UpdateMeRequest(displayName: name).toJson());
    await _setUser(AccountDto.fromJson(json as Map<String, dynamic>));
  }

  /// Diet, expert mode, push settings and news by mail follow the account. The
  /// change shows right away and is taken back if the server doesn't take it.
  Future<void> updateSettings({Diet? diet, bool? expertMode, bool? pushFriends, bool? pushNewPlaces, bool? updateMails}) async {
    final previous = user!;
    await _setUser(AccountDto(
      id: previous.id,
      displayName: previous.displayName,
      diet: diet ?? previous.diet,
      expertMode: expertMode ?? previous.expertMode,
      admin: previous.admin,
      pushFriends: pushFriends ?? previous.pushFriends,
      pushNewPlaces: pushNewPlaces ?? previous.pushNewPlaces,
      updateMails: updateMails ?? previous.updateMails,
    ));
    try {
      final json = await api.patch(
        '/users/me',
        UpdateMeRequest(
          diet: diet,
          expertMode: expertMode,
          pushFriends: pushFriends,
          pushNewPlaces: pushNewPlaces,
          updateMails: updateMails,
        ).toJson(),
      );
      await _setUser(AccountDto.fromJson(json as Map<String, dynamic>));
    } catch (_) {
      await _setUser(previous);
      rethrow;
    }
  }

  Future<void> logout() async {
    try {
      await api.post('/auth/logout');
    } catch (_) {
      // Logging out locally must work offline too.
    }
    await _clear();
  }

  Future<void> deleteAccount() async {
    await api.delete('/users/me');
    await _clear();
  }

  Future<void> setApiBase(String? override) async {
    final value = override?.trim();
    if (value == null || value.isEmpty) {
      await settingsStore.record('apiBaseOverride').delete(_db);
      apiBase = defaultApiBase;
    } else {
      await settingsStore.record('apiBaseOverride').put(_db, value.replaceAll(RegExp(r'/+$'), ''));
      apiBase = value;
    }
    notifyListeners();
  }

  Future<void> _setUser(AccountDto value) async {
    user = value;
    await settingsStore.record('user').put(_db, value.toJson());
    notifyListeners();
  }

  void _expire() {
    expired = true;
    _clear();
  }

  Future<void> _clear() async {
    _token = null;
    user = null;
    await _secure.delete(key: 'session_token');
    await settingsStore.record('user').delete(_db);
    notifyListeners();
  }
}
