import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../core/session.dart';
import '../../ui/widgets.dart';

/// The newest news about the app on Start, until it is dismissed. It also
/// offers to get the news by mail.
class NewsCard extends StatefulWidget {
  const NewsCard({super.key});

  @override
  State<NewsCard> createState() => _NewsCardState();
}

class _NewsCardState extends State<NewsCard> {
  UpdateDto? _update;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final session = context.read<Session>();
    if (!session.isLoggedIn) return;
    try {
      final json = await session.api.get('/updates/current');
      if (mounted) setState(() => _update = json == null ? null : UpdateDto.fromJson(json as Map<String, dynamic>));
    } catch (_) {
      // News are a nice-to-have.
    }
  }

  Future<void> _dismiss(UpdateDto update) async {
    setState(() => _update = null);
    try {
      await context.read<Session>().api.post('/updates/${update.id}/dismiss');
    } catch (_) {
      // Offline: it comes back next time.
    }
  }

  Future<void> _subscribe() async {
    try {
      await context.read<Session>().updateSettings(updateMails: true);
      if (mounted) showMessage(context, 'Neuigkeiten kommen jetzt auch per Mail.');
    } catch (e) {
      if (mounted) showMessage(context, 'Nicht gespeichert: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final update = _update;
    if (update == null) return const SizedBox.shrink();
    final subscribed = context.watch<Session>().user?.updateMails ?? false;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: NewsPreview(
        update: update,
        actions: [
          TextButton(onPressed: () => _dismiss(update), child: const Text('Ausblenden')),
          if (subscribed)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Kommt auch per Mail', style: TextStyle(color: nightMuted)),
                  SizedBox(width: 4),
                  Icon(Icons.check, size: 16, color: nightMuted),
                ],
              ),
            )
          else
            TextButton(onPressed: _subscribe, child: const Text('Auch per Mail bekommen')),
        ],
      ),
    );
  }
}

/// The card as everyone sees it, also the admin's preview.
class NewsPreview extends StatelessWidget {
  final UpdateDto update;
  final List<Widget> actions;
  const NewsPreview({super.key, required this.update, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    final highlight = accentFor(Brightness.dark);
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 8, 8),
      decoration: BoxDecoration(color: night, borderRadius: BorderRadius.circular(20)),
      child: TextButtonTheme(
        data: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: highlight)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'NEU IN DER DÖNER APP',
              style: TextStyle(color: highlight, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.8),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Text(update.title, style: displayStyle.copyWith(color: nightText, fontSize: 24, height: 1.1)),
            ),
            const SizedBox(height: 8),
            for (final feature in update.features)
              Padding(
                padding: const EdgeInsets.only(right: 10, bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('•  ', style: TextStyle(color: nightMuted)),
                    Expanded(
                      child: Text(feature, style: const TextStyle(color: nightText)),
                    ),
                  ],
                ),
              ),
            if (actions.isNotEmpty)
              SizedBox(
                width: double.infinity,
                child: Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, children: actions),
              )
            else
              const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Profil → Neuigkeiten, for admins: drafts and what went out.
class NewsAdminScreen extends StatefulWidget {
  const NewsAdminScreen({super.key});

  @override
  State<NewsAdminScreen> createState() => _NewsAdminScreenState();
}

