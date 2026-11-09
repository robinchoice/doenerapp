// Design studio: the real app with made-up data in a phone frame, the
// brand's colours and corners editable beside it. Local only, web only:
//   flutter run -d web-server -t lib/design_main.dart --web-port 8095
// See README, "Design-Werkstatt".
import 'dart:convert';

import 'package:doener_models/doener_models.dart';
import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:web/web.dart' as web;

import 'src/app.dart';
import 'src/core/app_data.dart';
import 'src/core/location.dart';
import 'src/core/push.dart';
import 'src/core/reminders.dart';
import 'src/core/session.dart';
import 'src/design/demo_server.dart';
import 'src/features/auth/login_screen.dart';
import 'src/features/onboarding/welcome_screen.dart';
import 'src/features/social/friends.dart';
import 'src/ui/widgets.dart';

const _storageKey = 'doener-design-studio';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('de');

  final db = await newDatabaseFactoryMemory().openDatabase('design.db');
  final session = Session(db, httpClient: MockClient(DemoServer().handle));
  await session.load();
  await session.verify(const VerifyRequest(email: 'demo@example.org', code: '000000'));
  final data = AppData(db, session);
  await data.load();
  await data.sync();
  await data.refreshMine();

  final saved = web.window.localStorage.getItem(_storageKey);
  final values = {..._toJson(const Brand()), if (saved != null) ...jsonDecode(saved) as Map<String, dynamic>};
  brand = _fromJson(values);

  final here = DemoServer.places.first;
  runApp(MultiProvider(
    providers: [
      Provider<Database>.value(value: db),
      Provider<Reminders?>.value(value: null),
      Provider<Push?>.value(value: null),
      ChangeNotifierProvider.value(value: session),
      ChangeNotifierProvider.value(value: data),
      ChangeNotifierProvider(create: (_) => LocationService()..position = LatLng(here.latitude, here.longitude)),
      ChangeNotifierProvider(create: (_) => Friends(session)..load()),
    ],
    child: DesignStudio(values: values),
  ));
}

// MARK: - Values

/// Editable colours: key, label, group.
const _lightColors = [('paper', 'Hintergrund'), ('card', 'Karten'), ('ink', 'Schrift'), ('muted', 'Schrift leise')];
const _darkColors = [('night', 'Hintergrund'), ('nightRaised', 'Karten'), ('nightText', 'Schrift'), ('nightMuted', 'Schrift leise')];
const _customColors = [('customFrom', 'Verlauf Anfang'), ('customTo', 'Verlauf Ende'), ('customLight', 'Akzent auf Hell'), ('customDark', 'Akzent auf Dunkel')];

Map<String, dynamic> _toJson(Brand b) => {
      'paper': b.paper.toARGB32(),
      'card': b.card.toARGB32(),
      'ink': b.ink.toARGB32(),
      'muted': b.muted.toARGB32(),
      'night': b.night.toARGB32(),
      'nightRaised': b.nightRaised.toARGB32(),
      'nightText': b.nightText.toARGB32(),
      'nightMuted': b.nightMuted.toARGB32(),
      'bandFrom': b.bandFrom,
      'bandTo': b.bandTo,
      'customOn': b.custom != null,
      'customFrom': (b.custom?.from ?? bandColor(b.bandFrom, glow)).toARGB32(),
      'customTo': (b.custom?.to ?? bandColor(b.bandTo, glow)).toARGB32(),
      'customLight': (b.custom?.light ?? bandColor((b.bandFrom + b.bandTo) / 2, deep)).toARGB32(),
      'customDark': (b.custom?.dark ?? bandColor((b.bandFrom + b.bandTo) / 2, glow)).toARGB32(),
      'cardRadius': b.cardRadius,
      'buttonRadius': b.buttonRadius,
    };

Brand _fromJson(Map<String, dynamic> j) {
  Color c(String key) => Color(j[key] as int);
  double d(String key) => (j[key] as num).toDouble();
  return Brand(
    paper: c('paper'),
    card: c('card'),
    ink: c('ink'),
    muted: c('muted'),
    night: c('night'),
    nightRaised: c('nightRaised'),
    nightText: c('nightText'),
    nightMuted: c('nightMuted'),
    bandFrom: d('bandFrom'),
    bandTo: d('bandTo'),
    custom: j['customOn'] == true ? (from: c('customFrom'), to: c('customTo'), light: c('customLight'), dark: c('customDark')) : null,
    cardRadius: d('cardRadius'),
    buttonRadius: d('buttonRadius'),
  );
}

