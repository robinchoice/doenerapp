import 'dart:convert';

import 'package:doener_models/doener_models.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';
import 'deps.dart';
import 'http.dart';

const maxTesterRequestsPerHour = 30;

void mountTesterRequests(Router router, Deps deps) {
  // POST /tester-requests {email, platform: ios|android, inviteCode?} — from the
  // landing page, no account needed. Robin gets a mail and lets the address in
  // under Profil → Tester. The invite code tells whose link brought the person.
  router.post('/tester-requests', (Request request) async {
    final body = await readJson(request);
    final email = body['email'];
    final platform = body['platform'];
    final inviteCode = body['inviteCode'] is String ? Validation.clean(body['inviteCode'] as String) : null;
    if (email is! String || !Validation.isValidEmail(email)) {
      throw const ApiException.badRequest('Ungültige E-Mail-Adresse');
    }
    if (platform != 'ios' && platform != 'android') throw const ApiException.badRequest('Ungültige Plattform');

    await deps.db.execute("DELETE FROM tester_requests WHERE created_at < now() - interval '90 days'");
    final recent = await queryOne(
      deps.db,
      "SELECT count(*)::int AS n FROM tester_requests WHERE created_at > now() - interval '1 hour'",
    );
    if ((recent!['n'] as int) >= maxTesterRequestsPerHour) {
      throw const ApiException(429, 'Zu viele Anfragen – bitte später erneut versuchen.');
    }

    final normalized = Validation.normalizeEmail(email);
    final inserted = await deps.db.execute(
      Sql.named(
        'INSERT INTO tester_requests (email, platform, invited_by) '
        'VALUES (@email, @platform, (SELECT id FROM users WHERE invite_code = @code::text)) '
        'ON CONFLICT (email, platform) DO NOTHING RETURNING id',
      ),
      parameters: {'email': normalized, 'platform': platform, 'code': inviteCode},
    );
    final to = deps.config.feedbackEmail;
    if (inserted.isNotEmpty && to != null) {
      final friend = inviteCode == null
          ? null
          : await queryOne(deps.db, 'SELECT display_name FROM users WHERE invite_code = @code', {'code': inviteCode});
      await _mailTesterRequest(deps, to, normalized, platform as String, friend?['display_name'] as String?);
    }
    return noContent();
  });

  // GET /tester-requests — open requests for admins, oldest first.
  router.get('/tester-requests', (Request request) async {
    await requireAdmin(deps, request);
    final rows = await query(
      deps.db,
      'SELECT t.id, t.email, t.platform, t.created_at, u.display_name FROM tester_requests t '
      "LEFT JOIN users u ON u.id = t.invited_by WHERE t.created_at > now() - interval '90 days' "
      'AND NOT EXISTS (SELECT 1 FROM users a WHERE a.email = t.email) ORDER BY t.created_at',
    );
    return json([
      for (final r in rows)
        TesterRequestDto(
          id: r['id'] as String,
          email: r['email'] as String,
          platform: r['platform'] as String,
          invitedBy: r['display_name'] as String?,
          createdAt: r['created_at'] as DateTime,
        ).toJson(),
    ]);
  });

  // POST /tester-requests/<id>/invite — lets the person in like /auth/invite,
  // with the TestFlight invite for iPhones. The request is done then.
  router.post('/tester-requests/<id>/invite', (Request request, String id) async {
    final admin = await requireAdmin(deps, request);
    final row = await queryOne(
        deps.db, 'SELECT email, platform, invited_by FROM tester_requests WHERE id = @id:uuid', {'id': requireUuid(id)});
    if (row == null) throw const ApiException.notFound('Anfrage nicht gefunden');
    final result = await inviteTester(deps, row['email'] as String, admin,
        platform: row['platform'] as String, friendId: row['invited_by'] as String?);
    await deps.db.execute(Sql.named('DELETE FROM tester_requests WHERE email = @email'), parameters: {'email': row['email']});
    return json(result.toJson());
  });

  // DELETE /tester-requests/<id> — turned down, without a mail.
  router.delete('/tester-requests/<id>', (Request request, String id) async {
    await requireAdmin(deps, request);
    await deps.db.execute(Sql.named('DELETE FROM tester_requests WHERE id = @id:uuid'), parameters: {'id': requireUuid(id)});
    return noContent();
  });
}

