import 'package:doener_app/src/core/app_data.dart';
import 'package:doener_app/src/core/session.dart';
import 'package:doener_app/src/features/place/review_sheet.dart';
import 'package:doener_app/src/features/profile/profile_screen.dart';
import 'package:doener_app/src/ui/widgets.dart';
import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sembast/sembast_memory.dart' hide Finder;

const _place = PlaceDto(placeId: 'p1', name: 'Kebap Haus', latitude: 48, longitude: 7.85);

/// The review sheet as the place detail opens it, for [account].
Future<AppData> _openSheet(WidgetTester tester, AccountDto account, {PlaceSummaryDto? summary}) async {
  tester.view.physicalSize = const Size(1170, 6000);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final data = (await tester.runAsync(_appData))!;
  data.session.user = account;
  await tester.pumpWidget(
    MultiProvider(
      providers: [ChangeNotifierProvider.value(value: data), ChangeNotifierProvider.value(value: data.session)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showAppSheet(context, (_) => ReviewSheet(place: _place, summary: summary)),
              child: const Text('Öffnen'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Öffnen'));
  await tester.pumpAndSettle();
  return data;
}

/// Scrolls the sheet to [finder] (its children are built lazily) and taps it.
Future<void> _tapInSheet(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).last);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Taps the [value]th fork in the rating row of [label].
Future<void> _rate(WidgetTester tester, String label, int value) async {
  final row = find.ancestor(of: find.text(label), matching: find.byType(Row)).first;
  await tester.tap(find.descendant(of: row, matching: find.byType(GestureDetector)).at(value - 1));
  await tester.pumpAndSettle();
}

Future<AppData> _appData() async {
  final db = await newDatabaseFactoryMemory().openDatabase('test.db');
  return AppData(db, Session(db))..places[_place.placeId] = _place;
}

void main() {
  test('map cache keeps places the user interacted with', () async {
    final data = await _appData();
    data.places['p2'] = const PlaceDto(placeId: 'p2', name: 'Anderer Laden', latitude: 48, longitude: 7.8);
    await data.toggleFavorite('p1');
    await data.clearMapCache();
    expect(data.places.keys, ['p1']);
  });

  test('cached places expire after 30 days', () async {
    final db = await newDatabaseFactoryMemory().openDatabase('test.db');
    final store = stringMapStoreFactory.store('places');
    final now = DateTime.now();
    await store.record('fresh').put(db, {'dto': _place.toJson(), 'cachedAt': now.millisecondsSinceEpoch});
    await store.record('old').put(db, {
      'dto': _place.toJson(),
      'cachedAt': now.subtract(const Duration(days: 31)).millisecondsSinceEpoch,
    });
    await store.record('legacy').put(db, _place.toJson()); // format without timestamp

    final data = AppData(db, Session(db));
    await data.load();
    expect(data.places.keys, ['fresh']);
    expect(await store.count(db), 1);
  });

  test('food counts are sorted by frequency', () {
    VisitDto visit(String? food) => VisitDto(
          id: '$food${DateTime.now().microsecondsSinceEpoch}',
          userId: 'u',
          userName: 'U',
          placeId: 'p',
          placeName: 'P',
          visitedAt: DateTime.now(),
          foodType: food,
        );
    final counts = foodCounts([visit('falafel'), visit('doener'), visit('doener'), visit(null)]);
    expect(counts.map((c) => (c.$1.id, c.$2)), [('doener', 2), ('falafel', 1)]);
  });

  testWidgets('overall rating follows the dimension average', (tester) async {
    final data = await tester.runAsync(_appData);
    await tester.pumpWidget(
      MultiProvider(
        providers: [ChangeNotifierProvider.value(value: data!), ChangeNotifierProvider.value(value: data.session)],
        child: const MaterialApp(home: Scaffold(body: ReviewSheet(place: _place))),
      ),
    );

    final empty = find.byIcon(Icons.restaurant_outlined);
    expect(empty, findsNWidgets(25)); // Soße, Fleisch, Salat, Brot, Gesamt
    await tester.tap(empty.at(3)); // Soße: 4
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.restaurant_outlined).at(2)); // Fleisch: 2
    await tester.pumpAndSettle();

    expect(find.text('Okay'), findsOneWidget); // (4 + 2) / 2 = 3
  });

  testWidgets('the left half of an icon rates a half step', (tester) async {
    final data = await tester.runAsync(_appData);
    await tester.pumpWidget(
      MultiProvider(
        providers: [ChangeNotifierProvider.value(value: data!), ChangeNotifierProvider.value(value: data.session)],
        child: const MaterialApp(home: Scaffold(body: ReviewSheet(place: _place))),
      ),
    );

    final empty = find.byIcon(Icons.restaurant_outlined);
    final sauce5 = tester.getRect(empty.at(4));
    final meat4 = tester.getCenter(empty.at(8));
    await tester.tapAt(Offset(sauce5.left + sauce5.width / 4, sauce5.center.dy)); // Soße: 4,5
    await tester.pumpAndSettle();
    await tester.tapAt(meat4); // Fleisch: 4
    await tester.pumpAndSettle();

    expect(find.byWidgetPredicate((w) => w is Align && w.widthFactor == 0.5), findsNWidgets(2), reason: 'Soße and Gesamt show a half icon');
    expect(find.text('Ausgezeichnet'), findsOneWidget); // (4,5 + 4) / 2 = 4,25, shown as 4,5
  });

  testWidgets('the close button leaves the review sheet', (tester) async {
    await _openSheet(tester, const AccountDto(id: 'u1', displayName: 'Robin'));
    expect(find.byType(ReviewSheet), findsOneWidget);
    await tester.tap(find.byTooltip('Schließen'));
    await tester.pumpAndSettle();
    expect(find.byType(ReviewSheet), findsNothing);
  });

  testWidgets('vegans rate vegan food, without meat or ayran', (tester) async {
    final data = await _openSheet(tester, const AccountDto(id: 'u1', displayName: 'Robin', diet: Diet.vegan));
    expect(find.text('🌱 Vegan'), findsOneWidget);
    expect(find.text('Fleisch'), findsNothing);
    expect(find.text('🥛 Selbstgemachter Ayran?'), findsNothing);

    await _rate(tester, 'Hummus', 5);
    await _rate(tester, 'Brot', 3);
    expect(find.text('Gut'), findsOneWidget, reason: '(5 + 3) / 2 = 4');
    await _tapInSheet(tester, find.text('Speichern'));

    final review = data.reviews['p1']!.dto;
    expect(review.ratings, {RatingItem.hummus: 5, RatingItem.brot: 3});
    expect(review.veganOptions, isTrue, reason: 'rating hummus says the place has vegan food');
    expect(review.rating, isNull, reason: 'no Döner score without sauce or meat');
  });

  testWidgets('dishes and homemade ayran get their own rating', (tester) async {
    final data = await _openSheet(tester, const AccountDto(id: 'u1', displayName: 'Robin'));
    expect(find.text('Seele'), findsOneWidget);
    expect(find.text('Ayran'), findsNothing, reason: 'only once it is homemade');

    await _rate(tester, 'Soße', 4);
    await tester.tap(find.text('Halloumi'));
    await tester.pumpAndSettle();
    await _rate(tester, 'Halloumi', 5);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Ja').last);
    await tester.pumpAndSettle();
    await _rate(tester, 'Ayran', 2);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Nein').first);
    await tester.pumpAndSettle();
    await _tapInSheet(tester, find.text('Speichern'));

    final review = data.reviews['p1']!.dto;
    expect(review.ratings, {RatingItem.sauce: 4, RatingItem.halloumi: 5, RatingItem.ayran: 2});
    expect(review.ayranHomemade, isTrue);
    expect(review.veganOptions, isFalse);
    expect(review.rating, 4, reason: 'halloumi and ayran stay out of the Döner score');
    expect(review.ingredients, isNull, reason: 'not asked without expert mode');
  });

  testWidgets('experts start from what others said "mit allem" means', (tester) async {
    final data = await _openSheet(
      tester,
      const AccountDto(id: 'u1', displayName: 'Robin', expertMode: true),
      summary: const PlaceSummaryDto(ingredients: [Ingredient.tomate, Ingredient.mais], meat: Meat.kalb, experts: 2),
    );
    await tester.scrollUntilVisible(find.widgetWithText(ChoiceChip, 'Kalb'), 200, scrollable: find.byType(Scrollable).last);
    expect(tester.widget<FilterChip>(find.widgetWithText(FilterChip, 'Mais')).selected, isTrue);
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Kalb')).selected, isTrue);

    await _tapInSheet(tester, find.widgetWithText(FilterChip, 'Granatapfelkerne'));
    await _tapInSheet(tester, find.widgetWithText(ChoiceChip, 'Selbst gesteckt'));
    await _tapInSheet(tester, find.text('Speichern'));

    final review = data.reviews['p1']!.dto;
    expect(review.ingredients, [Ingredient.tomate, Ingredient.mais, Ingredient.granatapfel]);
    expect(review.meat, Meat.kalb);
    expect(review.skewer, Skewer.homemade);
  });

  testWidgets('experts pick several sauces', (tester) async {
    final data = await _openSheet(tester, const AccountDto(id: 'u1', displayName: 'Robin', expertMode: true));
    // scrollUntilVisible stops at chips built below the viewport; at the end of the sheet the sauces are on screen.
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(find.text('Soßen · mehrere möglich'), findsOneWidget);

    for (final sauce in ['Knoblauch', 'Scharf', 'Tzatziki']) {
      await _tapInSheet(tester, find.widgetWithText(FilterChip, sauce));
    }
    await _tapInSheet(tester, find.text('Speichern'));

    expect(data.reviews['p1']!.dto.ingredients, [Ingredient.knoblauch, Ingredient.scharf, Ingredient.tzatziki]);
  });
}