String _hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// Dart source to hand to a developer, with the hex codes as comments.
String _export(Brand b) {
  String color(Color c) => 'Color(0x${c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()})';
  final custom = b.custom;
  return [
    '// Lieblingsdöner, Design-Werkstatt ${DateTime.now().toIso8601String().substring(0, 10)}',
    'const Brand(',
    for (final (key, label) in _lightColors) '  $key: ${color(Color(_toJson(b)[key] as int))}, // Hell: $label ${_hex(Color(_toJson(b)[key] as int))}',
    for (final (key, label) in _darkColors) '  $key: ${color(Color(_toJson(b)[key] as int))}, // Dunkel: $label ${_hex(Color(_toJson(b)[key] as int))}',
    if (custom == null) ...[
      '  bandFrom: ${b.bandFrom.toStringAsFixed(2)}, // Pleasance-Band',
      '  bandTo: ${b.bandTo.toStringAsFixed(2)},',
    ] else
      '  custom: (from: ${color(custom.from)}, to: ${color(custom.to)}, light: ${color(custom.light)}, dark: ${color(custom.dark)}),',
    '  cardRadius: ${b.cardRadius.round()},',
    '  buttonRadius: ${b.buttonRadius.round()},',
    ')',
  ].join('\n');
}

// MARK: - Studio

enum _View { app, welcome, login }

class DesignStudio extends StatefulWidget {
  final Map<String, dynamic> values;
  const DesignStudio({super.key, required this.values});

  @override
  State<DesignStudio> createState() => _DesignStudioState();
}

class _DesignStudioState extends State<DesignStudio> {
  late final Map<String, dynamic> _values = widget.values;
  final _previewKey = GlobalKey();
  var _view = _View.app;
  var _brightness = Brightness.light;
  String _selected = 'paper';

  void _set(String key, Object value) => _apply(() => _values[key] = value);

  void _reset() => _apply(() => _values
    ..clear()
    ..addAll(_toJson(const Brand())));

  /// Changes the values, keeps them for the next reload and redraws the phone.
  void _apply(void Function() change) {
    setState(() {
      change();
      brand = _fromJson(_values);
    });
    web.window.localStorage.setItem(_storageKey, jsonEncode(_values));
    // Widgets that read the brand directly instead of through the theme.
    void rebuild(Element e) {
      e.markNeedsBuild();
      e.visitChildren(rebuild);
    }

    (_previewKey.currentContext as Element?)?.visitChildren(rebuild);
  }

  void _select(String key) => setState(() {
        _selected = key;
        if (_darkColors.any((c) => c.$1 == key)) _brightness = Brightness.dark;
        if (_lightColors.any((c) => c.$1 == key)) _brightness = Brightness.light;
      });

