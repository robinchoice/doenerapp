import 'dart:async';

import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/haptics.dart';
import '../../core/push.dart';
import '../../core/session.dart';
import '../../ui/widgets.dart';
import '../profile/profile_view.dart';
import 'invite.dart';

/// Invite code from a link opened before the user was signed in — accepted
/// right after the login (and the choice of a name).
final pendingInviteRecord = settingsStore.record('pendingInvite');

class Friends extends ChangeNotifier {
  final Session _session;
  Friends(this._session);

  List<FriendshipDto> all = [];
  String? error;

  List<FriendshipDto> get accepted => all.where((f) => f.status == FriendshipStatus.accepted).toList();
  List<FriendshipDto> get incoming =>
      all.where((f) => f.status == FriendshipStatus.pending && f.direction == FriendshipDirection.incoming).toList();
  List<FriendshipDto> get outgoing =>
      all.where((f) => f.status == FriendshipStatus.pending && f.direction == FriendshipDirection.outgoing).toList();

  Future<void> load() async {
    if (!_session.isLoggedIn) {
      all = [];
      return notifyListeners();
    }
    await _guard(() async {
      final json = await _session.api.get('/friends') as List;
      all = [for (final f in json) FriendshipDto.fromJson(f as Map<String, dynamic>)];
    });
  }

  Future<List<UserDto>> search(String q) async {
    final json = await _session.api.get('/users/search', query: {'q': q}) as List;
    return [for (final u in json) UserDto.fromJson(u as Map<String, dynamic>)];
  }

  Future<void> request(String userId) => _guard(() async {
        final f = FriendshipDto.fromJson(await _session.api.post('/friends/requests', FriendRequestBody(userId: userId).toJson()) as Map<String, dynamic>);
        all = [f, ...all.where((x) => x.id != f.id)];
        Haptics.success();
      });

  Future<void> accept(String id) => _guard(() async {
        final f = FriendshipDto.fromJson(await _session.api.post('/friends/$id/accept') as Map<String, dynamic>);
        all = [for (final x in all) x.id == id ? f : x];
        Haptics.success();
      });

  /// No pushes about [f]'s check-ins.
  Future<void> setMuted(FriendshipDto f, bool muted) => _guard(() async {
        final path = '/me/mutes/${f.user.id}';
        muted ? await _session.api.put(path, null) : await _session.api.delete(path);
        all = [
          for (final x in all)
            x.id == f.id
                ? FriendshipDto(id: x.id, user: x.user, status: x.status, direction: x.direction, createdAt: x.createdAt, muted: muted)
                : x,
        ];
      });

  Future<void> remove(String id) => _guard(() async {
        await _session.api.delete('/friends/$id');
        all = all.where((x) => x.id != id).toList();
      });

  Future<InviteDto> fetchInvite() async => InviteDto.fromJson(await _session.api.get('/me/invite') as Map<String, dynamic>);

  /// New link; the old one stops working.
  Future<InviteDto> resetInvite() async =>
      InviteDto.fromJson(await _session.api.post('/me/invite/reset') as Map<String, dynamic>);

  Future<UserDto> inviter(String code) async =>
      UserDto.fromJson(await _session.api.get('/invites/${Uri.encodeComponent(code)}') as Map<String, dynamic>);

  /// Opening someone's invite link makes you friends right away.
  Future<FriendshipDto> acceptInvite(String code) async {
    final json = await _session.api.post('/invites/${Uri.encodeComponent(code)}/accept');
    final friendship = FriendshipDto.fromJson(json as Map<String, dynamic>);
    all = [friendship, ...all.where((x) => x.id != friendship.id)];
    Haptics.success();
    notifyListeners();
    return friendship;
  }

  Future<void> _guard(Future<void> Function() action) async {
    error = null;
    try {
      await action();
    } catch (e) {
      error = e.toString();
    }
    notifyListeners();
  }
}

