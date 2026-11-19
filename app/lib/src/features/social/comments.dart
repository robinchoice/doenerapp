import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/session.dart';
import '../../ui/widgets.dart';

class CommentsButton extends StatefulWidget {
  final FeedItemType type;
  final String postId;
  final String author;
  final String placeName;
  final String? text;
  final bool allowed;
  final int? count;
  const CommentsButton({super.key, required this.type, required this.postId, required this.author,
    required this.placeName, this.text, required this.allowed, this.count});

  @override
  State<CommentsButton> createState() => _CommentsButtonState();
}

class _CommentsButtonState extends State<CommentsButton> {
  late int? _count = widget.count;
  @override
  void didUpdateWidget(CommentsButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.postId != widget.postId || oldWidget.count != widget.count) _count = widget.count;
  }

  @override
  Widget build(BuildContext context) {
    final en = Localizations.localeOf(context).languageCode == 'en';
    return TextButton.icon(
      icon: Icon(widget.allowed ? Icons.chat_bubble_outline : Icons.lock_outline, size: 18),
      label: Text('${_count == null ? '' : '$_count '}${en ? (_count == 1 ? 'Comment' : 'Comments') : (_count == 1 ? 'Kommentar' : 'Kommentare')}'),
      onPressed: () => showAppSheet(context, (_) => CommentsSheet(post: widget, onCountChanged: (delta) {
        if (mounted && _count != null) setState(() => _count = _count! + delta);
      })),
    );
  }
}

class CommentsSheet extends StatefulWidget {
  final CommentsButton post;
  final ValueChanged<int>? onCountChanged;
  const CommentsSheet({super.key, required this.post, this.onCountChanged});
  @override
  State<CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<CommentsSheet> {
  final _text = TextEditingController();
  final _comments = <PostCommentDto>[];
  bool _loading = false;
  bool _sending = false;
  bool _hasMore = true;
  String? _cursor;
  String? _error;
  String get _path => '/${widget.post.type == FeedItemType.visit ? 'visits' : 'reviews'}/${widget.post.postId}/comments';

  @override
  void initState() {
    super.initState();
    if (widget.post.allowed) _load();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() { _loading = true; _error = null; });
    try {
      final page = PostCommentsPage.fromJson(await context.read<Session>().api.get(_path, query: {'cursor': ?_cursor}) as Map<String, dynamic>);
      if (!mounted) return;
      setState(() { _comments.addAll(page.comments); _cursor = page.cursor; _hasMore = page.hasMore; });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    final text = Validation.clean(_text.text);
    if (_sending || _loading || text == null || text.runes.length > maxCommentLength) return;
    setState(() => _sending = true);
    try {
      final c = PostCommentDto.fromJson(await context.read<Session>().api.post(_path, {'text': text}) as Map<String, dynamic>);
      if (!mounted) return;
      setState(() { _comments.insert(0, c); _text.clear(); });
      widget.onCountChanged?.call(1);
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _delete(PostCommentDto comment) async {
    try {
      await context.read<Session>().api.delete('$_path/${comment.id}');
      if (mounted) {
        setState(() => _comments.removeWhere((c) => c.id == comment.id));
        widget.onCountChanged?.call(-1);
      }
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final en = Localizations.localeOf(context).languageCode == 'en';
    final theme = Theme.of(context);
    final me = context.read<Session>().user!.id;
    final length = _text.text.runes.length;
    final tooLong = length > maxCommentLength;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .8,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(en ? 'Among friends' : 'Unter Kontakten', style: theme.textTheme.titleLarge),
          Text('${widget.post.author} · ${widget.post.placeName}', style: theme.textTheme.labelLarge),
          if (widget.post.text case final text?) Text(text, maxLines: 2, overflow: TextOverflow.ellipsis),
          const Divider(),
        ])),
        if (!widget.post.allowed)
          Expanded(child: Center(child: Padding(padding: const EdgeInsets.all(20), child: Text(en
              ? 'Only the author and their friends can see and write comments.'
              : 'Kommentare sehen und schreiben nur Kontakte des Kontos, das den Beitrag geteilt hat, und das Konto selbst.'))))
        else ...[
          Expanded(child: _comments.isEmpty && _loading ? const Center(child: CircularProgressIndicator())
            : _comments.isEmpty && _error == null ? Center(child: Text(en ? 'Start the conversation.' : 'Fang die Unterhaltung an.'))
            : Align(alignment: Alignment.topCenter, child: ListView(shrinkWrap: true, reverse: true, padding: const EdgeInsets.symmetric(horizontal: 20), children: [
              for (final c in _comments) Padding(padding: const EdgeInsets.only(bottom: 16), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                CircleAvatar(radius: 16, child: Text(c.user.displayName.characters.first.toUpperCase())),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${c.user.displayName} · ${relativeTime(c.createdAt)}', style: theme.textTheme.labelMedium),
                  const SizedBox(height: 4),
                  Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12)), child: Text(c.text)),
                  if (c.user.id == me) TextButton(onPressed: () => _delete(c), child: Text(en ? 'Delete' : 'Löschen')),
                ])),
              ])),
              if (_hasMore && _error == null) TextButton(onPressed: _loading ? null : _load, child: Text(en ? 'Older comments' : 'Ältere Kommentare')),
            ]))),
          if (_error != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Column(children: [
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            TextButton(onPressed: _load, child: Text(en ? 'Try again' : 'Erneut versuchen')),
          ])),
          Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 16), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: TextField(controller: _text, minLines: 1, maxLines: 3,
              onChanged: (_) => setState(() {}), decoration: InputDecoration(hintText: en ? 'Your comment' : 'Dein Kommentar',
                counterText: '$length/$maxCommentLength',
                errorText: tooLong ? (en ? 'Up to 1000 characters' : 'Höchstens 1000 Zeichen') : null))),
            IconButton(tooltip: en ? 'Send' : 'Senden', onPressed: _sending || _loading || tooLong || Validation.clean(_text.text) == null ? null : _send,
              icon: _sending ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send)),
          ])),
        ],
      ]),
    );
  }
}
