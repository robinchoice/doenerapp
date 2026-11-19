import 'dart:js_interop';

import 'package:web/web.dart' as web;

Future<String> fetchDockText(Uri url) async {
  final response = await web.window.fetch(url.toString().toJS,
      web.RequestInit(credentials: 'omit', referrerPolicy: 'no-referrer')).toDart.timeout(const Duration(seconds: 10));
  if (!response.ok) throw FormatException('Dock HTTP ${response.status}');
  return (await response.text().toDart).toDart;
}