/// A failed mail doesn't fail the request: the request is stored already.
Future<void> _mailTesterRequest(Deps deps, String to, String email, String platform, String? friend) async {
  final ios = platform == 'ios';
  try {
    await deps.mailer.send(
      to: to,
      subject: 'Testanfrage ${ios ? 'iOS' : 'Android'}: $email',
      text: '$email möchte die ${ios ? 'iOS' : 'Android'}-App testen${friend == null ? '' : ', gekommen über den Link von $friend'}.\n\n'
          'Freischalten in der App unter Profil → Tester. Das legt das Konto an und schickt die Login-Mail, '
          '${ios ? 'Apple schickt die TestFlight-Einladung.' : 'die APK bzw. den Link zum Play-Test schickst du mit einer Antwort auf diese Mail.'}',
      replyTo: email,
    );
  } catch (e) {
    print('Tester request mail failed: $e');
  }
}

/// `/` (German) and `/en` — the public landing page. Logged-in browsers go
/// straight on to the web app under `/app`.
Response landingPage(Request _, {required bool english}) =>
    Response.ok(_page(english ? _en : _de), headers: {'content-type': 'text/html; charset=utf-8'});

final _de = _Texts(
  lang: 'de',
  title: 'Döner App – Der beste Döner deiner Stadt',
  description: 'Döner bewertet nach Soße, Fleisch, Salat und Brot – von Leuten, die in deiner Gegend essen.',
  ogImage: 'og-image-de.png',
  navTest: 'Testen',
  h1: 'Der beste Döner',
  h1Accent: 'deiner Stadt.',
  lead:
      'Bewertet nach Soße, Fleisch, Salat und Brot – von Leuten, die in deiner Gegend essen. '
      'Und du siehst, wo deine Freunde gerade sitzen.',
  ctaTest: 'Für den Test anmelden',
  ctaBrowser: 'Im Browser öffnen',
  stores: 'iPhone über TestFlight · Android über den Play-Test · kostenlos',
  ranking: 'Ranking Freiburg',
  chips: ['Gesamt', 'Soße', 'Fleisch', 'Brot'],
  reviews: 'Bew.',
  friends: 'Freunde',
  placeData: 'Ortsdaten: Google Maps',
  tabs: ['Start', 'Karte', 'Ranking', 'Profil'],
  decimal: ',',
  features: [
    (
      '🥙',
      'Ehrlich bewertet',
      'Soße, Fleisch, Salat und Brot einzeln, in halben Punkten. Eine einzelne 5 schlägt keine dreißig 4,5er.',
    ),
    (
      '🏆',
      'Ranking deiner Stadt',
      'Die Top 3 in deiner Nähe, was gerade im Trend ist und welcher Laden neu aufgemacht hat. Auch vegetarisch und vegan.',
    ),
    (
      '👋',
      'Mit Freunden',
      'Per QR-Code verbinden, sehen, wer gerade wo isst – und am Jahresende kommt dein Döner Wrapped.',
    ),
  ],
  testH2: 'Teste die App, bevor sie im Store ist.',
  testLead:
      'Wir lassen gerade nach und nach Leute rein. Sag uns, welches Handy du hast, dann schicken wir dir die Einladung.',
  formH3: 'Für den Test anmelden',
  formLead: 'Dauert 20 Sekunden. Wir nutzen die Adresse nur für die Einladung.',
  testFlight: 'TestFlight',
  playTest: 'Play-Test',
  ios: (
    label: 'E-Mail deiner Apple-ID',
    hint: 'Dorthin schickt Apple die TestFlight-Einladung. Du brauchst die App „TestFlight“ aus dem App Store.',
    done: 'Sobald wir dich freigeschaltet haben, kommt die TestFlight-Einladung von Apple an diese Adresse.',
  ),
  android: (
    label: 'E-Mail deines Google-Kontos',
    hint: 'Die Adresse, mit der du im Play Store angemeldet bist. Nur so lässt dich Google in den Test.',
    done: 'Sobald wir dich freigeschaltet haben, bekommst du von uns den Link zum Test im Play Store.',
  ),
  emailPlaceholder: 'du@beispiel.de',
  submit: 'Einladung anfragen',
  doneH3: 'Du bist auf der Liste!',
  error: 'Das hat nicht geklappt. Versuch es bitte noch einmal.',
  invalidEmail: 'Diese E-Mail-Adresse stimmt nicht. Schau bitte noch einmal drauf.',
  tooMany: 'Gerade kommen zu viele Anfragen. Versuch es in einer Stunde noch einmal.',
  sender: 'ein Werkzeug von',
  privacy: 'Datenschutz',
  imprint: 'Impressum',
  otherLang: 'English',
  otherLangPath: '/en',
);

