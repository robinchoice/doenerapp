import 'dart:convert';

import 'package:doener_models/discover.dart';
import 'package:doener_models/doener_models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../core/session.dart';
import '../../ui/widgets.dart';
import 'friends.dart';
import 'invite.dart';

/// The address book exists only in the apps, not in the browser.
bool get canSearchContacts => !kIsWeb;

class AddressBookEntry {
  final String name;
  final List<String> numbers;
  const AddressBookEntry(this.name, this.numbers);
}

/// Reads the address book. An interface so tests need no phone.
abstract interface class ContactsSource {
  /// Null while access to the contacts is not allowed.
  Future<List<AddressBookEntry>?> read();
}

class DeviceContacts implements ContactsSource {
  const DeviceContacts();

  @override
  Future<List<AddressBookEntry>?> read() async {
    final status = await FlutterContacts.permissions.request(PermissionType.read);
    if (status != PermissionStatus.granted && status != PermissionStatus.limited) return null;
    final contacts = await FlutterContacts.getAll(properties: {ContactProperty.phone});
    return [
      for (final contact in contacts)
        if (contact.displayName case final name? when name.isNotEmpty)
          AddressBookEntry(name, [for (final phone in contact.phones) phone.number]),
    ];
  }
}

/// Opens a directory box: the profile in it, null if [output] is the wrong key.
typedef BoxOpener = Future<Map<String, Object?>?> Function(List<int> output, String box);

/// AES-GCM runs in the operating system (CryptoKit on iOS, javax.crypto on
/// Android), so the app ships no encryption of its own and stays exempt in
/// App Store Connect (`ITSAppUsesNonExemptEncryption`).
const _crypto = MethodChannel('com.robinchoice.doener/crypto');

/// A box is base64 of nonce(12) || ciphertext || tag(16), AES-256-GCM.
Future<Map<String, Object?>?> openDirectoryBox(List<int> output, String box) async {
  try {
    final bytes = base64Decode(box);
    if (bytes.length < 12 + 16) return null;
    final plain = await _crypto.invokeMethod<Uint8List>('openAesGcm', {
      'key': discoverBoxKey(output),
      'nonce': Uint8List.fromList(bytes.sublist(0, 12)),
      'sealed': Uint8List.fromList(bytes.sublist(12)),
    });
    if (plain == null) return null;
    final json = jsonDecode(utf8.decode(plain));
    return json is Map<String, dynamic> ? json : null;
  } on FormatException {
    return null;
  }
}

/// Someone from the address book who uses the app: [name] from the address
/// book, [displayName] from the app.
class ContactMatch {
  final String id;
  final String name;
  final String displayName;
  const ContactMatch(this.id, this.name, this.displayName);
}

class DiscoverResult {
  /// The address book was not readable.
  final bool denied;
  final List<ContactMatch> matches;

  /// The daily quota ended the search: [checked] of [total] numbers are done.
  final bool limited;
  final int checked;
  final int total;
  const DiscoverResult({this.denied = false, this.matches = const [], this.limited = false, this.checked = 0, this.total = 0});
}

/// The region that completes numbers without a country code: the device's,
/// Germany if it names none the number parser knows.
IsoCode deviceRegion() {
  final country = WidgetsBinding.instance.platformDispatcher.locale.countryCode?.toUpperCase();
  return IsoCode.values.asNameMap()[country] ?? IsoCode.DE;
}

/// Finds the people of the address book who are discoverable, without a
/// number leaving the phone (`package:doener_models/discover.dart`). Outputs
/// stay on the phone, so a later run checks only numbers not yet checked.
class ContactDiscovery {
  final Session session;
  final ContactsSource contacts;
  final BoxOpener open;
  final IsoCode region;

  ContactDiscovery(this.session, {this.contacts = const DeviceContacts(), this.open = openDirectoryBox, IsoCode? region})
      : region = region ?? deviceRegion();

