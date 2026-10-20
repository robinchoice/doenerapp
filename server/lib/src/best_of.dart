import 'dart:convert';

import 'package:doener_models/doener_models.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';

import 'agents.dart';
import 'deps.dart';
import 'places.dart' show rankByWeight;

const _scoreColumns = {BestOfCategory.overall: 'rating', BestOfCategory.vegan: 'vegan_rating'};
const _escape = HtmlEscape();
const _maxQuoteLength = 240;

/// "Freiburg im Breisgau" → "freiburg-im-breisgau", for the list's URL.
String citySlug(String city) => city
    .toLowerCase()
    .replaceAll('ä', 'ae')
    .replaceAll('ö', 'oe')
    .replaceAll('ü', 'ue')
    .replaceAll('ß', 'ss')
    .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
    .replaceAll(RegExp(r'^-+|-+$'), '');

String bestOfPath(String city, int year) => '/bestenliste/${citySlug(city)}/$year';

/// Once a year is over in Freiburg's time zone, its lists are computed and
/// frozen. Runs daily; a year already done is skipped.
Future<void> computeDueBestOf(Pool<void> db) async {
  final result = await db.execute("SELECT extract(year FROM now() AT TIME ZONE 'Europe/Berlin')::int - 1");
  final year = result.first.first as int;
  if (year >= firstBestOfYear) await computeBestOf(db, year);
}

/// Stores every city's lists of [year] in `best_of`: all places that qualify,
/// in ranking order. Later edits of reviews don't change them any more.
Future<void> computeBestOf(Pool<void> db, int year) => db.runTx((tx) async {
      final claimed = await tx.execute(
        Sql.named('INSERT INTO best_of_years (year) VALUES (@year:int4) ON CONFLICT DO NOTHING RETURNING year'),
        parameters: {'year': year},
      );
      if (claimed.isEmpty) return;
      for (final category in BestOfCategory.values) {
        final column = _scoreColumns[category];
        final rows = await query(
          tx,
          'SELECT p.id, p.name, p.city, avg(r.$column)::float8 AS avg, count(*)::int AS n '
          'FROM reviews r JOIN places p ON p.id = r.place_id '
          "WHERE r.$column IS NOT NULL AND p.city IS NOT NULL AND p.business_status IS DISTINCT FROM 'FUTURE_OPENING' "
          "AND p.business_status IS DISTINCT FROM 'CLOSED_PERMANENTLY' "
          "AND r.updated_at >= make_timestamptz(@year:int4, 1, 1, 0, 0, 0, 'Europe/Berlin') "
          "AND r.updated_at < make_timestamptz(@year:int4 + 1, 1, 1, 0, 0, 0, 'Europe/Berlin') "
          'GROUP BY p.id',
          {'year': year},
        );
        final byCity = <String, List<Map<String, dynamic>>>{};
        for (final row in rows) {
          byCity.putIfAbsent(row['city'] as String, () => []).add(row);
        }
        for (final MapEntry(key: city, value: places) in byCity.entries) {
          // The city's mean counts every review of the year, qualified or not.
          final ranked = [for (final r in rankByWeight(places)) if ((r['n'] as int) >= bestOfMinReviews) r];
          if (ranked.length < bestOfMinPlaces) continue;
          for (final (i, r) in ranked.indexed) {
            await tx.execute(
              Sql.named('INSERT INTO best_of (year, city, category, rank, place_id, average, count) '
                  'VALUES (@year:int4, @city, @category, @rank:int4, @place:uuid, @avg:float8, @n:int4)'),
              parameters: {'year': year, 'city': city, 'category': category.name, 'rank': i + 1, 'place': r['id'], 'avg': r['avg'], 'n': r['n']},
            );
          }
        }
      }
    });

const _latestYear = '(SELECT max(year) FROM best_of_years)';

/// The seals of a place (Google place ID) from the latest lists.
Future<List<AwardDto>> latestAwards(Session db, String placeId) async {
  final rows = await query(
    db,
    'SELECT b.* FROM best_of b JOIN places p ON p.id = b.place_id '
    'WHERE p.google_place_id = @id AND b.rank <= @ranks:int4 AND b.year = $_latestYear ORDER BY b.category, b.rank',
    {'id': placeId, 'ranks': bestOfAwardedRanks},
  );
  return [
    for (final r in rows)
      AwardDto(
        year: r['year'] as int,
        city: r['city'] as String,
        category: BestOfCategory.values.byName(r['category'] as String),
        rank: r['rank'] as int,
        average: r['average'] as double,
        count: r['count'] as int,
        path: bestOfPath(r['city'] as String, r['year'] as int),
      ),
  ];
}