final _en = _Texts(
  lang: 'en',
  title: 'Döner App – The best döner in your city',
  description: 'Döner rated by sauce, meat, salad and bread – by people who eat in your area.',
  ogImage: 'og-image-en.png',
  navTest: 'Try it',
  h1: 'The best döner',
  h1Accent: 'in&nbsp;your city.',
  lead:
      'Rated by sauce, meat, salad and bread – by people who eat in your area. And you see where your friends are eating right now.',
  ctaTest: 'Join the beta',
  ctaBrowser: 'Open in browser',
  stores: 'iPhone via TestFlight · Android via Google Play testing · free',
  ranking: 'Freiburg ranking',
  chips: ['Overall', 'Sauce', 'Meat', 'Bread'],
  reviews: 'ratings',
  friends: 'friends',
  placeData: 'Place data: Google Maps',
  tabs: ['Home', 'Map', 'Ranking', 'Profile'],
  decimal: '.',
  features: [
    ('🥙', 'Honest ratings', 'Sauce, meat, salad and bread separately, in half points. A single 5 doesn’t beat thirty 4.5s.'),
    (
      '🏆',
      'Your city’s ranking',
      'The top 3 near you, what’s trending and which shop just opened. Vegetarian and vegan too.',
    ),
    (
      '👋',
      'With friends',
      'Connect by QR code, see who’s eating where – and at the end of the year you get your Döner Wrapped.',
    ),
  ],
  testH2: 'Try the app before it’s in the store.',
  testLead: 'We’re letting people in step by step. Tell us which phone you have and we’ll send you the invite.',
  formH3: 'Join the beta',
  formLead: 'Takes 20 seconds. We only use the address for the invite.',
  testFlight: 'TestFlight',
  playTest: 'Play testing',
  ios: (
    label: 'Your Apple ID email',
    hint: 'Apple sends the TestFlight invite there. You need the “TestFlight” app from the App Store.',
    done: 'Once we’ve let you in, Apple sends the TestFlight invite to this address.',
  ),
  android: (
    label: 'Your Google account email',
    hint: 'The account you’re signed in with on Google Play – Google only admits testers that way.',
    done: 'Once we’ve let you in, we’ll send you the link to the test in the Play Store.',
  ),
  emailPlaceholder: 'you@example.com',
  submit: 'Request invite',
  doneH3: 'You’re on the list!',
  error: 'That didn’t work. Please try again.',
  invalidEmail: 'That email address doesn’t look right. Please check it.',
  tooMany: 'Too many requests right now. Please try again in an hour.',
  sender: 'a tool by',
  privacy: 'Privacy (German)',
  imprint: 'Legal notice',
  otherLang: 'Deutsch',
  otherLangPath: '/',
);

typedef _PlatformTexts = ({String label, String hint, String done});

class _Texts {
  final String lang, title, description, ogImage, navTest, h1, h1Accent, lead, ctaTest, ctaBrowser, stores;
  final String ranking, reviews, friends, placeData, decimal;
  final List<String> chips, tabs;
  final List<(String, String, String)> features;
  final String testH2,
      testLead,
      formH3,
      formLead,
      testFlight,
      playTest,
      emailPlaceholder,
      submit,
      doneH3,
      error;
  final String invalidEmail, tooMany;
  final _PlatformTexts ios, android;
  final String sender, privacy, imprint, otherLang, otherLangPath;

