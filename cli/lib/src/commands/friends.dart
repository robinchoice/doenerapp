import 'package:doener_models/doener_models.dart';

import '../client.dart';
import '../command.dart';

String _line(FriendshipDto friendship) {
  final status = switch ((friendship.status, friendship.direction)) {
    (FriendshipStatus.accepted, _) => 'befreundet',
    (FriendshipStatus.pending, FriendshipDirection.outgoing) => 'Anfrage gesendet',
    (FriendshipStatus.pending, FriendshipDirection.incoming) => 'möchte befreundet sein',
  };
  // The id is what befriend, unfriend and mute take
  return '${friendship.user.displayName} · $status${friendship.muted ? ' · stumm' : ''} · ${friendship.user.id}';
}

/// The friendship or open request with `--user`.
Future<FriendshipDto> _with(Context ctx) async {
  final user = ctx.args.option('user') ?? (throw const Failure('--user <id> fehlt, siehe `doener friends`.', Exit.usage));
  final friendships = parseList(await ctx.api.get('/friends'), FriendshipDto.fromJson);
  return friendships.where((f) => f.user.id == user).firstOrNull ??
      (throw const Failure('Mit dieser Person gibt es keine Freundschaft und keine Anfrage.', Exit.error));
}

final friends = <String, Command>{
  'friends': Command(
    help: [('friends', 'Freunde und offene Anfragen, mit der ID für die Befehle unten')],
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
  'unfriend': Command(
    help: [('unfriend --user <id>', 'Freundschaft beenden, eine Anfrage zurückziehen oder ablehnen')],
    options: (parser) => parser..addOption('user'),
    run: (ctx) async {
      requireLogin(ctx);
      final friendship = await _with(ctx);
      await ctx.api.delete('/friends/${friendship.id}');
      final name = friendship.user.displayName;
      return (
        data: {'ok': true},
        text: switch ((friendship.status, friendship.direction)) {
          (FriendshipStatus.accepted, _) => 'Freundschaft mit $name beendet.',
          (FriendshipStatus.pending, FriendshipDirection.outgoing) => 'Anfrage an $name zurückgezogen.',
          (FriendshipStatus.pending, FriendshipDirection.incoming) => 'Anfrage von $name abgelehnt.',
        },
      );
    },
  ),
  // Muted friends stay friends, only their check-ins send no push.
  for (final (name, muted) in const [('mute', true), ('unmute', false)])
    name: Command(
      help: [('$name --user <id>', muted ? 'Keine Pushes mehr, wenn dieser Freund eincheckt' : 'Wieder Pushes von diesem Freund')],
      options: (parser) => parser..addOption('user'),
      run: (ctx) async {
        requireLogin(ctx);
        final friendship = await _with(ctx);
        final path = '/me/mutes/${friendship.user.id}';
        await (muted ? ctx.api.put(path) : ctx.api.delete(path));
        final changed = FriendshipDto(
          id: friendship.id,
          user: friendship.user,
          status: friendship.status,
          direction: friendship.direction,
          createdAt: friendship.createdAt,
          muted: muted,
        );
        final who = friendship.user.displayName;
        return (data: {'friendship': changed.toJson()}, text: muted ? '$who ist stumm.' : '$who ist wieder laut.');
      },
    ),
};
