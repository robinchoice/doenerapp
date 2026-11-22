import 'dart:convert';
import 'dart:ui' show PointerDeviceKind;

import 'package:doener_app/src/core/session.dart';
import 'package:doener_app/src/features/place/check_in_sheet.dart';
import 'package:doener_app/src/features/social/comments.dart';
import 'package:doener_app/src/ui/app_dock.dart';
import 'package:doener_app/src/ui/dock.dart';
import 'package:doener_app/src/ui/widgets.dart' show showAppSheet, ActivityCard;
import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  testWidgets('regression: the food ring follows a circular drag before release', (tester) async {
    var selected = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: SizedBox(width: 320,
      child: StatefulBuilder(builder: (context, setState) => RotaryPicker(items: FoodItem.all.take(4).toList(), selected: selected,
        onChanged: (i) => setState(() => selected = i))))))));
    final center = tester.getCenter(find.byType(RotaryPicker));
    final gesture = await tester.startGesture(center + const Offset(100, 0));
    await gesture.moveTo(center + const Offset(100, 12));
    await gesture.moveTo(center + const Offset(0, 100));
    await tester.pump();
    expect(selected, 3);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('Teller'), findsOneWidget);
    await tester.tap(find.text('🌯'));
    await tester.pumpAndSettle();
    expect(selected, 1);
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('regression: circle drag stays on the wheel inside a $platform sheet', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final db = await newDatabaseFactoryMemory().openDatabase('wheel.db');
      final session = Session(db)..user = const AccountDto(id: 'me', displayName: 'Robin');
      await tester.pumpWidget(ChangeNotifierProvider.value(value: session, child: MaterialApp(theme: ThemeData(platform: platform),
        home: Scaffold(body: Builder(builder: (context) => TextButton(onPressed: () => showAppSheet(context,
          (_) => const CheckInSheet(places: [PlaceDto(placeId: 'p1', name: 'Grill', latitude: 48, longitude: 7.85)])), child: const Text('Open')))))));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final center = tester.getCenter(find.byType(RotaryPicker));
      final gesture = await tester.startGesture(center + const Offset(110, 0), kind: PointerDeviceKind.touch);
      for (final point in [const Offset(110, 12), const Offset(108, 24), const Offset(75, 75), const Offset(0, 110)]) {
        await gesture.moveTo(center + point);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, 'Pide · Check in now'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('regression: comments accept Unicode and keep drafts across resizing', (tester) async {
    final saved = <PostCommentDto>[];
    final db = await newDatabaseFactoryMemory().openDatabase('comments.db');
    final session = Session(db, httpClient: MockClient((request) async {
      Object value;
      if (request.method == 'POST') {
        saved.insert(0, PostCommentDto(id: 'c1', user: const UserDto(id: 'me', displayName: 'Robin'),
          text: (jsonDecode(request.body) as Map)['text'] as String, createdAt: DateTime.now()));
        value = saved.first.toJson();
      } else if (request.method == 'DELETE') {
        saved.clear();
        return http.Response('', 204);
      } else {
        value = PostCommentsPage(comments: saved).toJson();
      }
      return http.Response(jsonEncode(value), 200, headers: {'content-type': 'application/json'});
    }))..user = const AccountDto(id: 'me', displayName: 'Robin');
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider.value(value: session, child: const MaterialApp(home: Scaffold(
      body: CommentsButton(type: FeedItemType.review, postId: 'r1', author: 'Tom', placeName: 'Grill', allowed: true, count: 0)))));
    await tester.tap(find.text('0 Comments'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Guten Appetit!');
    tester.view.physicalSize = const Size(900, 700);
    tester.view.viewInsets = const FakeViewPadding(bottom: 250);
    await tester.pumpAndSettle();
    expect(find.text('Guten Appetit!'), findsOneWidget);
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(saved.single.text, 'Guten Appetit!');
    expect(find.text('1 Comment'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(saved, isEmpty);
    expect(find.text('0 Comments'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '🥙' * 1000);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(saved, hasLength(1));
    expect(saved.single.text.runes, hasLength(1000));
    expect(tester.takeException(), isNull);
  });

  testWidgets('regression: framed feed posts keep food and distinguish contact reviews', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListView(children: [
      ActivityCard(type: FeedItemType.visit, framed: true, title: 'Tom', placeName: 'Grill',
        timestamp: DateTime.now(), foodType: 'yufka', highlight: true),
      ActivityCard(type: FeedItemType.review, framed: true, title: 'Ina', placeName: 'Far away',
        timestamp: DateTime.now(), highlight: true),
      ActivityCard(type: FeedItemType.review, framed: true, title: 'Mo', placeName: 'Nearby', timestamp: DateTime.now()),
    ]))));
    expect(find.text('🌯 Yufka · Friends only'), findsOneWidget);
    expect(find.text('Public review · Contact'), findsOneWidget);
    expect(find.text('Public review · Nearby'), findsOneWidget);
  });

  testWidgets('public posts explain private comments without requesting them', (tester) async {
    final db = await newDatabaseFactoryMemory().openDatabase('private.db');
    var requests = 0;
    final session = Session(db, httpClient: MockClient((_) async { requests++; return http.Response('{}', 500); }))
      ..user = const AccountDto(id: 'me', displayName: 'Robin');
    await tester.pumpWidget(ChangeNotifierProvider.value(value: session, child: const MaterialApp(home: Scaffold(
      body: CommentsButton(type: FeedItemType.review, postId: 'r2', author: 'Stranger', placeName: 'Grill', allowed: false)))));
    await tester.tap(find.text('Comments'));
    await tester.pumpAndSettle();
    expect(find.text('Only the author and their friends can see and write comments.'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(requests, 0);
  });

  test('dock rejects non-web links and grows within a narrow viewport', () {
    expect(() => parsePleasanceApps({'apps': [{'name': 'Bad', 'url': 'javascript:bad', 'icon': 'https://example.org/a.svg',
      'band': {'from': 2, 'to': 3}}]}), throwsFormatException);
    for (final pointer in [8.0, 160.0, 300.0]) {
      final row = dockLayout(sizes: [24, 40, 40, 24, 40, 24, 24], gap: 4, grow: .45, reach: 2.5,
        center: 160, pointer: pointer, min: 8, max: 312);
      expect(row.first.left, greaterThanOrEqualTo(8));
      expect(row.last.left + row.last.size, lessThanOrEqualTo(312));
    }
  });

  testWidgets('dock loads on demand and keyboard opens apps after resizing', (tester) async {
    final semantics = tester.ensureSemantics();
    var loads = 0;
    Uri? opened;
    await tester.pumpWidget(MaterialApp(home: Scaffold(bottomNavigationBar: AppDock(loadApps: () async {
      loads++;
      return [PleasanceApp(name: 'Music Hub', url: Uri.parse('https://hub.pleasance.org'), from: 1.35, to: 2.2)];
    }, openUrl: (uri) => opened = uri))));
    expect(loads, 0);
    await tester.tap(find.byType(AppDock));
    await tester.pumpAndSettle();
    expect(loads, 1);
    expect(tester.getSemantics(find.bySemanticsLabel('Music Hub')).getSemanticsData().linkUrl, Uri.parse('https://hub.pleasance.org'));
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(opened, Uri.parse('https://hub.pleasance.org'));
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('regression: lifting a finger held through a resize launches nothing', (tester) async {
    final semantics = tester.ensureSemantics();
    Uri? opened;
    await tester.pumpWidget(MaterialApp(home: Scaffold(bottomNavigationBar: AppDock(loadApps: () async => [
      PleasanceApp(name: 'Music Hub', url: Uri.parse('https://hub.pleasance.org'), from: 1.35, to: 2.2),
      PleasanceApp(name: 'Savor', url: Uri.parse('https://savor.pleasance.org'), from: 3.5, to: 4.2),
    ], openUrl: (uri) => opened = uri))));
    await tester.tap(find.byType(AppDock));
    await tester.pumpAndSettle();
    final hub = tester.getCenter(find.bySemanticsLabel('Music Hub'));
    final gesture = await tester.startGesture(hub + const Offset(0, 30));
    await gesture.moveTo(hub);
    await tester.pump();
    expect(find.text('Music Hub', findRichText: true), findsOneWidget);
    tester.view.physicalSize = Size(400 * tester.view.devicePixelRatio, tester.view.physicalSize.height);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpAndSettle();
    expect(find.text('Music Hub', findRichText: true), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(opened, isNull);
    expect(find.bySemanticsLabel('Music Hub'), findsOneWidget, reason: 'the dock stays open');
    semantics.dispose();
  });
}
