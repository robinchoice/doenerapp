import 'package:http/http.dart' as http;
import 'package:postgres/postgres.dart';

import 'config.dart';
import 'mailer.dart';
import 'push.dart';

class Deps {
  final Pool<void> db;
  final Config config;
  final Mailer mailer;
  final http.Client httpClient;
  final Pusher pusher;

  const Deps({required this.db, required this.config, required this.mailer, required this.httpClient, this.pusher = const LogPusher()});
}

/// Rows as column maps — the only way handlers read query results.
Future<List<Map<String, dynamic>>> query(Session db, String sql, [Map<String, Object?> params = const {}]) async {
  final result = await db.execute(Sql.named(sql), parameters: params);
  return result.map((r) => r.toColumnMap()).toList();
}

Future<Map<String, dynamic>?> queryOne(Session db, String sql, [Map<String, Object?> params = const {}]) async {
  final rows = await query(db, sql, params);
  return rows.isEmpty ? null : rows.first;
}