/// The awarded places of [city]'s latest list, null if it has none.
Future<BestOfDto?> latestBestOf(Session db, String city, BestOfCategory category) async {
  final rows = await query(
    db,
    'SELECT b.year, b.rank, p.google_place_id, p.name FROM best_of b JOIN places p ON p.id = b.place_id '
    'WHERE b.city = @city AND b.category = @category AND b.rank <= @ranks:int4 AND b.year = $_latestYear ORDER BY b.rank',
    {'city': city, 'category': category.name, 'ranks': bestOfAwardedRanks},
  );
  if (rows.isEmpty) return null;
  final year = rows.first['year'] as int;
  return BestOfDto(
    year: year,
    city: city,
    category: category,
    path: bestOfPath(city, year),
    entries: [
      for (final r in rows) BestOfEntryDto(rank: r['rank'] as int, placeId: r['google_place_id'] as String, name: r['name'] as String),
    ],
  );
}

String _thousands(int n, {required bool english}) =>
    n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (_) => english ? ',' : '.');

String formatScore(double value, {required bool english}) {
  final text = value.toStringAsFixed(1);
  return english ? text : text.replaceAll('.', ',');
}

/// `/bestenliste/<city>/<year>` — the public list of a city and year, German
/// or with `?lang=en` English. Quotes are the longest review text of that
/// year, without a name; a deleted review takes its quote along.
Future<Response> bestOfPage(Deps deps, Request request, String slug, String yearText) async {
  final english = request.url.queryParameters['lang'] == 'en';
  String t(String de, String en) => english ? en : de;
  final year = int.tryParse(yearText);
  final cities = year == null
      ? const <Map<String, dynamic>>[]
      : await query(deps.db, 'SELECT DISTINCT city FROM best_of WHERE year = @year:int4', {'year': year});
  final city = [for (final c in cities) c['city'] as String].where((c) => citySlug(c) == slug).firstOrNull;
  if (year == null || city == null) {
    return _page(404, english, '<title>${t('Bestenliste nicht gefunden', 'List not found')}</title>',
        '<h1 class="display">${t('Diese Bestenliste gibt es nicht', 'There is no such list')}</h1>'
        '<p class="lead muted">${t('Die Bestenliste eines Jahres erscheint am 1. Januar danach.', 'A year\'s list comes out on 1 January after it.')}</p>');
  }

  final rows = await query(
    deps.db,
    'SELECT b.*, p.google_place_id, p.name, p.address FROM best_of b JOIN places p ON p.id = b.place_id '
    'WHERE b.year = @year:int4 AND b.city = @city ORDER BY b.category, b.rank',
    {'year': year, 'city': city},
  );
  final byCategory = <BestOfCategory, List<Map<String, dynamic>>>{};
  for (final r in rows) {
    byCategory.putIfAbsent(BestOfCategory.values.byName(r['category'] as String), () => []).add(r);
  }

  Future<String?> quote(Map<String, dynamic> row, BestOfCategory category) async {
    final found = await queryOne(
      deps.db,
      "SELECT text FROM reviews WHERE place_id = @place:uuid AND ${_scoreColumns[category]} IS NOT NULL AND btrim(coalesce(text, '')) <> '' "
      "AND updated_at >= make_timestamptz(@year:int4, 1, 1, 0, 0, 0, 'Europe/Berlin') "
      "AND updated_at < make_timestamptz(@year:int4 + 1, 1, 1, 0, 0, 0, 'Europe/Berlin') "
      'ORDER BY length(text) DESC LIMIT 1',
      {'place': row['place_id'], 'year': year},
    );
    final text = (found?['text'] as String?)?.trim();
    if (text == null) return null;
    if (text.length <= _maxQuoteLength) return text;
    final cut = text.substring(0, _maxQuoteLength);
    return '${cut.substring(0, cut.lastIndexOf(' ') > 0 ? cut.lastIndexOf(' ') : cut.length)} …';
  }

  final overall = byCategory[BestOfCategory.overall] ?? const [];
  final sections = StringBuffer();
  for (final category in BestOfCategory.values) {
    final entries = byCategory[category];
    if (entries == null) continue;
    final vegan = category == BestOfCategory.vegan;
    sections.write('<h2 class="sect">${vegan ? t('Vegan', 'Vegan') : t('Gesamt', 'Overall')}</h2>');
    for (final r in entries.take(bestOfAwardedRanks)) {
      final q = await quote(r, category);
      sections.write('<div class="win"><span class="n num ${vegan ? 'v' : ''}">${r['rank']}</span><div>'
          '<h3 class="display">${_escape.convert(r['name'] as String)}</h3>'
          '<p class="muted">${r['address'] == null ? '' : '${_escape.convert(r['address'] as String)} · '}'
          '${t('Ø', 'Avg.')} ${formatScore(r['average'] as double, english: english)} · ${r['count']} ${t('Bewertungen', 'reviews')}</p>'
          '${q == null ? '' : '<q>${_escape.convert(q)}</q>'}</div></div>');
    }
    if (entries.length > bestOfAwardedRanks) {
      sections.write('<details><summary>${t('Plätze', 'Ranks')} ${bestOfAwardedRanks + 1}–${entries.length}</summary>');
      for (final r in entries.skip(bestOfAwardedRanks)) {
        sections.write('<div class="row"><span class="num muted">${r['rank']}</span><span>${_escape.convert(r['name'] as String)}</span>'
            '<span class="num">${formatScore(r['average'] as double, english: english)}</span></div>');
      }
      sections.write('</details>');
    }
  }

  final reviewCount = _thousands(overall.fold<int>(0, (sum, r) => sum + (r['count'] as int)), english: english);
  final otherYears = await query(deps.db, 'SELECT DISTINCT year FROM best_of WHERE city = @city AND year <> @year:int4 ORDER BY year DESC',
      {'city': city, 'year': year});
  final title = t('Die besten Döner in $city $year', 'The best döner in $city $year');
  final top = [for (final r in overall.take(bestOfAwardedRanks)) '${r['rank']}. ${r['name']}'].join(' · ');
  final base = deps.config.publicBase(request.requestedUri);
  final url = '$base${bestOfPath(city, year)}';
  final head = '''<title>${_escape.convert(title)}</title>
<meta name="description" content="${_escape.convert(top)}">
<meta property="og:site_name" content="Döner App">
<meta property="og:type" content="article">
<meta property="og:title" content="${_escape.convert(title)}">
<meta property="og:description" content="${_escape.convert(top)}">
<meta property="og:url" content="${_escape.convert(url)}${english ? '?lang=en' : ''}">
<meta property="og:image" content="${_escape.convert(base)}/og-image-${english ? 'en' : 'de'}.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image">
<link rel="alternate" hreflang="de" href="${_escape.convert(url)}">
<link rel="alternate" hreflang="en" href="${_escape.convert(url)}?lang=en">''';
  final body = '''<h1 class="display">${_escape.convert(title)}</h1>
<div class="rule"></div>
<p class="lead muted">${overall.isEmpty ? '' : t('In der Wertung: ${overall.length} Läden mit mindestens $bestOfMinReviews Bewertungen aus $year, zusammen $reviewCount.', 'Ranked: ${overall.length} shops with at least $bestOfMinReviews reviews from $year, $reviewCount in all.')}</p>
$sections
<div class="method"><b>${t('So entsteht die Liste.', 'How the list is made.')}</b> ${t('Jede:r bewertet einmal pro Laden, eine neue Bewertung ersetzt die alte. Gezählt werden die Bewertungen aus $year, ein Laden braucht mindestens $bestOfMinReviews davon. Sortiert wird nach gewichtetem Schnitt: Jeder Laden startet mit $rankingPriorWeight gedachten Bewertungen in Höhe des Stadtschnitts, so schlägt eine einzelne 5 nicht viele 4,5er. Angezeigt werden der echte Schnitt und die Anzahl. Ob jemand wirklich dort gegessen hat, prüfen wir nicht. Läden können sich keinen Platz kaufen. Zitate stammen aus Bewertungen, ohne Namen.', 'One review per person and shop; a new one replaces the old. Reviews from $year count, a shop needs at least $bestOfMinReviews of them. Sorted by weighted average: each shop starts with $rankingPriorWeight imagined reviews at the city average, so a single 5 can\'t beat many 4.5s. Shown are the real average and count. We don\'t check whether someone really ate there. Shops can\'t buy a place. Quotes come from reviews, without names.')}</div>
<div class="ctas"><a class="btn btn-main" href="/app">${t('Selbst bewerten', 'Rate a shop')}</a><button class="btn btn-ghost" id="share" type="button">${t('Teilen', 'Share')}</button></div>
${otherYears.isEmpty ? '' : '<p class="years">${t('Frühere Jahre', 'Earlier years')}: ${[for (final y in otherYears) '<a href="${bestOfPath(city, y['year'] as int)}${english ? '?lang=en' : ''}">${y['year']}</a>'].join(' · ')}</p>'}
<p class="source muted">${t('Ortsdaten: Google Maps', 'Place data: Google Maps')}</p>
<script>
  document.getElementById('share').addEventListener('click', async (e) => {
    const data = {title: document.title, url: location.href};
    if (navigator.share) return navigator.share(data).catch(() => {});
    await navigator.clipboard.writeText(location.href);
    e.target.textContent = '${t('Link kopiert', 'Link copied')}';
  });
</script>''';
  return _page(200, english, head, body, otherLang: english ? bestOfPath(city, year) : '${bestOfPath(city, year)}?lang=en');
}

