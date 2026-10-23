import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/session.dart';
import '../../ui/widgets.dart';

/// Friends' reactions under a check-in or review. With [path] (`/visits/<id>` or
/// `/reviews/<id>`) a tap picks one of [reactionEmojis] or takes it back; without,
/// it only shows what others picked, as on one's own posts.
class ReactionBar extends StatefulWidget {
  final String? path;
  final Map<String, int> reactions;
  final String? mine;
  const ReactionBar({super.key, this.path, required this.reactions, this.mine});

  @override
  State<ReactionBar> createState() => _ReactionBarState();
}

class _ReactionBarState extends State<ReactionBar> {
  late final _counts = Map.of(widget.reactions);
  late var _mine = widget.mine;

  Future<void> _react(String emoji) async {
    final (counts, mine) = (Map.of(_counts), _mine);
    final next = emoji == _mine ? null : emoji;
    setState(() {
      if (_mine != null) _counts.update(_mine!, (n) => n - 1);
      if (next != null) _counts.update(next, (n) => n + 1, ifAbsent: () => 1);
      _counts.removeWhere((_, n) => n <= 0);
      _mine = next;
    });
    final api = context.read<Session>().api;
    final path = '${widget.path}/reaction';
    try {
      next == null ? await api.delete(path) : await api.put(path, ReactionRequest(next).toJson());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _counts
          ..clear()
          ..addAll(counts);
        _mine = mine;
      });
      showMessage(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final emojis = widget.path == null ? [for (final e in reactionEmojis) if (_counts.containsKey(e)) e] : reactionEmojis;
    return Wrap(spacing: 8, runSpacing: 6, children: [
      for (final emoji in emojis)
        Material(
          color: emoji == _mine ? context.accent.withValues(alpha: 0.12) : Colors.transparent,
          shape: StadiumBorder(side: BorderSide(color: emoji == _mine ? context.accent : theme.dividerColor)),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: widget.path == null ? null : () => _react(emoji),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Text(_counts[emoji] == null ? emoji : '$emoji ${_counts[emoji]}', style: theme.textTheme.labelLarge),
            ),
          ),
        ),
    ]);
  }
}