class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key});

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  @override
  void initState() {
    super.initState();
    context.read<Friends>().load();
  }

  @override
  Widget build(BuildContext context) {
    final friends = context.watch<Friends>();
    Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: context.accent)),
        );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Freunde'),
        actions: [
          IconButton(
            tooltip: 'Freund hinzufügen',
            icon: const Icon(Icons.person_add_alt_1),
            onPressed: () => showAppSheet(context, (_) => const _FriendSearch()),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: friends.load,
        child: ListView(
          children: [
            if (friends.error != null) ListTile(leading: const Icon(Icons.error_outline), title: Text(friends.error!)),
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.qr_code_2)),
              title: const Text('Freunde einladen'),
              subtitle: const Text('Wer deinen Link öffnet, ist sofort mit dir befreundet.'),
              onTap: () => showAppSheet(context, (_) => const InviteSheet()),
            ),
            if (friends.incoming.isNotEmpty) ...[
              header('Anfragen'),
              for (final f in friends.incoming)
                ListTile(
                  title: Text(f.user.displayName),
                  subtitle: const Text('Möchte dich als Freund hinzufügen'),
                  onTap: () => showUserProfile(context, f.user),
                  trailing: FilledButton(onPressed: () => friends.accept(f.id), child: const Text('Annehmen')),
                ),
            ],
            if (friends.outgoing.isNotEmpty) ...[
              header('Gesendete Anfragen'),
              for (final f in friends.outgoing)
                ListTile(
                  title: Text(f.user.displayName),
                  subtitle: const Text('Ausstehend'),
                  trailing: OutlinedButton(onPressed: () => friends.remove(f.id), child: const Text('Zurückziehen')),
                ),
            ],
            header('Freunde (${friends.accepted.length})'),
            if (friends.accepted.isEmpty) const ListTile(title: Text('Noch keine Freunde')),
            for (final f in friends.accepted)
              ListTile(
                leading: const CircleAvatar(child: Icon(Icons.person)),
                title: Text(f.user.displayName),
                subtitle: TierLabel(f.user.tier),
                onTap: () => showUserProfile(context, f.user),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (context.read<Push?>() != null)
                      IconButton(
                        tooltip: f.muted ? 'Stumm, tippen für Benachrichtigungen' : 'Stummschalten',
                        icon: Icon(f.muted ? Icons.notifications_off_outlined : Icons.notifications_none),
                        onPressed: () => friends.setMuted(f, !f.muted),
                      ),
                    IconButton(
                      tooltip: 'Entfernen',
                      icon: const Icon(Icons.person_remove_outlined),
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Text('${f.user.displayName} entfernen?'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Abbrechen')),
                              TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Entfernen')),
                            ],
                          ),
                        );
                        if (ok == true) friends.remove(f.id);
                      },
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FriendSearch extends StatefulWidget {
  const _FriendSearch();

  @override
  State<_FriendSearch> createState() => _FriendSearchState();
}

class _FriendSearchState extends State<_FriendSearch> {
  List<UserDto> _results = [];
  String? _error;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    if (q.trim().length < 2) return setState(() => _results = []);
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        final results = await context.read<Friends>().search(q.trim());
        if (mounted) {
          setState(() {
            _results = results;
            _error = null;
          });
        }
      } catch (e) {
        if (mounted) setState(() => _error = e.toString());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final friends = context.watch<Friends>();
    final known = {for (final f in friends.all) f.user.id: f};
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        Text('Freund suchen', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        TextField(
          autofocus: true,
          autocorrect: false,
          decoration: const InputDecoration(hintText: 'Anzeigename…', prefixIcon: Icon(Icons.search)),
          onChanged: _onChanged,
        ),
        if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!)),
        for (final u in _results)
          ListTile(
            title: Text(u.displayName),
            subtitle: TierLabel(u.tier),
            onTap: () => showUserProfile(context, u),
            trailing: switch (known[u.id]?.status) {
              FriendshipStatus.accepted => const Text('Befreundet'),
              FriendshipStatus.pending => const Text('Angefragt'),
              null => OutlinedButton(onPressed: () => friends.request(u.id), child: const Text('Anfragen')),
            },
          ),
      ],
    );
  }
}