  Future<void> _showExport(BuildContext context) => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Werte'),
          content: SingleChildScrollView(child: SelectableText(_export(brand), style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _export(brand)));
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Kopiert')));
              },
              child: const Text('Kopieren'),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Design-Werkstatt · Lieblingsdöner',
        debugShowCheckedModeBanner: false,
        // The studio keeps its own neutral look, so it doesn't change with the brand.
        theme: ThemeData(colorSchemeSeed: Colors.blueGrey, useMaterial3: true),
        home: Scaffold(
          backgroundColor: const Color(0xFFE4E4E7),
          body: Row(
            children: [
              Expanded(child: Padding(padding: const EdgeInsets.all(24), child: Center(child: _phone()))),
              SizedBox(width: 420, child: Material(elevation: 2, child: _panel())),
            ],
          ),
        ),
      );

  Widget _phone() {
    const size = Size(390, 844);
    final preview = KeyedSubtree(
      key: _previewKey,
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(
          size: size,
          padding: const EdgeInsets.only(top: 47, bottom: 34),
          viewPadding: const EdgeInsets.only(top: 47, bottom: 34),
          platformBrightness: _brightness,
        ),
        child: MaterialApp(
          key: ValueKey(_view),
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: _brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
          locale: const Locale('de'),
          supportedLocales: const [Locale('de')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: switch (_view) {
            _View.app => const HomeShell(),
            _View.welcome => WelcomeScreen(onDone: () {}),
            _View.login => const LoginScreen(),
          },
        ),
      ),
    );
    return FittedBox(
      child: Container(
        width: size.width + 24,
        height: size.height + 24,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: const Color(0xFF111111), borderRadius: BorderRadius.circular(56)),
        child: ClipRRect(borderRadius: BorderRadius.circular(44), child: preview),
      ),
    );
  }

  Widget _panel() {
    final custom = _values['customOn'] == true;
    final label = [..._lightColors, ..._darkColors, ..._customColors].firstWhere((c) => c.$1 == _selected).$2;
    final group = _lightColors.any((c) => c.$1 == _selected)
        ? 'Hell'
        : _darkColors.any((c) => c.$1 == _selected)
            ? 'Dunkel'
            : 'Akzent';
    return Builder(
      builder: (context) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        children: [
          Row(
            children: [
              Expanded(child: Text('Design-Werkstatt', style: Theme.of(context).textTheme.titleLarge)),
              IconButton(tooltip: 'Zurücksetzen', onPressed: _reset, icon: const Icon(Icons.restart_alt)),
              FilledButton.tonal(onPressed: () => _showExport(context), child: const Text('Werte')),
            ],
          ),
          const SizedBox(height: 16),
          SegmentedButton(
            segments: const [
              ButtonSegment(value: _View.app, label: Text('App')),
              ButtonSegment(value: _View.welcome, label: Text('Willkommen')),
              ButtonSegment(value: _View.login, label: Text('Anmelden')),
            ],
            selected: {_view},
            onSelectionChanged: (s) => setState(() => _view = s.first),
          ),
          const SizedBox(height: 8),
          SegmentedButton(
            segments: const [
              ButtonSegment(value: Brightness.light, label: Text('Hell'), icon: Icon(Icons.light_mode_outlined)),
              ButtonSegment(value: Brightness.dark, label: Text('Dunkel'), icon: Icon(Icons.dark_mode_outlined)),
            ],
            selected: {_brightness},
            onSelectionChanged: (s) => setState(() => _brightness = s.first),
          ),
          const SizedBox(height: 16),
          Text('$group: $label', style: Theme.of(context).textTheme.titleMedium),
          ColorPicker(
            key: ValueKey(_selected),
            color: Color(_values[_selected] as int),
            onColorChanged: (c) => _set(_selected, c.toARGB32()),
            pickersEnabled: const {ColorPickerType.wheel: true, ColorPickerType.primary: false, ColorPickerType.accent: false},
            enableShadesSelection: false,
            wheelDiameter: 240,
            wheelWidth: 20,
            padding: const EdgeInsets.symmetric(vertical: 8),
          ),
          // flex_color_picker's own code field needs material_ui's localizations, so a plain one.
          TextField(
            key: ValueKey('hex-$_selected-${_values[_selected]}'),
            controller: TextEditingController(text: _hex(Color(_values[_selected] as int))),
            decoration: const InputDecoration(labelText: 'Farbcode', isDense: true, border: OutlineInputBorder()),
            style: const TextStyle(fontFamily: 'monospace'),
            onSubmitted: (text) {
              final hex = text.replaceAll('#', '').trim();
              final value = int.tryParse(hex, radix: 16);
              if (hex.length == 6 && value != null) _set(_selected, 0xFF000000 | value);
            },
          ),
          _heading(context, 'Hell'),
          for (final (key, label) in _lightColors) _colorTile(key, label),
          _heading(context, 'Dunkel'),
          for (final (key, label) in _darkColors) _colorTile(key, label),
          _heading(context, 'Akzent und Verlauf'),
          SegmentedButton(
            segments: const [
              ButtonSegment(value: false, label: Text('Pleasance-Band')),
              ButtonSegment(value: true, label: Text('Eigene Farben')),
            ],
            selected: {custom},
            onSelectionChanged: (s) {
              // Own colours start from the band as it is now.
              _apply(() => _values
                ..addAll(s.first ? _toJson(_fromJson({..._values, 'customOn': false})) : const {})
                ..['customOn'] = s.first);
              if (!s.first && _customColors.any((c) => c.$1 == _selected)) _select('paper');
            },
          ),
          const SizedBox(height: 8),
          if (custom)
            for (final (key, label) in _customColors) _colorTile(key, label)
          else
            _bandEditor(),
          _heading(context, 'Ecken'),
          _slider('Karten', 'cardRadius', 28),
          _slider('Knöpfe', 'buttonRadius', 24),
        ],
      ),
    );
  }

  Widget _heading(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 4),
        child: Text(text, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.outline)),
      );

  Widget _colorTile(String key, String label) {
    final color = Color(_values[key] as int);
    return ListTile(
      dense: true,
      selected: key == _selected,
      selectedTileColor: Colors.blueGrey.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      leading: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: Border.all(color: Colors.black26)),
      ),
      title: Text(label),
      trailing: Text(_hex(color), style: const TextStyle(fontFamily: 'monospace')),
      onTap: () => _select(key),
    );
  }

  /// Which part of the family band the app takes its colours from.
  Widget _bandEditor() {
    final from = (_values['bandFrom'] as num).toDouble();
    final to = (_values['bandTo'] as num).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Container(
            height: 14,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(7), gradient: const LinearGradient(colors: glow)),
          ),
        ),
        RangeSlider(
          min: 1,
          max: 7,
          values: RangeValues(from, to),
          onChanged: (v) {
            _set('bandFrom', v.start);
            _set('bandTo', v.end);
          },
        ),
        Text('Ausschnitt ${from.toStringAsFixed(2)} bis ${to.toStringAsFixed(2)}', textAlign: TextAlign.center),
      ],
    );
  }

  Widget _slider(String label, String key, double max) {
    final value = (_values[key] as num).toDouble();
    return Row(
      children: [
        SizedBox(width: 60, child: Text(label)),
        Expanded(child: Slider(min: 0, max: max, divisions: max.round(), value: value, onChanged: (v) => _set(key, v))),
        SizedBox(width: 40, child: Text('${value.round()} px', textAlign: TextAlign.end)),
      ],
    );
  }
}
