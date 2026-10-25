import 'dart:async';

import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../core/app_data.dart';
import '../../core/location.dart';
import '../../core/session.dart';
import '../../ui/widgets.dart';
import '../place/place_detail.dart';
import '../social/friends.dart';

/// The bell's entries, with new shops of the city where the user is.
Future<InboxDto> _fetchInbox(BuildContext context) async {
  final position = context.read<LocationService>().position;
  final json = await context.read<Session>().api.get('/me/inbox', query: {
    if (position != null) 'lat': '${position.latitude}',
    if (position != null) 'lon': '${position.longitude}',
  });
  return InboxDto.fromJson(json as Map<String, dynamic>);
}

/// The bell on Start: what happened since it was last opened, on any device.
/// Loads again when the app comes back to the front.
class InboxButton extends StatefulWidget {
  const InboxButton({super.key});

  @override
  State<InboxButton> createState() => _InboxButtonState();
}

class _InboxButtonState extends State<InboxButton> {
  InboxDto? _inbox;
  late final _lifecycle = AppLifecycleListener(onResume: _load);

  @override
  void initState() {
    super.initState();
    _lifecycle;
    _load();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!context.read<Session>().isLoggedIn) return;
    try {
      final inbox = await _fetchInbox(context);
      if (mounted) setState(() => _inbox = inbox);
    } catch (_) {
      // Offline: the bell shows what it had.
    }
  }

  Future<void> _open() async {
    final inbox = _inbox;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => InboxScreen(initial: inbox)));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final unread = _inbox?.unread ?? 0;
    return IconButton(
      tooltip: 'Mitteilungen',
      onPressed: _open,
      icon: Badge(
        isLabelVisible: unread > 0,
        label: Text(unread > 9 ? '9+' : '$unread'),
        child: const Icon(Icons.notifications_none),
      ),
    );
  }
}

/// The last 7 days, newest first. New ones stay marked while the screen is
/// open; opening it marks everything as seen on all devices.
class InboxScreen extends StatefulWidget {
  final InboxDto? initial;
  const InboxScreen({super.key, this.initial});

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  late InboxDto? _inbox = widget.initial;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<Session>().api;
    try {
      final inbox = await _fetchInbox(context);
      if (mounted) {
        setState(() {
          _inbox = inbox;
          _error = null;
        });
      }
      // Seen is what was loaded, not what came in since.
      final until = inbox.loadedAt?.toUtc().toIso8601String();
      await api.post('/me/inbox/seen${until == null ? '' : '?until=${Uri.encodeQueryComponent(until)}'}');
    } on OfflineException catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _openItem(InboxItemDto item) async {
    if (item.type == 'friend_request') {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const FriendsScreen()));
      return;
    }
    final placeId = item.placeId;
    if (placeId == null) return;
    try {
      final place = await context.read<AppData>().place(placeId);
      if (mounted) await showPlaceDetail(context, place);
    } on OfflineException catch (e) {
      if (mounted) showMessage(context, e.toString());
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inbox = _inbox;
    return Scaffold(
      appBar: AppBar(title: const Text('Mitteilungen')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: [
            if (_error != null && inbox == null)
              Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center))
            else if (inbox == null)
              const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator()))
            else if (inbox.items.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('In den letzten 7 Tagen ist nichts passiert. Hier steht, was deine Freunde machen und was neu ist.',
                    textAlign: TextAlign.center),
              ),
            for (final item in inbox?.items ?? const <InboxItemDto>[])
              _InboxTile(
                item: item,
                isNew: inbox!.seenAt == null || item.timestamp.isAfter(inbox.seenAt!),
                onTap: () => _openItem(item),
              ),
            if (inbox != null && inbox.items.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Gelesen gilt auf allen Geräten. Was du hier gesehen hast, kommt nicht noch einmal als Push. Einträge verschwinden nach 7 Tagen.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _InboxTile extends StatelessWidget {
  final InboxItemDto item;
  final bool isNew;
  final VoidCallback onTap;
  const _InboxTile({required this.item, required this.isNew, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final aboutFriend = item.type == 'friend_visit';
    return ListTile(
      onTap: onTap,
      leading: Badge(
        isLabelVisible: isNew,
        smallSize: 8,
        child: Icon(switch (item.type) {
          'friend_visit' => Icons.restaurant,
          'friend_review' => Icons.star_outline,
          'reaction' => Icons.favorite_border,
          'friend_request' => Icons.person_add_alt,
          'new_place' => Icons.storefront,
          _ => Icons.campaign_outlined,
        }),
      ),
      title: Text(item.title, style: isNew ? const TextStyle(fontWeight: FontWeight.w600) : null),
      subtitle: Text(
        [?item.body, relativeTime(item.timestamp)].join(' · '),
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
      ),
      trailing: aboutFriend || item.type == 'new_place'
          ? IconButton(
              tooltip: 'Weniger davon',
              icon: const Icon(Icons.more_horiz),
              onPressed: () =>
                  showAppSheet(context, (_) => LessSheet(aboutFriend: aboutFriend, userId: item.userId, userName: item.userName)),
            )
          : null,
    );
  }
}

/// "Weniger davon" on a push or in the bell: mute the friend or switch the
/// kind of push off. The bell keeps showing it either way.
class LessSheet extends StatefulWidget {
  final bool aboutFriend;
  final String? userId;
  final String? userName;
  const LessSheet({super.key, required this.aboutFriend, this.userId, this.userName});

  @override
  State<LessSheet> createState() => _LessSheetState();
}

enum _Less { mute, friends, places }

class _LessSheetState extends State<LessSheet> {
  late _Less _choice = !widget.aboutFriend
      ? _Less.places
      : widget.userId != null
          ? _Less.mute
          : _Less.friends;

  Future<void> _apply() async {
    final session = context.read<Session>();
    final friends = context.read<Friends>();
    try {
      final String message;
      switch (_choice) {
        case _Less.mute:
          await session.api.put('/me/mutes/${widget.userId}', null);
          unawaited(friends.load());
          message = '${widget.userName} ist stumm. Rückgängig unter Freunde.';
        case _Less.friends:
          await session.updateSettings(pushFriends: false);
          message = 'Keine Pushes mehr, wenn Freunde einchecken.';
        case _Less.places:
          await session.updateSettings(pushNewPlaces: false);
          message = 'Keine Pushes mehr zu neuen Läden.';
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      messenger.showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (mounted) showMessage(context, 'Nicht gespeichert: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final options = [
      if (widget.aboutFriend && widget.userId != null)
        (_Less.mute, '${widget.userName} stummschalten', 'Keine Pushes mehr, wenn ${widget.userName} eincheckt. Die anderen schon.'),
      if (widget.aboutFriend) (_Less.friends, 'Keine Check-ins von Freunden mehr', 'Schaltet „Freunde checken ein“ aus.'),
      if (!widget.aboutFriend) (_Less.places, 'Keine neuen Läden mehr', 'Schaltet „Neue Läden in deiner Stadt“ aus.'),
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 4), child: Text('Weniger davon', style: theme.textTheme.titleLarge)),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('In den Mitteilungen auf Start bleibt es, nur der Push fällt weg.', style: theme.textTheme.bodySmall),
            ),
            RadioGroup<_Less>(
              groupValue: _choice,
              onChanged: (value) => setState(() => _choice = value!),
              child: Column(
                children: [
                  for (final (value, title, subtitle) in options)
                    RadioListTile<_Less>(value: value, title: Text(title), subtitle: Text(subtitle)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8,
                children: [
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
                  FilledButton(onPressed: _apply, child: const Text('Übernehmen')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
