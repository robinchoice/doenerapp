import 'package:doener_models/doener_models.dart';

import '../client.dart';
import '../command.dart';

String _line(FeedItem item) {
  final what = switch (item.type) {
    FeedItemType.visit => 'hat bei ${item.place.name} eingecheckt',
    FeedItemType.review => 'hat ${item.place.name} bewertet: ${switch (item.headline(Diet.all)) {
        final score? => decimal(score),
        null => 'ohne Wertung',
      }}',
  };
  return [
        '${day(item.timestamp)} ${item.user.displayName}${item.fromFriend ? '' : ' (in der Nähe)'} $what',
        if (item.text case final text?) '„$text“',
      ].join(' · ') +
      reactionText(item.reactions);
}

/// Friends' check-ins and reviews like the feed in the app, with a position
/// also everyone's reviews around it. Pages through [FeedPage.cursor].
final feed = Command(
  help: [
    ('feed [--lat <breite> --lon <länge>]', 'Was Freunde gegessen und bewertet haben, mit Position auch Bewertungen in der Nähe'),
    ('  [--limit <1–50>] [--cursor <cursor>]', 'Anzahl, sonst 20, und die nächste Seite'),
  ],
  options: (parser) => parser
    ..addOption('lat')
    ..addOption('lon')
    ..addOption('limit')
    ..addOption('cursor'),
  run: (ctx) async {
    requireLogin(ctx);
    final around = ctx.args.option('lat') != null || ctx.args.option('lon') != null;
    final page = parse(
      await ctx.api.get('/feed', {
        if (around) 'lat': '${numberOption(ctx, 'lat', required: true)}',
        if (around) 'lon': '${numberOption(ctx, 'lon', required: true)}',
        'limit': ?ctx.args.option('limit'),
        'cursor': ?ctx.args.option('cursor'),
      }),
      FeedPage.fromJson,
    );
    return (
      data: page.toJson(),
      text: [
        if (page.items.isEmpty) 'Noch nichts von deinen Freunden.',
        ...page.items.map(_line),
        if (page.cursor case final cursor?) '\nWeiter mit --cursor $cursor',
      ].join('\n'),
    );
  },
);
