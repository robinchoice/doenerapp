import 'dart:convert';

import 'package:doener_app/src/core/api.dart';
import 'package:doener_app/src/features/update/update_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('a 426 from the API asks for the update with its link', () async {
    final api = ApiClient(
      baseUrl: () => 'https://doener.test/api/v1',
      token: () => null,
      client: MockClient((_) async => http.Response(
            jsonEncode({'error': 'Zu alt', 'code': 'UPDATE_REQUIRED', 'url': 'https://doener.test/android'}),
            426,
          )),
    );
    expect(api.updateRequired.value, isNull);
    await expectLater(api.get('/places'), throwsA(isA<ApiException>()));
    expect(api.updateRequired.value, 'https://doener.test/android');
  });

  testWidgets('the update screen offers the link only when there is one', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: UpdateScreen(url: 'https://doener.test/android')));
    expect(find.text('Update nötig'), findsOneWidget);
    expect(find.text('Jetzt aktualisieren'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: UpdateScreen(url: '')));
    expect(find.text('Jetzt aktualisieren'), findsNothing);
  });
}
