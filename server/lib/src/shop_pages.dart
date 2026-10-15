import 'dart:convert';

import 'package:doener_models/doener_models.dart';
import 'package:qr/qr.dart';
import 'package:shelf/shelf.dart';

import 'best_of.dart';
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
  final awards = name == null ? const <AwardDto>[] : await latestAwards(deps.db, placeId);
  final content = '${[for (final a in awards) '<p class="award">${_escape.convert(_awardText(a))}</p>'].join()}'
      '<p>Gib Soße, Fleisch, Salat und Brot eine Note. Aus allen Bewertungen entsteht das Ranking'
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
  .award { margin: 0 0 4px; font-weight: 800; letter-spacing: .04em; text-transform: uppercase; color: #965410; }
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
<p class="steps">QR-Code scannen, Soße, Fleisch, Salat und Brot benoten –<br>daraus entsteht das Döner-Ranking${city == null ? '' : ' von ${_escape.convert(city)}'}.</p>
<p class="source">Döner App · Ortsdaten: Google Maps</p>
<button onclick="window.print()">Drucken</button>
</main></body>''',
  );
}

String _awardText(AwardDto a) => a.category == BestOfCategory.vegan
    ? 'Vegan: Platz ${a.rank} in ${a.city} ${a.year}'
    : 'Platz ${a.rank} in ${a.city} ${a.year}';

/// `/siegel/<placeId>` — the place's seals from the latest best-of lists to
/// print, 15 × 5 cm each, German or with `?lang=en` English. The QR code
/// leads to [reviewLinkPage], like the poster's.
Future<Response> sealPage(Deps deps, Request request, String placeId) async {
  final place = await _place(deps, placeId);
  final awards = place == null ? const <AwardDto>[] : await latestAwards(deps.db, placeId);
  if (awards.isEmpty) {
    return request.url.queryParameters['lang'] == 'en'
        ? _html(404, '<title>No seal</title></head><body><main><h1>This shop has no seal</h1></main></body>', lang: 'en')
        : _html(404, '<title>Kein Siegel</title></head><body><main><h1>Dieser Laden hat kein Siegel</h1></main></body>');
  }
  final english = request.url.queryParameters['lang'] == 'en';
  final link = '${_base(deps, request)}/b/$placeId';
  final name = _escape.convert(place!['name'] as String);
  return _html(
    200,
    '''<title>Siegel: $name</title>
<style>
  @font-face { font-family: Bricolage; src: url(/assets/assets/fonts/BricolageGrotesque.ttf); font-weight: 200 800; font-stretch: 75% 100%; }
  @page { size: A4; margin: 15mm; }
  body { background: #fff; }
  main { max-width: 170mm; margin: 0 auto; padding: 24px; }
  .seal { display: block; width: 150mm; max-width: 100%; height: auto; margin: 0 0 10mm; }
  p { color: #5E5E66; font-size: 0.9rem; }
  a { color: inherit; }
  button { margin: 8px 12px 0 0; padding: 12px 24px; border: 0; border-radius: 12px; background: #17171A; color: #fff; font: 600 1rem system-ui, sans-serif; cursor: pointer; }
  @media print { p, button { display: none; } main { padding: 0; } }
</style>
</head>
<body><main>
${[for (final a in awards) _sealSvg(a, link, english: english)].join('\n')}
<p>${english ? 'Print on label paper or have it printed as a window sticker, 15 × 5 cm.' : 'Auf Etikettenpapier drucken oder als Fensteraufkleber drucken lassen, 15 × 5 cm.'}
<a href="?lang=${english ? 'de' : 'en'}">${english ? 'Deutsche Fassung' : 'English version'}</a></p>
<button onclick="window.print()">${english ? 'Print' : 'Drucken'}</button>
</main></body>''',
    lang: english ? 'en' : 'de',
  );
}

/// The seal as approved in the mockups ("Banderole"): light, the skewer tile,
/// rank and year, the numbers behind them and the QR code.
String _sealSvg(AwardDto award, String link, {required bool english}) {
  final vegan = award.category == BestOfCategory.vegan;
  final id = award.category.name;
  // The year takes the middle deep tone: a gradient on a tspan spoils Chrome's print.
  final (glow, year) = vegan ? (['#BCC768', '#94CB7B', '#6CCF8E'], '#3D6732') : (['#F6A94A', '#F3BA4D', '#D7C45B'], '#8B5D0A');
  String gradient(String name, List<String> stops) => '<linearGradient id="$name-$id" x1="0" y1="1" x2="1" y2="0">'
      '<stop offset="0" stop-color="${stops[0]}"/><stop offset=".5" stop-color="${stops[1]}"/><stop offset="1" stop-color="${stops[2]}"/></linearGradient>';
  final city = award.city.toUpperCase();
  final head = vegan
      ? (english ? 'VEGAN RANKING $city' : 'VEGAN-RANKING $city')
      : (english ? 'DÖNER RANKING $city' : 'DÖNER-RANKING $city');
  // Long city names are squeezed so the lines don't run into the QR code; rank and
  // year always are, in case the display font is missing.
  final fit = head.length > 28 ? ' textLength="250" lengthAdjust="spacingAndGlyphs"' : '';
  final origin = english ? 'Rated by people in ${award.city}' : 'Bewertet von Leuten aus ${award.city}';
  final fitOrigin = origin.length > 36 ? ' textLength="232" lengthAdjust="spacingAndGlyphs"' : '';
  final score = formatScore(award.average, english: english);
  final stats = english
      ? 'Avg. $score from ${award.count} reviews in ${award.year}'
      : 'Ø $score aus ${award.count} Bewertungen im Jahr ${award.year}';
  final qr = _qrModules(link);
  const display = 'font-family="Bricolage, Arial Narrow, sans-serif" font-weight="800" font-stretch="78%"';
  final label = english ? 'No. ${award.rank} in ${award.city} ${award.year}' : _awardText(award);
  return '''<svg class="seal" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 480 160" role="img" aria-label="${_escape.convert(label)}">
<defs>${gradient('glow', glow)}${gradient('tile', const ['#F6A94A', '#F3BA4D', '#D7C45B'])}<clipPath id="clip-$id"><rect width="480" height="160" rx="14"/></clipPath></defs>
<g clip-path="url(#clip-$id)"><rect width="480" height="160" fill="#F4F4F1"/><rect y="154" width="480" height="6" fill="url(#glow-$id)"/></g>
<rect x="18" y="18" width="58" height="58" rx="14" fill="#121117"/>
<g transform="translate(18,18) scale(.58)"><path d="M41 26H59M32 33H68Q66 54 59 67H41Q34 54 32 33ZM50 67V74" fill="none" stroke="url(#tile-$id)" stroke-width="9" stroke-linecap="round" stroke-linejoin="round"/></g>
<text x="94" y="36" $display font-size="15" letter-spacing="1.5" fill="#5E5E66"$fit>${_escape.convert(head)}</text>
<text x="92" y="94" $display font-size="57" fill="#17171A" textLength="244" lengthAdjust="spacingAndGlyphs">${english ? 'No.' : 'Platz'} ${award.rank}<tspan dx="12" fill="$year">${award.year}</tspan></text>
<text x="94" y="120" font-family="system-ui, sans-serif" font-size="13" fill="#17171A">${_escape.convert(stats)}</text>
<text x="94" y="139" font-family="system-ui, sans-serif" font-size="11.5" fill="#5E5E66"$fitOrigin>${_escape.convert(origin)}</text>
<svg x="358" y="12" width="106" height="106" viewBox="0 0 ${qr.size} ${qr.size}" shape-rendering="crispEdges"><rect width="${qr.size}" height="${qr.size}" fill="#fff"/><path d="${qr.path}" fill="#17171A"/></svg>
<text x="411" y="138" text-anchor="middle" font-family="system-ui, sans-serif" font-size="10.5" font-weight="700" fill="#17171A">${english ? 'Scan &amp; rate it' : 'Scannen &amp; mitbewerten'}</text>
</svg>''';
}

/// One square per dark module, with the quiet zone around them.
({String path, int size}) _qrModules(String data) {
  final image = QrImage(QrCode(payload: QrPayload.fromString(data), errorCorrectLevel: QrErrorCorrectLevel.medium));
  final modules = StringBuffer();
  for (var row = 0; row < image.moduleCount; row++) {
    for (var col = 0; col < image.moduleCount; col++) {
      if (image.isDark(row, col)) modules.write('M${col + 4} ${row + 4}h1v1h-1z');
    }
  }
  return (path: modules.toString(), size: image.moduleCount + 8);
}

/// The QR code as SVG, with the quiet zone around it.
String _qrSvg(String data) {
  final qr = _qrModules(data);
  return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${qr.size} ${qr.size}" shape-rendering="crispEdges" role="img" aria-label="QR-Code">'
      '<rect width="${qr.size}" height="${qr.size}" fill="#fff"/><path d="${qr.path}" fill="#000"/></svg>';
}

Response _html(int status, String rest, {String lang = 'de'}) => Response(
      status,
      headers: {'content-type': 'text/html; charset=utf-8'},
      body: '''<!DOCTYPE html>
<html lang="$lang">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>body { margin: 0; font-family: system-ui, sans-serif; background: #fff8f0; color: #222; }</style>
$rest
</html>
''',
    );
