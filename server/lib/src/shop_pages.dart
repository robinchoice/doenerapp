import 'dart:convert';

import 'package:qr/qr.dart';
import 'package:shelf/shelf.dart';

import 'deps.dart';

/// Google place IDs; anything else is not looked up.
final _placeIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,300}$');

const _escape = HtmlEscape(HtmlEscapeMode.attribute);

String _base(Deps deps, Request request) => deps.config.publicUrl ?? request.requestedUri.origin;

Future<Map<String, dynamic>?> _place(Deps deps, String placeId) async => _placeIdPattern.hasMatch(placeId)
    ? await queryOne(deps.db, 'SELECT name, city FROM place_view WHERE google_place_id = @id', {'id': placeId})
    : null;

/// `/b/<placeId>` — where the QR code of a shop's poster leads: straight to
/// its review in the app, or in the web app for those without it. Google's
/// terms allow the name only with the source named. A shop that dropped out
/// of the cache gets a page without its name; the app loads it again.
Future<Response> reviewLinkPage(Deps deps, Request request, String placeId) async {
  if (!_placeIdPattern.hasMatch(placeId)) {
    return _html(404, '<title>Laden nicht gefunden</title></head><body><main><h1>Laden nicht gefunden</h1></main></body>');
  }
  final place = await _place(deps, placeId);
  final appUrl = deps.config.appDownloadUrl;
  final name = place == null ? null : _escape.convert(place['name'] as String);
  final city = place?['city'] as String?;
  final title = name == null ? 'Wie war dein Döner?' : 'Wie war dein Döner bei $name?';
  final content = '<p>Gib Soße, Fleisch und Brot eine Note. Aus allen Bewertungen entsteht das Ranking'
      '${city == null ? ' deiner Stadt' : ' von ${_escape.convert(city)}'}.</p>'
      '<a class="button" href="/app?review=$placeId">Jetzt bewerten</a>'
      '${appUrl == null ? '' : '<a class="button secondary" href="${_escape.convert(appUrl)}">App holen</a>'}'
      '${name == null ? '' : '<p class="source">Ortsdaten: Google Maps</p>'}';
  return _html(
    200,
    '''<title>$title</title>
<meta property="og:title" content="$title">
<meta property="og:description" content="Bewerte den Laden in der Döner App.">
<meta property="og:image" content="${_escape.convert(_base(deps, request))}/icons/Icon-512.png">
<style>
  main { max-width: 420px; margin: 0 auto; padding: 48px 24px; text-align: center; }
  img { border-radius: 50%; }
  h1 { font-size: 1.5rem; }
  .button { display: block; margin: 12px 0; padding: 14px; border-radius: 12px; background: #ff8c00; color: #fff; text-decoration: none; font-weight: 600; }
  .button.secondary { background: none; color: #ff8c00; border: 2px solid #ff8c00; }
  .source { font-size: 0.75rem; color: #888; margin-top: 24px; }
</style>
</head>
<body><main><img src="/icons/Icon-192.png" alt="" width="96" height="96"><h1>$title</h1>$content</main></body>''',
  );
}

/// `/aushang/<placeId>` — a poster to print and hang up in the shop. Its QR
/// code leads to [reviewLinkPage].
Future<Response> posterPage(Deps deps, Request request, String placeId) async {
  final place = await _place(deps, placeId);
  if (place == null) {
    return _html(404, '<title>Laden nicht gefunden</title></head><body><main><h1>Laden nicht gefunden</h1></main></body>');
  }
  final name = _escape.convert(place['name'] as String);
  final city = place['city'] as String?;
  final link = '${_base(deps, request)}/b/$placeId';
  return _html(
    200,
    '''<title>Aushang: $name</title>
<style>
  @page { size: A4; margin: 15mm; }
  main { max-width: 170mm; margin: 0 auto; padding: 24px; text-align: center; }
  h1 { font-size: 2.6rem; margin: 16px 0 8px; }
  .shop { font-size: 1.5rem; font-weight: 600; margin: 0 0 24px; }
  svg { width: min(110mm, 100%); height: auto; }
  .link { font-size: 0.9rem; color: #666; word-break: break-all; }
  .steps { font-size: 1.15rem; margin: 20px 0; }
  .source { font-size: 0.75rem; color: #888; margin-top: 32px; }
  button { margin: 24px 0 0; padding: 12px 24px; border: 0; border-radius: 12px; background: #ff8c00; color: #fff; font-size: 1rem; font-weight: 600; cursor: pointer; }
  @media print { button { display: none; } body { background: #fff; } }
</style>
</head>
<body><main>
<img src="/icons/Icon-192.png" alt="" width="72" height="72">
<h1>Wie war dein Döner?</h1>
<p class="shop">$name</p>
${_qrSvg(link)}
<p class="link">${_escape.convert(link)}</p>
<p class="steps">QR-Code scannen, Soße, Fleisch und Brot benoten –<br>daraus entsteht das Döner-Ranking${city == null ? '' : ' von ${_escape.convert(city)}'}.</p>
<p class="source">Döner App · Ortsdaten: Google Maps</p>
<button onclick="window.print()">Drucken</button>
</main></body>''',
  );
}

/// The QR code as SVG, one square per dark module, with the quiet zone around it.
String _qrSvg(String data) {
  final image = QrImage(QrCode(payload: QrPayload.fromString(data), errorCorrectLevel: QrErrorCorrectLevel.medium));
  final size = image.moduleCount + 8;
  final modules = StringBuffer();
  for (var row = 0; row < image.moduleCount; row++) {
    for (var col = 0; col < image.moduleCount; col++) {
      if (image.isDark(row, col)) modules.write('M${col + 4} ${row + 4}h1v1h-1z');
    }
  }
  return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $size $size" shape-rendering="crispEdges" role="img" aria-label="QR-Code">'
      '<rect width="$size" height="$size" fill="#fff"/><path d="$modules" fill="#000"/></svg>';
}

Response _html(int status, String rest) => Response(
      status,
      headers: {'content-type': 'text/html; charset=utf-8'},
      body: '''<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>body { margin: 0; font-family: system-ui, sans-serif; background: #fff8f0; color: #222; }</style>
$rest
</html>
''',
    );