class _NewsAdminScreenState extends State<NewsAdminScreen> {
  AdminUpdatesDto? _list;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final json = await context.read<Session>().api.get('/admin/updates');
      if (mounted) setState(() => _list = AdminUpdatesDto.fromJson(json as Map<String, dynamic>));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on OfflineException catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _edit([UpdateDto? update]) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NewsEditor(update: update, subscribers: _list?.subscribers ?? 0),
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = _list;
    return Scaffold(
      appBar: AppBar(title: const Text('Neuigkeiten')),
      body: _Column(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_error != null)
                Text(_error!, style: TextStyle(color: theme.colorScheme.error))
              else if (list == null)
                const Center(child: CircularProgressIndicator())
              else ...[
                Text(
                  'Erscheint als Karte auf Start, auf Wunsch auch per Mail an ${list.subscribers} Abonnenten.',
                  style: TextStyle(color: theme.colorScheme.outline),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(onPressed: () => _edit(), icon: const Icon(Icons.add), label: const Text('Neue Neuigkeit')),
                ),
                const SizedBox(height: 8),
                for (final update in list.updates)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(update.title),
                    subtitle: Text(_status(update)),
                    trailing: update.publishedAt == null ? const Icon(Icons.chevron_right) : null,
                    onTap: update.publishedAt == null ? () => _edit(update) : null,
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _status(UpdateDto update) {
    final published = update.publishedAt;
    if (published == null) return 'Entwurf';
    final day = formatDay(published.toLocal());
    final mail = update.byMail
        ? update.pending > 0
              ? ' · wird gesendet, ${update.sent} von ${update.sent + update.pending + update.failed}'
              : ' · an ${update.sent} gesendet${update.failed > 0 ? ', ${update.failed} fehlgeschlagen' : ''}'
        : '';
    return 'Am $day veröffentlicht${update.inApp ? ' · in der App' : ''}$mail';
  }
}

/// Writing and publishing one piece of news. Published news can't change.
class NewsEditor extends StatefulWidget {
  final UpdateDto? update;
  final int subscribers;
  const NewsEditor({super.key, this.update, required this.subscribers});

  @override
  State<NewsEditor> createState() => _NewsEditorState();
}

class _NewsEditorState extends State<NewsEditor> {
  late final _title = TextEditingController(text: widget.update?.title);
  late final _features = TextEditingController(text: widget.update?.features.join('\n'));
  late bool _inApp = widget.update?.inApp ?? true;
  late bool _byMail = widget.update?.byMail ?? true;
  late String? _id = widget.update?.id;
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    _features.dispose();
    super.dispose();
  }

  UpdateDraftRequest get _draft => UpdateDraftRequest(
    title: _title.text.trim(),
    features: [
      for (final line in _features.text.split('\n'))
        if (line.replaceFirst(RegExp(r'^\s*[-•]\s*'), '').trim() case final f when f.isNotEmpty) f,
    ],
    inApp: _inApp,
    byMail: _byMail,
  );

  UpdateDto get _preview => UpdateDto(id: _id ?? '', title: _draft.title, features: _draft.features);

  /// Saves the draft first, so every action works on what is shown.
  Future<bool> _run(Future<void> Function(ApiClient api) action, String done) async {
    final api = context.read<Session>().api;
    setState(() => _busy = true);
    try {
      final json = _id == null ? await api.post('/admin/updates', _draft.toJson()) : await api.put('/admin/updates/$_id', _draft.toJson());
      _id = UpdateDto.fromJson(json as Map<String, dynamic>).id;
      await action(api);
      if (mounted) showMessage(context, done);
      return true;
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message);
    } on OfflineException catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    return false;
  }

  Future<void> _publish() async {
    final mail = _byMail ? 'Geht per Mail an ${widget.subscribers} Abonnenten. ' : '';
    final app = _inApp ? 'Erscheint sofort als Karte auf Start. ' : '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_byMail ? 'Neuigkeit senden?' : 'Neuigkeit veröffentlichen?'),
        content: Text('$app${mail}Danach lässt sich der Text nicht mehr ändern.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Abbrechen')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(_byMail ? 'Ja, senden' : 'Ja, veröffentlichen')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final published = await _run((api) => api.post('/admin/updates/$_id/publish'), _byMail ? 'Versand gestartet.' : 'Veröffentlicht.');
    if (published && mounted) Navigator.of(context).pop();
  }

  void _showPreview() => showAppSheet(
    context,
    (_) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('So sieht die Karte aus', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            NewsPreview(update: _preview),
            const SizedBox(height: 12),
            const Text('Die Mail zeigt denselben Text mit dem Knopf „Döner App öffnen“. Wie sie ankommt, zeigt die Testmail.'),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final nothing = !_inApp && !_byMail;
    return Scaffold(
      appBar: AppBar(title: Text(_id == null ? 'Neue Neuigkeit' : 'Neuigkeit')),
      body: _Column(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _title,
              maxLength: 120,
              decoration: const InputDecoration(labelText: 'Titel'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _features,
              minLines: 4,
              maxLines: 12,
              decoration: const InputDecoration(labelText: 'Was ist neu?', helperText: 'Ein Punkt pro Zeile, höchstens 10'),
            ),
            const SizedBox(height: 16),
            Text(
              'Wo erscheint sie?',
              style: TextStyle(color: context.accent, fontWeight: FontWeight.w600),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _inApp,
              onChanged: (v) => setState(() => _inApp = v!),
              title: const Text('Als Karte in der App'),
              subtitle: const Text('Für alle auf Start, bis sie sie ausblenden.'),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _byMail,
              onChanged: (v) => setState(() => _byMail = v!),
              title: Text('Per Mail an ${widget.subscribers} Abonnenten'),
              subtitle: const Text('Nur wer „Neuigkeiten per Mail“ eingeschaltet hat.'),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(onPressed: _showPreview, icon: const Icon(Icons.visibility_outlined), label: const Text('Vorschau')),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton(onPressed: _busy ? null : () => _run((_) async {}, 'Entwurf gespeichert.'), child: const Text('Speichern')),
                OutlinedButton(
                  onPressed: _busy ? null : () => _run((api) => api.post('/admin/updates/$_id/test'), 'Testmail an dich geschickt.'),
                  child: const Text('Testmail an mich'),
                ),
                FilledButton(
                  onPressed: _busy || nothing ? null : _publish,
                  child: Text(_byMail ? 'An ${widget.subscribers} senden' : 'In der App veröffentlichen'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The admin screens keep to the width of the tabs on wide screens (see HomeShell).
class _Column extends StatelessWidget {
  final Widget child;
  const _Column({required this.child});

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: child),
  );
}
