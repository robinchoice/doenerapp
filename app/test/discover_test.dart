import 'dart:convert';
import 'dart:io';

import 'package:doener_app/src/core/session.dart';
import 'package:doener_app/src/features/social/discover.dart';
import 'package:doener_app/src/features/social/friends.dart';
import 'package:doener_models/discover.dart';
import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:sembast/sembast_memory.dart' hide Finder;

class FakeContacts implements ContactsSource {
  final List<AddressBookEntry>? entries;
  const FakeContacts(this.entries);
  @override
  Future<List<AddressBookEntry>?> read() async => entries;
}

/// The API with a real OPRF key. Boxes are plain JSON with the key that opens
/// them: the AES-GCM runs natively and is checked on the server side.
class FakeApi {
  final oprf = OprfServer.fromHex('2a' * 32);

  /// Discoverable accounts: number → (id, name).
  final accounts = <String, (String, String)>{};
  final friendships = <FriendshipDto>[];
  var evaluated = 0;

  /// Numbers the API evaluates before it answers 429.
  int quota = 1000;

  late final client = MockClient((request) async {
    switch ((request.method, request.url.path)) {
      case ('POST', '/discover/evaluate'):
        final blinded = (jsonDecode(request.body)['blinded'] as List).cast<String>();
        if (evaluated + blinded.length > quota) return _json(({'error': 'Morgen weiter'}), 429);
        evaluated += blinded.length;
        return _json(({'evaluated': [for (final b in blinded) base64Encode(oprf.blindEvaluate(base64Decode(b)))]}), 200);
      case ('GET', '/discover/directory'):
        return _json(
          {
            'entries': [
              for (final MapEntry(key: number, value: (id, name)) in accounts.entries)
                {
                  'tag': discoverTag(hexBytes(phoneKey(oprf, number))),
                  'box': jsonEncode({
                    'key': toHex(discoverBoxKey(hexBytes(phoneKey(oprf, number)))),
                    'profile': {'id': id, 'name': name},
                  }),
                },
            ],
          },
          200,
        );
      case ('GET', '/friends'):
        return _json(([for (final f in friendships) f.toJson()]), 200);
      case ('POST', '/friends/requests'):
        final id = jsonDecode(request.body)['userId'] as String;
        final name = accounts.values.firstWhere((a) => a.$1 == id).$2;
        final friendship = FriendshipDto(
          id: 'f-$id',
          user: UserDto(id: id, displayName: name),
          status: FriendshipStatus.pending,
          direction: FriendshipDirection.outgoing,
          createdAt: DateTime(2026),
        );
        friendships.add(friendship);
        return _json((friendship.toJson()), 200);
    }
    return _json(({'error': 'Nicht gefunden'}), 404);
  });
}

http.Response _json(Object? body, int status) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

Future<Map<String, Object?>?> openFake(List<int> output, String box) async {
  final json = jsonDecode(box) as Map<String, dynamic>;
  return json['key'] == toHex(discoverBoxKey(output)) ? json['profile'] as Map<String, Object?> : null;
}

Future<Session> session(FakeApi api) async {
  final db = await newDatabaseFactoryMemory().openDatabase('discover-${DateTime.now().microsecondsSinceEpoch}.db');
  return Session(db, httpClient: api.client)
    ..user = const AccountDto(id: 'me', displayName: 'Ich', discoverable: true)
    ..apiBase = '';
}

const _book = [
  AddressBookEntry('Ben Bäcker', ['0151 00000002']),
  AddressBookEntry('Anna', ['+49 151 00000001', '0151 00000001']),
  AddressBookEntry('Niemand', ['0151 00000009', 'keine Nummer']),
  AddressBookEntry('Ich selbst', ['0151 00000000']),
];