/// Every best-of list as Markdown for agents (agents.dart): places, averages and
/// counts like on the page, but no quotes, they come from single reviews.
Future<List<PublicPage>> bestOfPublicPages(Session db, {required bool english}) async {
  String t(String de, String en) => english ? en : de;
  final rows = await query(
    db,
    'SELECT b.year, b.city, b.category, b.rank, b.average, b.count, p.name, p.address FROM best_of b '
    'JOIN places p ON p.id = b.place_id ORDER BY b.year DESC, b.city, b.rank',
  );
  final lists = <String, List<Map<String, dynamic>>>{};
  for (final r in rows) {
    lists.putIfAbsent(bestOfPath(r['city'] as String, r['year'] as int), () => []).add(r);
  }
  final pages = <PublicPage>[];
  for (final MapEntry(key: path, value: entries) in lists.entries) {
    final (city, year) = (entries.first['city'] as String, entries.first['year'] as int);
    List<Map<String, dynamic>> of(BestOfCategory c) => [for (final r in entries) if (r['category'] == c.name) r];
    String line(Map<String, dynamic> r) => '${r['rank']}. ${r['name']}${r['address'] == null ? '' : ' – ${r['address']}'} · '
        '${t('Ø', 'Avg.')} ${formatScore(r['average'] as double, english: english)} · ${r['count']} ${t('Bewertungen', 'reviews')}';
    final top = [for (final r in of(BestOfCategory.overall).take(bestOfAwardedRanks)) '${r['rank']}. ${r['name']}'];
    pages.add((
      path: path,
      title: t('Die besten Döner in $city $year', 'The best döner in $city $year'),
      description: top.isEmpty ? t('Bestenliste $year', 'Best-of list $year') : top.join(' · '),
      body: [
        t('Läden mit mindestens $bestOfMinReviews Bewertungen aus $year, sortiert nach gewichtetem Schnitt. '
            'Angezeigt werden der echte Schnitt (Ø) und die Anzahl der Bewertungen.',
            'Shops with at least $bestOfMinReviews reviews from $year, sorted by weighted average. '
            'Shown are the real average (Avg.) and the number of reviews.'),
        for (final category in BestOfCategory.values)
          if (of(category).isNotEmpty)
            '## ${category == BestOfCategory.vegan ? 'Vegan' : t('Gesamt', 'Overall')}\n\n${of(category).map(line).join('\n')}',
      ].join('\n\n'),
    ));
  }
  return pages;
}