  const _Texts({
    required this.lang,
    required this.title,
    required this.description,
    required this.ogImage,
    required this.navTest,
    required this.h1,
    required this.h1Accent,
    required this.lead,
    required this.ctaTest,
    required this.ctaBrowser,
    required this.stores,
    required this.ranking,
    required this.chips,
    required this.reviews,
    required this.friends,
    required this.placeData,
    required this.tabs,
    required this.decimal,
    required this.features,
    required this.testH2,
    required this.testLead,
    required this.formH3,
    required this.formLead,
    required this.testFlight,
    required this.playTest,
    required this.ios,
    required this.android,
    required this.emailPlaceholder,
    required this.submit,
    required this.doneH3,
    required this.error,
    required this.invalidEmail,
    required this.tooMany,
    required this.sender,
    required this.privacy,
    required this.imprint,
    required this.otherLang,
    required this.otherLangPath,
  });
}

/// Example rows for the phone in the hero (shop, district, friends, score, count).
const _exampleRanking = [
  ('Bosporus Grill', 'Stühlinger', 2, 4.7, 38),
  ('Antalya Kebap', 'Altstadt', 0, 4.5, 51),
  ('Dürüm Ustası', 'Wiehre', 0, 4.5, 22),
  ('Kebaphaus Haslach', 'Haslach', 0, 4.3, 17),
  ('Yufka Corner', 'Herdern', 0, 4.2, 29),
];