  Future<DiscoverResult> run() async {
    final entries = await contacts.read();
    if (entries == null) return const DiscoverResult(denied: true);

    // One entry per number, named after the first contact that has it.
    final names = <String, String>{};
    for (final entry in entries) {
      for (final raw in entry.numbers) {
        if (toE164(raw, region) case final number?) names.putIfAbsent(number, () => entry.name);
      }
    }

    final saved = await session.readDiscoverCache();
    final outputs = {for (final number in names.keys) number: ?saved[number]};
    final pending = [for (final number in names.keys) if (!outputs.containsKey(number)) number];
    final client = OprfClient();
    var limited = false;
    for (var start = 0; start < pending.length; start += evaluateChunk) {
      final chunk = pending.skip(start).take(evaluateChunk).toList();
      final blinded = <Blinded>[];
      for (final number in chunk) {
        blinded.add(client.blind(utf8.encode(number)));
        await _yield(blinded.length);
      }
      final Object? answer;
      try {
        answer = await session.api.post('/discover/evaluate', {'blinded': [for (final b in blinded) base64Encode(b.element)]});
      } on ApiException catch (e) {
        if (e.status != 429) rethrow;
        limited = true;
        break;
      }
      final evaluated = switch (answer) {
        {'evaluated': final List<Object?> list} when list.length == chunk.length => list,
        _ => throw const ApiException(502, 'Ungültige Antwort vom Server'),
      };
      for (var i = 0; i < chunk.length; i++) {
        try {
          outputs[chunk[i]] = toHex(client.finalize(blinded[i], base64Decode(evaluated[i] as String)));
        } on Object {
          throw const ApiException(502, 'Ungültige Antwort vom Server');
        }
        await _yield(i + 1);
      }
      await session.writeDiscoverCache(outputs);
    }

    final matches = <ContactMatch>[];
    if (outputs.isNotEmpty) {
      final boxes = await _directory();
      for (final MapEntry(key: number, value: hex) in outputs.entries) {
        final output = hexBytes(hex);
        final box = boxes[discoverTag(output)];
        if (box == null) continue;
        if (await open(output, box) case {'id': final String id, 'name': final String displayName}
            when id != session.user?.id && !matches.any((m) => m.id == id)) {
          matches.add(ContactMatch(id, names[number]!, displayName));
        }
      }
    }
    matches.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return DiscoverResult(matches: matches, limited: limited, checked: outputs.length, total: names.length);
  }

  /// Box by tag of everyone discoverable except this account.
  Future<Map<String, String>> _directory() async {
    if (await session.api.get('/discover/directory') case {'entries': final List<Object?> entries}) {
      return {
        for (final entry in entries)
          if (entry case {'tag': final String tag, 'box': final String box}) tag: box,
      };
    }
    throw const ApiException(502, 'Ungültige Antwort vom Server');
  }

  // The curve arithmetic is slow in Dart: give the frames room now and then.
  Future<void> _yield(int count) async {
    if (count % 4 == 0) await Future<void>.delayed(Duration.zero);
  }
}

/// Confirms the own number first if needed, then searches the address book.
Future<void> openContactSearch(BuildContext context) async {
  final navigator = Navigator.of(context);
  if (!(context.read<Session>().user?.discoverable ?? false)) {
    final confirmed = await navigator.push<bool>(MaterialPageRoute(builder: (_) => const PhoneScreen()));
    if (confirmed != true) return;
  }
  await navigator.push(MaterialPageRoute<void>(builder: (_) => const DiscoverScreen()));
}

/// The entry on the contacts screen and in the onboarding.
class ContactSearchTile extends StatelessWidget {
  const ContactSearchTile({super.key});

  @override
  Widget build(BuildContext context) {
    final discoverable = context.select<Session, bool>((s) => s.user?.discoverable ?? false);
    return ListTile(
      leading: const CircleAvatar(child: Icon(Icons.contacts_outlined)),
      title: const Text('Kontakte aus dem Adressbuch finden'),
      subtitle: Text(discoverable
          ? 'Wer aus deinem Adressbuch ist schon dabei?'
          : 'Mit deiner Handynummer, ohne dass wir Nummern speichern.'),
      onTap: () => openContactSearch(context),
    );
  }
}

/// The number, then the code from the SMS. Pops with true once the account is discoverable.
class PhoneScreen extends StatefulWidget {
  const PhoneScreen({super.key});

