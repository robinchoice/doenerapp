import 'package:doener_models/doener_models.dart';

import '../client.dart';
import '../command.dart';

String _postPath(Context ctx) {
  final type = ctx.args.option('type') ?? (throw const Failure('--type visit|review fehlt / is required.', Exit.usage));
  final post = ctx.args.option('post') ?? (throw const Failure('--post <id> fehlt / is required.', Exit.usage));
  return '/${type == 'visit' ? 'visits' : 'reviews'}/${Uri.encodeComponent(post)}/comments';
}

final comments = <String, Command>{
  'comments': Command(
    help: [('comments --type visit|review --post <id> [--cursor <cursor>]', 'Unterhaltung unter Kontakten / Conversation among friends')],
    options: (p) => p..addOption('type', allowed: ['visit', 'review'])..addOption('post')..addOption('cursor'),
    run: (ctx) async {
      requireLogin(ctx);
      final page = parse(await ctx.api.get(_postPath(ctx), {'cursor': ?ctx.args.option('cursor')}), PostCommentsPage.fromJson);
      return (data: page.toJson(), text: [
        if (page.comments.isEmpty) 'Noch keine Kommentare / No comments yet.',
        for (final c in page.comments.reversed) '${c.id} · ${c.user.displayName}: ${c.text}',
        if (page.cursor case final cursor?) 'Weiter / More: --cursor $cursor',
      ].join('\n'));
    },
  ),
  'comment': Command(
    help: [('comment --type visit|review --post <id> --text <text>', 'Kommentieren / Add a comment')],
    options: (p) => p..addOption('type', allowed: ['visit', 'review'])..addOption('post')..addOption('text'),
    run: (ctx) async {
      requireLogin(ctx);
      final text = ctx.args.option('text') ?? (throw const Failure('--text <text> fehlt / is required.', Exit.usage));
      final c = parse(await ctx.api.post(_postPath(ctx), {'text': text}), PostCommentDto.fromJson);
      return (data: c.toJson(), text: '${c.id} · ${c.user.displayName}: ${c.text}');
    },
  ),
  'uncomment': Command(
    help: [('uncomment --type visit|review --post <id> --id <commentId>', 'Eigenen Kommentar löschen / Delete your comment')],
    options: (p) => p..addOption('type', allowed: ['visit', 'review'])..addOption('post')..addOption('id'),
    run: (ctx) async {
      requireLogin(ctx);
      final id = ctx.args.option('id') ?? (throw const Failure('--id <commentId> fehlt / is required.', Exit.usage));
      await ctx.api.delete('${_postPath(ctx)}/${Uri.encodeComponent(id)}');
      return (data: {'deleted': true}, text: 'Kommentar gelöscht / Comment deleted.');
    },
  ),
};