void main() {
  test('regression: the app ships no cipher of its own', () {
    final cipher = RegExp(r'GCMBlockCipher|AESEngine|BlockCipher\(|package:cryptography|package:pointycastle');
    final offending = [
      for (final file in Directory('lib').listSync(recursive: true).whereType<File>())
        if (file.path.endsWith('.dart') && cipher.hasMatch(file.readAsStringSync())) file.path,
    ];
    expect(offending, isEmpty, reason: 'AES-GCM runs natively, see AGENTS.md');
  });

  test('finds discoverable people of the address book under their address book names', () async {
    final api = FakeApi()
      ..accounts['+4915100000001'] = ('anna', 'Anna K.')
      ..accounts['+4915100000002'] = ('ben', 'Döner-Ben')
      ..accounts['+4915100000000'] = ('me', 'Ich');
    final discovery = ContactDiscovery(await session(api), contacts: const FakeContacts(_book), open: openFake, region: IsoCode.DE);
    final result = await discovery.run();
    expect([for (final m in result.matches) (m.id, m.name, m.displayName)], [
      ('anna', 'Anna', 'Anna K.'),
      ('ben', 'Ben Bäcker', 'Döner-Ben'),
    ]);
    expect((result.checked, result.total, result.limited), (4, 4, false));
    expect(api.evaluated, 4, reason: 'one evaluation per distinct number');

    // Known numbers are not sent again.
    await discovery.run();
    expect(api.evaluated, 4);
  });

  test('the daily quota ends the search, a later run continues', () async {
    final api = FakeApi()
      ..accounts['+4915100000002'] = ('ben', 'Döner-Ben')
      ..quota = 0;
    final s = await session(api);
    final book = [for (var i = 0; i < evaluateChunk + 10; i++) AddressBookEntry('Kontakt $i', ['0151 1${'$i'.padLeft(7, '0')}'])];
    final limited = await ContactDiscovery(s, contacts: FakeContacts([...book, _book.first]), open: openFake, region: IsoCode.DE).run();
    expect((limited.limited, limited.checked, limited.matches.length), (true, 0, 0));

    api.quota = evaluateChunk;
    final partly = await ContactDiscovery(s, contacts: FakeContacts([...book, _book.first]), open: openFake, region: IsoCode.DE).run();
    expect((partly.limited, partly.checked, partly.total), (true, evaluateChunk, evaluateChunk + 11));

    api.quota = 1000;
    final done = await ContactDiscovery(s, contacts: FakeContacts([...book, _book.first]), open: openFake, region: IsoCode.DE).run();
    expect((done.limited, done.checked, done.matches.single.name), (false, evaluateChunk + 11, 'Ben Bäcker'));
  });

  test('without access to the contacts nothing is sent', () async {
    final api = FakeApi();
    final result = await ContactDiscovery(await session(api), contacts: const FakeContacts(null), open: openFake).run();
    expect(result.denied, isTrue);
    expect(api.evaluated, 0);
  });

  testWidgets('a match is asked to be a contact with one tap', (tester) async {
    final api = FakeApi()..accounts['+4915100000002'] = ('ben', 'Döner-Ben');
    final s = (await tester.runAsync(() => session(api)))!;
    final friends = Friends(s);
    await tester.pumpWidget(
      MultiProvider(
        providers: [ChangeNotifierProvider.value(value: s), ChangeNotifierProvider.value(value: friends)],
        child: MaterialApp(
          home: DiscoverScreen(
            discovery: ContactDiscovery(s, contacts: const FakeContacts(_book), open: openFake, region: IsoCode.DE),
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
    await tester.pumpAndSettle();
    expect(find.text('1 Kontakt aus deinem Adressbuch ist dabei.'), findsOneWidget);
    expect(find.text('Ben Bäcker'), findsOneWidget);
    expect(find.text('In der App: Döner-Ben'), findsOneWidget);

    await tester.tap(find.text('Anfragen'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(find.text('Angefragt'), findsOneWidget);
    expect(api.friendships.single.user.id, 'ben');
  });
}
