import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/session.dart';
import '../../ui/widgets.dart';
import 'friends.dart';

enum _Action { report, block, remove }

/// ⋮ on someone else's review or check-in: report the review, block its
/// author, and for admins take the review down.
class ContentMenu extends StatelessWidget {
  final UserDto user;

  /// Null for a check-in, which can't be reported.
  final String? reviewId;

  /// The user's content should vanish from the list.
  final VoidCallback onBlocked;
  final VoidCallback? onRemoved;
  const ContentMenu({super.key, required this.user, this.reviewId, required this.onBlocked, this.onRemoved});

  Future<bool> _confirm(BuildContext context, String title, String message, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Abbrechen')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
          ],
        ),
      ) ??
      false;

  Future<void> _block(BuildContext context) async {
    final ok = await _confirm(
      context,
      '${user.displayName} blockieren?',
      'Ihr seht gegenseitig keine Bewertungen mehr und findet euch nicht in der Suche. Eine Freundschaft endet. '
          'Freigeben kannst du in den Einstellungen.',
      'Blockieren',
    );
    if (!ok || !context.mounted) return;
    final friends = context.read<Friends>();
    try {
      await context.read<Session>().api.put('/me/blocks/${user.id}', null);
      if (context.mounted) showMessage(context, '${user.displayName} ist blockiert.');
      onBlocked();
      await friends.load();
    } catch (e) {
      if (context.mounted) showMessage(context, e.toString());
    }
  }

  Future<void> _remove(BuildContext context) async {
    final ok = await _confirm(context, 'Bewertung entfernen?', 'Die Bewertung von ${user.displayName} wird endgültig gelöscht.', 'Entfernen');
    if (!ok || !context.mounted) return;
    try {
      await context.read<Session>().api.delete('/reviews/$reviewId');
      if (context.mounted) showMessage(context, 'Bewertung entfernt.');
      onRemoved?.call();
    } catch (e) {
      if (context.mounted) showMessage(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final admin = context.watch<Session>().user?.admin ?? false;
    return SizedBox(
      width: 32,
      height: 24,
      child: PopupMenuButton<_Action>(
        tooltip: 'Mehr',
        padding: EdgeInsets.zero,
        iconSize: 18,
        icon: Icon(Icons.more_vert, color: Theme.of(context).colorScheme.outline),
        onSelected: (action) => switch (action) {
          _Action.report => showAppSheet(context, (_) => _ReportSheet(reviewId: reviewId!)),
          _Action.block => _block(context),
          _Action.remove => _remove(context),
        },
        itemBuilder: (_) => [
          if (reviewId != null) const PopupMenuItem(value: _Action.report, child: Text('Bewertung melden')),
          PopupMenuItem(value: _Action.block, child: Text('${user.displayName} blockieren')),
          if (admin && reviewId != null && onRemoved != null)
            const PopupMenuItem(value: _Action.remove, child: Text('Bewertung entfernen (Admin)')),
        ],
      ),
    );
  }
}

class _ReportSheet extends StatefulWidget {
  final String reviewId;
  const _ReportSheet({required this.reviewId});

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  final _note = TextEditingController();
  ReportReason? _reason;
  bool _busy = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _busy = true);
    try {
      await context.read<Session>().api.post(
            '/reviews/${widget.reviewId}/report',
            ReportRequest(reason: _reason!, note: Validation.clean(_note.text)).toJson(),
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      showMessage(context, 'Danke! Wir sehen uns die Bewertung an.');
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      children: [
        Text('Bewertung melden', style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Wir sehen uns jede Meldung an und entfernen, was nicht in die App gehört. Wer gemeldet hat, erfährt niemand.',
          style: TextStyle(color: theme.colorScheme.outline),
        ),
        const SizedBox(height: 8),
        for (final reason in ReportReason.values)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(_reason == reason ? Icons.radio_button_checked : Icons.radio_button_unchecked, color: context.accent),
            title: Text(reason.label),
            onTap: () => setState(() => _reason = reason),
          ),
        TextField(
          controller: _note,
          minLines: 2,
          maxLines: 5,
          maxLength: Validation.reportNoteMax,
          decoration: const InputDecoration(labelText: 'Was ist los? (optional)'),
        ),
        const SizedBox(height: 8),
        FilledButton(onPressed: _busy || _reason == null ? null : _send, child: const Text('Melden')),
      ],
    );
  }
}

/// Settings → Blockierte Nutzer.
class BlockedUsersScreen extends StatefulWidget {
  const BlockedUsersScreen({super.key});

  @override
  State<BlockedUsersScreen> createState() => _BlockedUsersScreenState();
}

class _BlockedUsersScreenState extends State<BlockedUsersScreen> {
  List<UserDto>? _blocked;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final json = await context.read<Session>().api.get('/me/blocks') as List;
      if (mounted) setState(() => _blocked = [for (final u in json) UserDto.fromJson(u as Map<String, dynamic>)]);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _unblock(UserDto user) async {
    try {
      await context.read<Session>().api.delete('/me/blocks/${user.id}');
      if (mounted) setState(() => _blocked = _blocked!.where((u) => u.id != user.id).toList());
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final blocked = _blocked;
    return Scaffold(
      appBar: AppBar(title: const Text('Blockierte Nutzer')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Ihr seht gegenseitig keine Bewertungen und findet euch nicht in der Suche. Wer blockiert ist, erfährt es nicht.',
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          ),
          if (_error != null)
            ListTile(leading: const Icon(Icons.error_outline), title: Text(_error!))
          else if (blocked == null)
            const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
          else if (blocked.isEmpty)
            const ListTile(title: Text('Du hast niemanden blockiert.'))
          else
            for (final user in blocked)
              ListTile(
                leading: const CircleAvatar(child: Icon(Icons.person_off_outlined)),
                title: Text(user.displayName),
                trailing: OutlinedButton(onPressed: () => _unblock(user), child: const Text('Freigeben')),
              ),
        ],
      ),
    );
  }
}