  @override
  State<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends State<PhoneScreen> {
  final _number = TextEditingController();
  final _code = TextEditingController();
  String? _phone;
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _number.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on OfflineException {
      if (mounted) setState(() => _error = 'Keine Verbindung. Versuch es gleich noch einmal.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendCode() async {
    final phone = toE164(_number.text, deviceRegion());
    if (phone == null) {
      setState(() => _error = 'Diese Nummer ist ungültig. Gib sie mit Ländervorwahl ein, zum Beispiel +49 151 …');
      return;
    }
    await _run(() async {
      await context.read<Session>().requestPhoneCode(phone);
      if (mounted) setState(() => _phone = phone);
    });
  }

  Future<void> _confirm() => _run(() async {
        await context.read<Session>().verifyPhone(_phone!, _code.text.trim());
        if (mounted) Navigator.of(context).pop(true);
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final phone = _phone;
    final note = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline);
    return Scaffold(
      appBar: AppBar(title: const Text('Deine Handynummer')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                if (phone == null) ...[
                  const Text(
                    'Wer deine Nummer im Adressbuch hat, findet dich, und du findest deine Kontakte. '
                    'Damit niemand eine fremde Nummer einträgt, schicken wir einmal einen Code per SMS.',
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _number,
                    autofocus: true,
                    keyboardType: TextInputType.phone,
                    autofillHints: const [AutofillHints.telephoneNumber],
                    decoration: const InputDecoration(labelText: 'Handynummer', hintText: '0151 …'),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _busy ? null : _sendCode(),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy || _number.text.trim().isEmpty ? null : _sendCode,
                    child: const Text('Code per SMS schicken'),
                  ),
                  const SizedBox(height: 12),
                  Text('Gespeichert wird nur ein Schlüsselwert, aus dem sich die Nummer nicht ablesen lässt.', style: note),
                ] else ...[
                  Text('Code an ${maskNumber(phone)} geschickt.'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _code,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    decoration: const InputDecoration(labelText: 'Code aus der SMS'),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: _busy || _code.text.trim().length != 6 ? null : _confirm,
                    child: const Text('Bestätigen'),
                  ),
                  TextButton(
                    onPressed: _busy ? null : () => _run(() => context.read<Session>().requestPhoneCode(phone)),
                    child: const Text('Neuen Code schicken'),
                  ),
                  TextButton(
                    onPressed: _busy ? null : () => setState(() => _phone = null),
                    child: const Text('Andere Nummer'),
                  ),
                ],
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Searches when it opens; the contacts permission is asked only here.
class DiscoverScreen extends StatefulWidget {
  /// Only for tests; the app searches the device's address book.
  final ContactDiscovery? discovery;
  const DiscoverScreen({super.key, this.discovery});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  DiscoverResult? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search();
  }

  Future<void> _search() async {
    final friends = context.read<Friends>();
    final discovery = widget.discovery ?? ContactDiscovery(context.read<Session>());
    try {
      final result = await discovery.run();
      await friends.load();
      if (mounted) setState(() => _result = result);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on OfflineException {
      if (mounted) setState(() => _error = 'Keine Verbindung. Versuch es gleich noch einmal.');
    }
  }

  Future<void> _stopBeingFound() async {
    final navigator = Navigator.of(context);
    try {
      await context.read<Session>().removePhone();
      navigator.pop();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final note = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline);
    final result = _result;
    final requestError = context.select<Friends, String?>((f) => f.error);
    return Scaffold(
      appBar: AppBar(title: const Text('Aus deinem Adressbuch')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 16),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: switch ((_error, result)) {
                    (final error?, _) => Text(error, style: TextStyle(color: theme.colorScheme.error)),
                    (_, null) => const Row(
                        children: [
                          SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                          SizedBox(width: 12),
                          Expanded(child: Text('Dein Adressbuch wird geprüft …')),
                        ],
                      ),
                    (_, final result?) when result.denied => const Text(
                        'Ohne Zugriff auf deine Kontakte lässt sich dein Adressbuch nicht prüfen. '
                        'Du kannst ihn in den Einstellungen deines Handys erlauben.',
                      ),
                    (_, final result?) => Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (result.limited) ...[
                            Text('Heute ließen sich ${result.checked} von ${result.total} Nummern prüfen. Morgen geht es weiter.'),
                            const SizedBox(height: 8),
                          ],
                          Text(switch (result.matches.length) {
                            0 when !result.limited => 'Noch niemand aus deinem Adressbuch ist auffindbar. Lade deine Leute ein!',
                            0 => 'Bisher niemand gefunden.',
                            1 => '1 Kontakt aus deinem Adressbuch ist dabei.',
                            final n => '$n Kontakte aus deinem Adressbuch sind dabei.',
                          }),
                          if (result.matches.isEmpty) ...[
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              icon: const Icon(Icons.qr_code_2),
                              label: const Text('Kontakte einladen'),
                              onPressed: () => showAppSheet(context, (_) => const InviteSheet()),
                            ),
                          ],
                        ],
                      ),
                  },
                ),
                if (result != null && requestError != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Text(requestError, style: TextStyle(color: theme.colorScheme.error)),
                  ),
                if (result != null)
                  for (final match in result.matches) _MatchTile(match),
                if (result != null && !result.denied) ...[
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'Gefunden wird nur, wer selbst die Nummer bestätigt hat. Die Nummern prüft dein Handy, '
                      'der Server sieht sie nicht. Die Namen kommen aus deinem Adressbuch.',
                      style: note,
                    ),
                  ),
                ],
                if (result != null || _error != null) ...[
                  const SizedBox(height: 16),
                  Center(child: TextButton(onPressed: _stopBeingFound, child: const Text('Nicht mehr über meine Nummer auffindbar'))),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MatchTile extends StatelessWidget {
  final ContactMatch match;
  const _MatchTile(this.match);

  @override
  Widget build(BuildContext context) {
    final friends = context.watch<Friends>();
    final friendship = friends.all.where((f) => f.user.id == match.id).firstOrNull;
    return ListTile(
      leading: const CircleAvatar(child: Icon(Icons.person)),
      title: Text(match.name),
      subtitle: match.displayName == match.name ? null : Text('In der App: ${match.displayName}'),
      trailing: switch ((friendship?.status, friendship?.direction)) {
        (FriendshipStatus.accepted, _) => const Text('Befreundet'),
        (FriendshipStatus.pending, FriendshipDirection.outgoing) => const Text('Angefragt'),
        (FriendshipStatus.pending, _) => FilledButton(onPressed: () => friends.request(match.id), child: const Text('Annehmen')),
        _ => OutlinedButton(onPressed: () => friends.request(match.id), child: const Text('Anfragen')),
      },
    );
  }
}