Response _page(int status, bool english, String head, String body, {String? otherLang}) => Response(
      status,
      headers: {'content-type': 'text/html; charset=utf-8'},
      body: '''<!DOCTYPE html>
<html lang="${english ? 'en' : 'de'}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
$head
<link rel="icon" type="image/png" href="/favicon.png">
<style>
@font-face { font-family: Bricolage; src: url(/assets/assets/fonts/BricolageGrotesque.ttf); font-weight: 200 800; font-stretch: 75% 100%; font-display: swap; }
:root {
  --night: #0E0D12; --raised: #16151B; --text: #F2F0EA; --muted: #9A98A3; --line: rgba(255,255,255,.07);
  --ink: #17171A; --grad: linear-gradient(45deg, #F6A94A, #F3BA4D, #D7C45B); --vgrad: linear-gradient(45deg, #BCC768, #94CB7B, #6CCF8E);
}
* { box-sizing: border-box; margin: 0; }
body { font: 16px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; -webkit-font-smoothing: antialiased; background: var(--night); color: var(--text); }
a { color: inherit; }
.display { font-family: Bricolage, "Arial Narrow", sans-serif; font-weight: 790; font-stretch: 78%; letter-spacing: -.01em; line-height: 1.05; }
.num { font-family: Bricolage, "Arial Narrow", sans-serif; font-weight: 800; font-stretch: 75%; line-height: 1; }
.muted { color: var(--muted); }
main { max-width: 680px; margin: 0 auto; padding: 0 20px; }
.nav { display: flex; align-items: center; justify-content: space-between; padding: 20px 0; }
.brand { display: flex; align-items: center; gap: 10px; font-size: 20px; text-decoration: none; }
.brand img { width: 36px; height: 36px; border-radius: 9px; }
h1 { font-size: clamp(40px, 9vw, 64px); margin: 28px 0 14px; }
.rule { height: 4px; width: 110px; border-radius: 2px; background: var(--grad); }
.lead { font-size: 17px; margin: 16px 0 8px; }
.sect { font: 600 13px system-ui, sans-serif; text-transform: uppercase; letter-spacing: .07em; color: var(--muted); margin: 32px 0 4px; }
.win { display: flex; gap: 16px; padding: 16px 0; border-bottom: 1px solid var(--line); }
.win .n { font-size: 52px; width: 36px; flex: none; background: var(--grad); -webkit-background-clip: text; background-clip: text; color: transparent; }
.win .n.v { background-image: var(--vgrad); }
.win h3 { font-size: 26px; }
.win p { font-size: 14px; margin-top: 2px; }
.win q { display: block; color: var(--muted); font-size: 15px; margin-top: 6px; }
details { margin-top: 10px; color: var(--muted); }
summary { cursor: pointer; padding: 8px 0; }
.row { display: flex; gap: 14px; padding: 8px 0; border-bottom: 1px solid var(--line); color: var(--text); }
.row span:nth-child(2) { flex: 1; }
.method { background: var(--raised); border-radius: 18px; padding: 16px 18px; font-size: 14px; color: var(--muted); margin-top: 32px; }
.method b { color: var(--text); }
.ctas { display: flex; gap: 12px; margin-top: 20px; flex-wrap: wrap; }
.btn { display: inline-flex; align-items: center; justify-content: center; padding: 13px 22px; border-radius: 14px; font: 600 16px system-ui, sans-serif; text-decoration: none; border: 0; cursor: pointer; }
.btn-main { background: var(--grad); color: var(--ink); }
.btn-ghost { background: transparent; color: inherit; box-shadow: inset 0 0 0 1.5px currentColor; }
.source { font-size: 12px; margin-top: 20px; }
.years { margin-top: 24px; }
.foot { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 28px 0 40px; margin-top: 40px; flex-wrap: wrap; border-top: 1px solid var(--line); color: var(--muted); font-size: 14px; }
.sender { display: flex; align-items: center; gap: 10px; text-decoration: none; }
.sender span { font-family: Bricolage, "Arial Narrow", sans-serif; font-weight: 650; font-stretch: 80%; }
.mark { position: relative; display: inline-block; }
.mark img { height: 22px; display: block; }
.mark::after { content: ""; position: absolute; left: 0; right: 0; bottom: -5px; height: 2px; background: linear-gradient(90deg,#F2545B,#FB8C45,#F2C14E,#6CCF8E,#46BFE0,#8E92F8,#C39BF2); opacity: .45; }
.mark i { position: absolute; bottom: -6px; left: 26%; width: 10%; height: 4px; background: var(--grad); z-index: 1; }
.foot nav { display: flex; gap: 18px; }
</style>
</head>
<body><main>
<header class="nav"><a class="brand display" href="${english ? '/en' : '/'}"><img src="/icons/Icon-192.png" alt="">Döner App</a>${otherLang == null ? '' : '<a class="muted" href="${_escape.convert(otherLang)}">${english ? 'Deutsch' : 'English'}</a>'}</header>
$body
<footer class="foot">
  <a class="sender" href="https://pleasance.org"><span>${english ? 'a tool by' : 'ein Werkzeug von'}</span><span class="mark"><img src="/assets/assets/pleasance-wordmark.svg" alt="Pleasance"><i></i></span></a>
  <nav><a href="/datenschutz">${english ? 'Privacy (German)' : 'Datenschutz'}</a><a href="https://pleasance.org/impressum">${english ? 'Legal notice' : 'Impressum'}</a></nav>
</footer>
</main></body>
</html>
''',
    );
