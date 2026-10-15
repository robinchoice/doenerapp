import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'best_of.dart';
import 'deps.dart';
import 'landing.dart';
import 'privacy.dart';

// Public content for other people's agents, after llms.txt (https://llmstxt.org):
// /llms.txt lists the pages, /llms-full.txt holds all of them, every page is
// <path>.md as well, and Accept: text/markdown gets the Markdown under the page's
// own URL. ?lang= picks the language, since agents rarely send Accept-Language.

/// A page anyone sees without logging in. body is Markdown below the title and
/// description and carries the page's content, not its layout. path is the
/// page's URL, the English version of `/` is `/en`.
typedef PublicPage = ({String path, String title, String description, String body});

/// Every public page with its own content. Never anything behind the login:
/// no single reviews, profiles, invites, accounts or admin pages.
Future<List<PublicPage>> publicPages(Deps deps, String base, {required bool english}) async => [
      landingPublicPage(base, english: english),
      ...await bestOfPublicPages(deps.db, english: english),
      privacyPublicPage(english: english),
    ];

String _markdownPath(String path) => path == '/' ? '/index.md' : '$path.md';

String _markdown(PublicPage page) => '# ${page.title}\n\n> ${page.description}\n\n${page.body}';

String _base(Deps deps, Request request) => deps.config.publicUrl ?? request.requestedUri.origin;

/// `?lang=de|en`, else Accept-Language, else German. Links keep an explicit `?lang=`.
({bool english, String query}) _language(Request request) {
  final lang = request.url.queryParameters['lang'];
  final english = lang == null
      ? (request.headers['accept-language'] ?? '').trimLeft().toLowerCase().startsWith('en')
      : lang == 'en';
  return (english: english, query: lang == null ? '' : '?lang=${english ? 'en' : 'de'}');
}

Response _text(String body, String type) => Response.ok('$body\n',
    headers: {'content-type': '$type; charset=utf-8', 'vary': 'accept, accept-language'});

Future<Response?> _page(Deps deps, Request request, String markdownPath, {bool? english}) async {
  final pages = await publicPages(deps, _base(deps, request), english: english ?? _language(request).english);
  final page = pages.where((p) => _markdownPath(p.path) == markdownPath).firstOrNull;
  return page == null ? null : _text(_markdown(page), 'text/markdown');
}

/// Mount before the pages: `/bestenliste/<city>/<year>` would take `<year>.md` too.
void mountAgents(Router router, Deps deps) {
  router
    ..get('/llms.txt', (Request request) async {
      final (:english, :query) = _language(request);
      String t(String de, String en) => english ? en : de;
      final base = _base(deps, request);
      final landing = landingPublicPage(base, english: english);
      final pages = await publicPages(deps, base, english: english);
      return _text(
        [
          '# Döner App',
          '> ${landing.description}',
          '${t('Öffentliche Inhalte der Döner App als Markdown, ohne Login. Alles in einer Datei', 'Public content of the Döner App as Markdown, no login needed. Everything in one file')}: '
              '$base/llms-full.txt$query\n\n'
              '${t('English', 'Deutsch')}: $base/llms.txt?lang=${english ? 'de' : 'en'}',
          '## ${t('Seiten', 'Pages')}',
          [for (final p in pages) '- [${p.title}]($base${_markdownPath(p.path)}$query): ${p.description}'].join('\n'),
        ].join('\n\n'),
        'text/plain',
      );
    })
    ..get('/llms-full.txt', (Request request) async {
      final pages = await publicPages(deps, _base(deps, request), english: _language(request).english);
      return _text(pages.map(_markdown).join('\n\n---\n\n'), 'text/plain');
    })
    ..get('/<page|.+\\.md>', (Request request, String _) async =>
        await _page(deps, request, '/${request.url.path}') ?? Response.notFound('Not found'));
}

/// Agents that ask for Markdown get a public page as its .md, all others the HTML.
Middleware markdownForAgents(Deps deps) => (inner) => (request) async {
      if (request.method != 'GET' || !(request.headers['accept'] ?? '').contains('text/markdown')) {
        return inner(request);
      }
      final segments = request.url.pathSegments.where((s) => s.isNotEmpty);
      final path = '/${segments.join('/')}';
      final english = path == '/en' ? true : null;
      return await _page(deps, request, _markdownPath(english == true ? '/' : path), english: english) ??
          inner(request);
    };
