import 'dart:convert';

import 'package:doener_models/doener_models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:sembast/sembast.dart';

import '../../core/api.dart';
import '../../core/app_data.dart';
import '../../core/location.dart';
import '../../core/push.dart';
import '../../core/reminders.dart';
import '../../core/session.dart';
import '../../ui/widgets.dart';
import '../social/friends.dart';
import '../social/moderation.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _name = TextEditingController(text: context.read<Session>().user?.displayName);
  late final _apiBase = TextEditingController(text: context.read<Session>().apiBase == defaultApiBase ? '' : context.read<Session>().apiBase);
  final _info = PackageInfo.fromPlatform();
  String? _nameError;

  @override
  void dispose() {
    _name.dispose();
    _apiBase.dispose();
    super.dispose();
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Abbrechen')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Ja, machen')),
          ],
        ),
      ) ??
      false;

  Future<void> _saveName() async {
    final error = Validation.displayNameError(_name.text);
    setState(() => _nameError = error);
    if (error != null) return;
    try {
      await context.read<Session>().updateDisplayName(_name.text.trim());
      if (mounted) showMessage(context, 'Anzeigename aktualisiert.');
    } catch (e) {
      setState(() => _nameError = e.toString());
    }
  }

  /// Switching a push on is a tap, so browsers allow asking for permission here.
  Future<void> _updatePush({bool? pushFriends, bool? pushNewPlaces}) async {
    final session = context.read<Session>();
    final push = context.read<Push?>();
    final position = context.read<LocationService>().position;
    try {
      await session.updateSettings(pushFriends: pushFriends, pushNewPlaces: pushNewPlaces);
      if (pushFriends == true || pushNewPlaces == true) {
        await push?.register(session, latitude: position?.latitude, longitude: position?.longitude);
      }
    } catch (e) {
      if (mounted) showMessage(context, 'Nicht gespeichert: $e');
    }
  }

  Future<void> _updateSettings({Diet? diet, bool? expertMode}) async {
    try {
      await context.read<Session>().updateSettings(diet: diet, expertMode: expertMode);
    } catch (e) {
      if (mounted) showMessage(context, 'Nicht gespeichert: $e');
    }
  }

  Future<void> _logout() async {
    final data = context.read<AppData>();
    final pending = data.pendingCount;
    final ok = await _confirm(
      'Abmelden',
      pending > 0
          ? '$pending Einträge wurden noch nicht übertragen und gehen beim Abmelden verloren.'
          : 'Deine Besuche und Bewertungen bleiben auf dem Server gespeichert.',
    );
    if (!ok || !mounted) return;
    final session = context.read<Session>();
    await context.read<Push?>()?.unregister(session);
    await session.logout();
    await data.clearAccountData();
  }

  Future<void> _deleteAccount() async {
    final ok = await _confirm('Account löschen', 'Dein Account, alle Besuche, Bewertungen und Freundschaften werden endgültig gelöscht.');
    if (!ok || !mounted) return;
    try {
      final data = context.read<AppData>();
      await context.read<Session>().deleteAccount();
      await data.clearAccountData();
      if (mounted) showMessage(context, 'Account gelöscht.');
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    }
  }

  Future<void> _fullReset() async {
    final ok = await _confirm('Komplett zurücksetzen', 'Alles weg – wie nach einer frischen Installation. Das Onboarding läuft erneut.');
    if (!ok || !mounted) return;
    final session = context.read<Session>();
    final data = context.read<AppData>();
    final db = context.read<Database>();
    await session.logout();
    await data.clearDeviceData();
    await session.setApiBase(null);
    await settingsStore.record('onboardingDone').delete(db);
    await settingsStore.record('invitePromptDone').delete(db);
    await pendingInviteRecord.delete(db);
    if (mounted) showMessage(context, 'Zurückgesetzt. Beim nächsten Start läuft das Onboarding.');
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final data = context.watch<AppData>();
    final theme = Theme.of(context);
    Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(text, style: theme.textTheme.titleSmall?.copyWith(color: context.accent)),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Einstellungen')),
      body: ListView(
        children: [
          header('Account'),
          if (session.isLoggedIn) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _name,
                maxLength: Validation.displayNameMax,
                decoration: InputDecoration(
                  labelText: 'Anzeigename',
                  errorText: _nameError,
                  suffixIcon: IconButton(icon: const Icon(Icons.check), onPressed: _saveName),
                ),
                onSubmitted: (_) => _saveName(),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.block),
              title: const Text('Blockierte Nutzer'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BlockedUsersScreen())),
            ),
            ListTile(leading: const Icon(Icons.logout), title: const Text('Abmelden'), onTap: _logout),
            ListTile(
              leading: Icon(Icons.delete_forever, color: theme.colorScheme.error),
              title: Text('Account löschen', style: TextStyle(color: theme.colorScheme.error)),
              onTap: _deleteAccount,
            ),
          ],
          if (session.isLoggedIn) ...[
            header('Ernährung'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<Diet>(
                segments: [for (final d in Diet.values) ButtonSegment(value: d, label: Text(d.label))],
                selected: {session.diet},
                showSelectedIcon: false,
                onSelectionChanged: (s) => _updateSettings(diet: s.first),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                switch (session.diet) {
                  Diet.all => 'Du siehst alle Bewertungen und Ranglisten.',
                  Diet.vegetarian => 'Kein Fleisch in Bewertung, Ranking und Karte. Statt Gesamt zählt die Note ohne Fleisch.',
                  Diet.vegan => 'Nur Veganes in Bewertung, Ranking und Karte. Läden ohne vegane Optionen verschwinden.',
                },
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
            if (context.read<Push?>() != null) ...[
              header('Benachrichtigungen'),
              SwitchListTile(
                title: const Text('Freunde checken ein'),
                subtitle: const Text('Wo deine Freunde gerade essen, höchstens alle 3 Stunden pro Person. Einzelne stellst du unter Freunde stumm.'),
                value: session.user!.pushFriends,
                onChanged: (value) => _updatePush(pushFriends: value),
              ),
              SwitchListTile(
                title: const Text('Neue Läden in deiner Stadt'),
                subtitle: const Text('Sobald ein angekündigter Döner aufmacht.'),
                value: session.user!.pushNewPlaces,
                onChanged: (value) => _updatePush(pushNewPlaces: value),
              ),
            ],
            header('Bewerten'),
            SwitchListTile(
              title: const Text('Expertenmodus'),
              subtitle: const Text('Fragt beim Bewerten, was in „mit allem“ steckt, dazu Fleisch, Spieß und Brot. Zeigt am Laden die ganze Zutatenliste.'),
              value: session.expertMode,
              onChanged: (value) => _updateSettings(expertMode: value),
            ),
            if (context.read<Reminders?>() case final reminders?)
              SwitchListTile(
                title: const Text('Erinnerung nach dem Check-in'),
                subtitle: const Text('Eine halbe Stunde später fragt die App, wie es war.'),
                value: reminders.enabled,
                onChanged: (value) async {
                  await reminders.setEnabled(value);
                  setState(() {});
                },
              ),
          ],
          header('Synchronisation'),
          ListTile(
            leading: data.syncing
                ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(data.pendingCount == 0 ? Icons.cloud_done : Icons.cloud_upload),
            title: Text(data.pendingCount == 0 ? 'Alles übertragen' : '${data.pendingCount} Einträge warten'),
            subtitle: data.lastSyncError == null ? null : Text(data.lastSyncError!),
            trailing: TextButton(
              onPressed: data.syncing
                  ? null
                  : () async {
                      await data.sync();
                      await data.refreshMine();
                    },
              child: const Text('Jetzt'),
            ),
          ),
          header('Feedback'),
          ListTile(
            leading: const Icon(Icons.feedback_outlined),
            title: const Text('Feedback geben'),
            subtitle: const Text('Fehler gefunden oder Idee für die App? Wir sind in der Testphase.'),
            onTap: () => showAppSheet(context, (_) => const FeedbackSheet()),
          ),
          header('Backend-URL'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _apiBase,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                hintText: defaultApiBase,
                helperText: 'Leer = Standard. Praktisch zum Testen gegen einen lokalen Server.',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.check),
                  onPressed: () async {
                    await session.setApiBase(_apiBase.text);
                    if (context.mounted) showMessage(context, 'Backend: ${session.apiBase}');
                  },
                ),
              ),
            ),
          ),
          header('Daten'),
          ListTile(
            leading: const Icon(Icons.map_outlined),
            title: const Text('Karten-Cache leeren'),
            subtitle: const Text('Läden werden beim nächsten Verschieben der Karte neu geladen.'),
            onTap: () async {
              await data.clearMapCache();
              if (context.mounted) showMessage(context, 'Karten-Cache geleert.');
            },
          ),
          ListTile(
            leading: Icon(Icons.restart_alt, color: theme.colorScheme.error),
            title: Text('Komplett zurücksetzen', style: TextStyle(color: theme.colorScheme.error)),
            subtitle: const Text('Löscht alles auf diesem Gerät, meldet ab und startet das Onboarding neu.'),
            onTap: _fullReset,
          ),
          header('Über'),
          FutureBuilder(
            future: _info,
            builder: (context, snapshot) => ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text('Version ${snapshot.data?.version ?? '—'} (${snapshot.data?.buildNumber ?? '—'})'),
              subtitle: const Text('Made with ❤️ und viel Knoblauchsoße.'),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class FeedbackSheet extends StatefulWidget {
  /// The screen the tester came from; attached unless removed.
  final Uint8List? screenshot;

  const FeedbackSheet({super.key, this.screenshot});

  @override
  State<FeedbackSheet> createState() => _FeedbackSheetState();
}

class _FeedbackSheetState extends State<FeedbackSheet> {
  final _message = TextEditingController();
  late Uint8List? _screenshot = widget.screenshot;
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1080, maxHeight: 1080, imageQuality: 50);
    if (file != null) {
      final bytes = await file.readAsBytes();
      setState(() => _screenshot = bytes);
    }
  }

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      await context.read<Session>().api.post(
            '/feedback',
            FeedbackRequest(
              message: _message.text.trim(),
              screenshotBase64: _screenshot == null ? null : base64.encode(_screenshot!),
              appVersion: info.version,
              buildNumber: info.buildNumber,
              platform: kIsWeb ? 'web' : defaultTargetPlatform.name,
            ).toJson(),
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      showMessage(context, 'Danke für dein Feedback!');
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Text('Feedback geben', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            controller: _message,
            minLines: 5,
            maxLines: 10,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(hintText: 'Fehler oder Feedback beschreiben…'),
          ),
          const SizedBox(height: 12),
          if (_screenshot != null) ...[
            ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.memory(_screenshot!, height: 160, fit: BoxFit.contain)),
            TextButton(onPressed: () => setState(() => _screenshot = null), child: const Text('Screenshot entfernen')),
          ] else
            OutlinedButton.icon(onPressed: _pick, icon: const Icon(Icons.image_outlined), label: const Text('Screenshot anhängen (optional)')),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _sending || _message.text.trim().length < Validation.feedbackMin ? null : _send,
            child: const Text('Senden'),
          ),
        ],
      );
}