String _page(_Texts t) {
  String score(double v) => v.toStringAsFixed(1).replaceAll('.', t.decimal);
  final rows = [
    for (final (i, (name, district, friends, avg, n)) in _exampleRanking.indexed)
      '<div class="row"><span class="rank num">${i + 1}</span><div><b>$name</b><br>'
          '<span class="muted">$district${friends > 0 ? ' · $friends ${t.friends}' : ''}</span></div>'
          '<div class="score"><b class="num">${score(avg)}</b><small>$n ${t.reviews}</small></div></div>',
  ].join('\n');
  final chips = [for (final (i, c) in t.chips.indexed) '<span class="chip${i == 0 ? ' on' : ''}">$c</span>'].join();
  final features = [
    for (final (icon, title, text) in t.features)
      '<div><div class="ico">$icon</div><h2 class="display">$title</h2><p>$text</p></div>',
  ].join('\n');
  final platformTexts = jsonEncode({
    'ios': [t.ios.label, t.ios.hint, t.ios.done],
    'android': [t.android.label, t.android.hint, t.android.done],
    'error': t.error,
    '400': t.invalidEmail,
    '429': t.tooMany,
  });

  return '''<!DOCTYPE html>
<html lang="${t.lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<script>
  // Logged in (token of flutter_secure_storage) or coming from a link for the app: on to the app.
  if (localStorage.getItem('FlutterSecureStorage.session_token') || /[?&](invite|review)=/.test(location.search)) {
    location.replace('/app' + location.search);
  }
</script>
<title>${t.title}</title>
<meta name="description" content="${t.description}">
<meta property="og:site_name" content="Döner App">
<meta property="og:type" content="website">
<meta property="og:title" content="${t.title}">
<meta property="og:description" content="${t.description}">
<meta property="og:image" content="https://doener-api.pleasance.org/${t.ogImage}">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image">
<link rel="alternate" hreflang="de" href="https://doener-api.pleasance.org/">
<link rel="alternate" hreflang="en" href="https://doener-api.pleasance.org/en">
<link rel="icon" type="image/png" href="/favicon.png">
<link rel="apple-touch-icon" href="/icons/Icon-192.png">
<style>
@font-face { font-family: Bricolage; src: url(/assets/assets/fonts/BricolageGrotesque.ttf); font-weight: 200 800; font-stretch: 75% 100%; font-display: swap; }
:root {
  --night: #0E0D12; --raised: #16151B; --tile: #121117; --text: #F2F0EA; --muted: #9A98A3; --line: rgba(255,255,255,.07);
  --ink: #17171A; --g2: #F3BA4D; --grad: linear-gradient(45deg, #F6A94A, #F3BA4D, #D7C45B);
}
* { box-sizing: border-box; margin: 0; }
body { font: 16px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; -webkit-font-smoothing: antialiased; background: var(--night); color: var(--text); }
a { color: inherit; }
.display { font-family: Bricolage, "Arial Narrow", sans-serif; font-weight: 790; font-stretch: 78%; letter-spacing: -.01em; line-height: 1; }
.num { font-family: Bricolage, "Arial Narrow", sans-serif; font-weight: 800; font-stretch: 75%; line-height: 1; }
.muted { color: var(--muted); }
.wrap { max-width: 1120px; margin: 0 auto; padding: 0 24px; }
.btn { display: inline-flex; align-items: center; justify-content: center; gap: 8px; border: 0; border-radius: 999px; padding: 14px 22px; font: 600 16px system-ui, sans-serif; cursor: pointer; text-decoration: none; }
.btn-main { background: var(--grad); color: var(--ink); }
.btn-main:disabled { opacity: .6; cursor: default; }
.btn-ghost { background: transparent; color: inherit; box-shadow: inset 0 0 0 1.5px currentColor; opacity: .85; }
.rule { height: 4px; width: 120px; background: var(--grad); border-radius: 2px; }
.nav { display: flex; align-items: center; justify-content: space-between; padding: 18px 0; }
.brand { display: flex; align-items: center; gap: 12px; font-size: 26px; text-decoration: none; }
.brand img { width: 40px; height: 40px; border-radius: 10px; }
.hero { display: grid; grid-template-columns: 1.1fr .9fr; gap: 48px; align-items: center; padding: 56px 0 72px; }
.hero h1 { font-size: 88px; margin: 18px 0 22px; }
.hero h1 em { font-style: normal; background: var(--grad); -webkit-background-clip: text; background-clip: text; color: transparent; }
.lead { font-size: 20px; color: var(--muted); max-width: 30ch; margin: 22px 0 32px; }
.ctas { display: flex; gap: 12px; flex-wrap: wrap; }
.stores { margin-top: 18px; font-size: 14px; color: var(--muted); }
.phonebox { display: flex; justify-content: center; }
.phone { width: 280px; border-radius: 40px; padding: 10px; background: #000; box-shadow: 0 30px 80px rgba(0,0,0,.45), inset 0 0 0 2px #2a2930; }
.screen { border-radius: 31px; overflow: hidden; background: var(--night); height: 560px; position: relative; font-size: 13px; }
.sbar { display: flex; justify-content: space-between; padding: 12px 22px 6px; font-weight: 600; font-size: 12px; }
.screen h3 { font-size: 26px; padding: 6px 14px 0; }
.chips { padding: 10px 14px 10px; }
.chip { display: inline-block; padding: 5px 10px; border-radius: 999px; background: var(--raised); border: 1px solid var(--line); font-size: 11px; margin: 0 4px 4px 0; }
.chip.on { background: var(--grad); color: var(--ink); border-color: transparent; font-weight: 600; }
.row { display: flex; align-items: center; gap: 10px; padding: 10px 14px; border-bottom: 1px solid var(--line); }
.rank { width: 22px; font-size: 22px; color: var(--g2); }
.score { margin-left: auto; text-align: right; }
.score b { font-size: 20px; display: block; }
.score small { color: var(--muted); font-size: 10px; }
.placedata { padding: 8px 14px; font-size: 10px; }
.tabbar { position: absolute; bottom: 0; left: 0; right: 0; display: flex; justify-content: space-around; align-items: center; padding: 10px 6px 18px; background: var(--raised); border-top: 1px solid var(--line); color: var(--muted); font-size: 10px; }
.tabbar .ci { width: 46px; height: 46px; border-radius: 50%; background: var(--grad); display: grid; place-items: center; font-size: 22px; margin-top: -18px; }
.tabbar .active { color: var(--g2); }
.feat { display: grid; grid-template-columns: repeat(3, 1fr); gap: 16px; padding: 24px 0 80px; }
.feat > div { background: var(--raised); border: 1px solid var(--line); border-radius: 24px; padding: 28px; }
.feat .ico { font-size: 34px; }
.feat h2 { font-size: 30px; margin: 14px 0 8px; }
.feat p { color: var(--muted); }
.testing { display: grid; grid-template-columns: 1fr 1fr; gap: 48px; align-items: center; padding: 72px 0; border-top: 1px solid var(--line); }
.testing h2 { font-size: 60px; margin: 14px 0 18px; }
.tester { border-radius: 24px; padding: 28px; background: var(--raised); border: 1px solid var(--line); }
.tester h3 { font-size: 30px; margin-bottom: 6px; }
.tester p { color: var(--muted); }
.seg { display: grid; grid-template-columns: 1fr 1fr; gap: 6px; padding: 5px; border-radius: 14px; margin: 18px 0 14px; background: var(--tile); }
.seg button { border: 0; border-radius: 10px; padding: 12px; font: 600 15px system-ui, sans-serif; cursor: pointer; background: transparent; color: inherit; display: flex; flex-direction: column; align-items: center; gap: 2px; }
.seg button small { font-weight: 400; font-size: 12px; opacity: .7; }
.seg button.on { background: var(--grad); color: var(--ink); }
.tester label { display: block; font-size: 14px; margin-bottom: 6px; }
.tester input { width: 100%; padding: 14px 16px; border-radius: 12px; font: 16px system-ui, sans-serif; border: 1.5px solid transparent; outline: none; background: var(--tile); color: var(--text); }
.tester input:focus { border-color: var(--g2); }
.hint { font-size: 13px; margin-top: 8px; }
.error { color: #F2545B !important; font-size: 14px; margin-top: 10px; }
.tester form .btn-main { width: 100%; margin-top: 16px; }
.done { text-align: center; padding: 24px 0 8px; }
.done .big { font-size: 56px; }
.done .btn { margin-top: 18px; }
.foot { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 32px 0 40px; flex-wrap: wrap; border-top: 1px solid var(--line); color: var(--muted); }
.sender { display: flex; align-items: center; gap: 10px; text-decoration: none; }
.sender span { font-family: Bricolage, "Arial Narrow", sans-serif; font-weight: 650; font-stretch: 80%; font-size: 14px; }
.mark { position: relative; display: inline-block; }
.mark img { height: 22px; display: block; }
.mark::after { content: ""; position: absolute; left: 0; right: 0; bottom: -5px; height: 2px; background: linear-gradient(90deg,#F2545B,#FB8C45,#F2C14E,#6CCF8E,#46BFE0,#8E92F8,#C39BF2); opacity: .45; }
.mark i { position: absolute; bottom: -6px; left: 26%; width: 10%; height: 4px; background: var(--grad); z-index: 1; }
.foot nav { display: flex; gap: 18px; font-size: 14px; }
[hidden] { display: none !important; }
@media (max-width: 760px) {
  .wrap { padding: 0 18px; }
  .hide-m { display: none !important; }
  .hero, .testing { grid-template-columns: 1fr; gap: 36px; padding: 28px 0 48px; }
  .hero h1 { font-size: 58px; }
  .lead { font-size: 18px; }
  .feat { grid-template-columns: 1fr; padding-bottom: 48px; }
  .testing h2 { font-size: 44px; }
  .ctas { flex-direction: column; }
}
</style>
</head>
<body>
<div class="wrap">
  <header class="nav">
    <a class="brand display" href="${t.lang == 'de' ? '/' : '/en'}"><img src="/icons/Icon-192.png" alt="">Döner App</a>
    <a class="btn btn-ghost hide-m" href="#test">${t.navTest}</a>
  </header>

  <section class="hero">
    <div>
      <div class="rule"></div>
      <h1 class="display">${t.h1} <em>${t.h1Accent}</em></h1>
      <p class="lead">${t.lead}</p>
      <div class="ctas">
        <a class="btn btn-main" href="#test">${t.ctaTest}</a>
        <a class="btn btn-ghost" href="/app">${t.ctaBrowser}</a>
      </div>
      <p class="stores">${t.stores}</p>
    </div>
    <div class="phonebox" aria-hidden="true">
      <div class="phone"><div class="screen">
        <div class="sbar"><span>12:41</span><span>●●● 5G</span></div>
        <h3 class="display">${t.ranking}</h3>
        <div class="chips">$chips</div>
$rows
        <div class="placedata muted">${t.placeData}</div>
        <div class="tabbar"><span>${t.tabs[0]}</span><span>${t.tabs[1]}</span><span class="ci">🥙</span><span class="active">${t.tabs[2]}</span><span>${t.tabs[3]}</span></div>
      </div></div>
    </div>
  </section>

  <section class="feat">
$features
  </section>

  <section class="testing" id="test">
    <div>
      <div class="rule"></div>
      <h2 class="display">${t.testH2}</h2>
      <p class="lead" style="margin-bottom:0">${t.testLead}</p>
    </div>
    <div class="tester">
      <form>
        <h3 class="display">${t.formH3}</h3>
        <p>${t.formLead}</p>
        <div class="seg"><button type="button" aria-pressed="false" data-p="ios">iPhone<small>${t.testFlight}</small></button><button type="button" aria-pressed="false" data-p="android">Android<small>${t.playTest}</small></button></div>
        <label for="email"></label><input id="email" type="email" required autocomplete="email" placeholder="${t.emailPlaceholder}" aria-describedby="hint">
        <p class="hint" id="hint"></p>
        <p class="error" role="alert" hidden></p>
        <button class="btn btn-main">${t.submit}</button>
      </form>
      <div class="done" hidden><div class="big">🥙</div><h3 class="display" tabindex="-1">${t.doneH3}</h3><p></p></div>
    </div>
  </section>

  <footer class="foot">
    <a class="sender" href="https://pleasance.org"><span>${t.sender}</span><span class="mark"><img src="/assets/assets/pleasance-wordmark.svg" alt="Pleasance"><i></i></span></a>
    <nav><a href="/datenschutz">${t.privacy}</a><a href="https://pleasance.org/impressum">${t.imprint}</a><a href="${t.otherLangPath}">${t.otherLang}</a></nav>
  </footer>
</div>
<script>
  const texts = $platformTexts;
  const box = document.querySelector('.tester'), form = box.querySelector('form'), done = box.querySelector('.done');
  const error = form.querySelector('.error'), submit = form.querySelector('.btn-main');
  let platform;
  const choose = (p) => {
    platform = p;
    form.querySelectorAll('.seg button').forEach((b) => {
      b.classList.toggle('on', b.dataset.p === p);
      b.setAttribute('aria-pressed', b.dataset.p === p);
    });
    form.querySelector('label').textContent = texts[p][0];
    form.querySelector('.hint').textContent = texts[p][1];
    done.querySelector('p').textContent = texts[p][2];
  };
  form.querySelectorAll('.seg button').forEach((b) => b.addEventListener('click', () => choose(b.dataset.p)));
  choose(/android/i.test(navigator.userAgent) ? 'android' : 'ios');
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    submit.disabled = true;
    error.hidden = true;
    try {
      const res = await fetch('/api/v1/tester-requests', {
        method: 'POST',
        headers: {'content-type': 'application/json'},
        // From a friend's invite page (/i/<code>): whose link it was.
        body: JSON.stringify({email: form.querySelector('input').value, platform, inviteCode: new URLSearchParams(location.search).get('von')}),
      });
      if (!res.ok) throw res.status;
      form.hidden = true;
      done.hidden = false;
      done.querySelector('h3').focus();
    } catch (status) {
      error.textContent = texts[status] || texts.error;
      error.hidden = false;
    } finally {
      submit.disabled = false;
    }
  });
</script>
</body>
</html>
''';
}
