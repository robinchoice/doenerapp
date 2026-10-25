import 'package:doener_models/doener_models.dart';

import '../client.dart';
import '../command.dart';

String _line(FriendshipDto friendship) {
  final status = switch ((friendship.status, friendship.direction)) {
    (FriendshipStatus.accepted, _) => 'befreundet',
    (FriendshipStatus.pending, FriendshipDirection.outgoing) => 'Anfrage gesendet',
    (FriendshipStatus.pending, FriendshipDirection.incoming) => 'möchte befreundet sein, annehmen: befriend --user ${friendship.user.id}',
  };
  return '${friendship.user.displayName} · $status${friendship.muted ? ' · stumm' : ''}';
}

final friends = <String, Command>{
  'friends': Command(
    help: [('friends', 'Freunde und offene Anfragen')],
    run: (ctx) async {
      requireLogin(ctx);
      final friendships = parseList(await ctx.api.get('/friends'), FriendshipDto.fromJson);
      return (
        data: {'friends': [for (final friendship in friendships) friendship.toJson()]},
        text: friendships.isEmpty ? 'Noch keine Freunde.' : friendships.map(_line).join('\n'),
      );
    },
  ),
  'users': Command(
    help: [('users --search <name>', 'Nutzer suchen, für befriend')],
    options: (parser) => parser..addOption('search'),
    run: (ctx) async {
      requireLogin(ctx);
      final search = ctx.args.option('search') ?? (throw const Failure('--search <name> fehlt.', Exit.usage));
      final users = parseList(await ctx.api.get('/users/search', {'q': search}), UserDto.fromJson);
      return (
        data: {'users': [for (final user in users) user.toJson()]},
        text: users.isEmpty ? 'Niemand gefunden.' : [for (final user in users) '${user.displayName} · ${user.id}'].join('\n'),
      );
    },
  ),
  // Asking someone who already asked accepts, so the one command does both.
  'befriend': Command(
    help: [('befriend --user <id>', 'Freundschaftsanfrage senden oder eine erhaltene annehmen')],
    options: (parser) => parser..addOption('user'),
    run: (ctx) async {
      requireLogin(ctx);
      final user = ctx.args.option('user') ?? (throw const Failure('--user <id> fehlt, siehe `doener users`.', Exit.usage));
      final friendship = parse(await ctx.api.post('/friends/requests', FriendRequestBody(userId: user).toJson()), FriendshipDto.fromJson);
      final name = friendship.user.displayName;
      return (
        data: {'friendship': friendship.toJson()},
        text: friendship.status == FriendshipStatus.accepted ? 'Mit $name befreundet.' : 'Anfrage an $name gesendet.',
      );
    },
  ),
};
