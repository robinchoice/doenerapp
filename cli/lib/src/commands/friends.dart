import 'package:doener_models/doener_models.dart';

import '../client.dart';
import '../command.dart';

String _line(FriendshipDto friendship) {
  final status = switch ((friendship.status, friendship.direction)) {
    (FriendshipStatus.accepted, _) => 'befreundet',
    (FriendshipStatus.pending, FriendshipDirection.outgoing) => 'Anfrage gesendet',
    (FriendshipStatus.pending, FriendshipDirection.incoming) => 'möchte befreundet sein',
  };
  return '${friendship.user.displayName} · $status${friendship.muted ? ' · stumm' : ''}';
}

final friends = Command(
  help: [('friends', 'Freunde und offene Anfragen')],
  run: (ctx) async {
    requireLogin(ctx);
    final friendships = parseList(await ctx.api.get('/friends'), FriendshipDto.fromJson);
    return (
      data: {'friends': [for (final friendship in friendships) friendship.toJson()]},
      text: friendships.isEmpty ? 'Noch keine Freunde.' : friendships.map(_line).join('\n'),
    );
  },
);
