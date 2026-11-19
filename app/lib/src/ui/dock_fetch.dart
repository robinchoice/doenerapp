import 'dart:convert';

import 'package:http/http.dart' as http;

Future<String> fetchDockText(Uri url) async {
  final response = await http.get(url).timeout(const Duration(seconds: 10));
  if (response.statusCode != 200) throw FormatException('Dock HTTP ${response.statusCode}');
  return utf8.decode(response.bodyBytes);
}
