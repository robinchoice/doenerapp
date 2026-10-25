import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/session.dart';
import '../../ui/widgets.dart';

const _days = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];

String _two(int n) => '$n'.padLeft(2, '0');

/// `22:30`, or `22` on the full hour with [short].
String _clock(int minutes, {bool short = false}) =>
    short && minutes % 60 == 0 ? '${minutes ~/ 60}' : '${minutes ~/ 60}:${_two(minutes % 60)}';

/// "Jeden Tag 22–8 Uhr", for the row in the settings.
String quietHoursText(AccountDto user) {
  if (!user.quietHours || user.quietDays == 0) return 'Aus';
  final days = switch (user.quietDays) {
    AccountDto.allDays => 'Jeden Tag',
    31 => 'Mo–Fr',
    96 => 'Sa, So',
    final bits => [for (var i = 0; i < 7; i++) if (bits & (1 << i) != 0) _days[i]].join(', '),
  };
  final short = user.quietStart % 60 == 0 && user.quietEnd % 60 == 0;
  return '$days ${_clock(user.quietStart, short: short)}–${_clock(user.quietEnd, short: short)} Uhr';
}

/// "bis morgen, 8:00 Uhr" for a pause.
String pausedText(DateTime until) {
  final local = until.toLocal();
  if (local.year >= pauseForever.year) return 'bis du fortsetzt';
  final time = '${local.hour}:${_two(local.minute)} Uhr';
  final today = DateUtils.dateOnly(DateTime.now());
  final day = DateUtils.dateOnly(local);
  if (day == today) return 'bis $time';
  if (day == today.add(const Duration(days: 1))) return 'bis morgen, $time';
  return 'bis ${local.day}.${local.month}., $time';
}

/// "Bis ich fortsetze" pauses until then.
final pauseForever = DateTime.utc(9999);

/// Asks how long to pause pushes; null when cancelled.
Future<DateTime?> askPause(BuildContext context) {
  final now = DateTime.now();
  final options = [
    ('Für 1 Stunde', now.add(const Duration(hours: 1))),
    ('Bis morgen, 8 Uhr', DateTime(now.year, now.month, now.day + 1, 8)),
    ('Für 1 Woche', now.add(const Duration(days: 7))),
    ('Bis ich fortsetze', pauseForever),
  ];
  var choice = options[1].$2;
  return showDialog<DateTime>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Pushes pausieren'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RadioGroup<DateTime>(
              groupValue: choice,
              onChanged: (value) => setState(() => choice = value!),
              child: Column(
                children: [
                  for (final (label, until) in options)
                    RadioListTile<DateTime>(value: until, title: Text(label), contentPadding: EdgeInsets.zero),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text('Ruhezeiten und Schalter bleiben, wie sie sind.', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
          TextButton(onPressed: () => Navigator.pop(context, choice), child: const Text('Pausieren')),
        ],
      ),
    ),
  );
}

/// One window with weekdays, in the phone's time zone. A window over
/// midnight belongs to the day it starts on.
class QuietHoursScreen extends StatelessWidget {
  const QuietHoursScreen({super.key});

  Future<void> _update(
    BuildContext context, {
    bool? quietHours,
    int? quietDays,
    int? quietStart,
    int? quietEnd,
  }) async {
    try {
      await context
          .read<Session>()
          .updateSettings(quietHours: quietHours, quietDays: quietDays, quietStart: quietStart, quietEnd: quietEnd);
    } catch (e) {
      if (context.mounted) showMessage(context, 'Nicht gespeichert: $e');
    }
  }

  Future<void> _pickTime(BuildContext context, int minutes, {required bool start}) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60),
      helpText: start ? 'Beginn der Ruhezeit' : 'Ende der Ruhezeit',
    );
    if (picked == null || !context.mounted) return;
    final value = picked.hour * 60 + picked.minute;
    await _update(context, quietStart: start ? value : null, quietEnd: start ? null : value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = context.watch<Session>().user!;
    Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(text, style: theme.textTheme.titleSmall?.copyWith(color: context.accent)),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Ruhezeiten')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Ruhezeiten'),
            subtitle: const Text('In dieser Zeit klingelt nichts.'),
            value: user.quietHours,
            onChanged: (value) => _update(context, quietHours: value),
          ),
          IgnorePointer(
            ignoring: !user.quietHours,
            child: Opacity(
              opacity: user.quietHours ? 1 : 0.4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  header('An diesen Tagen'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (var i = 0; i < 7; i++)
                          FilterChip(
                            label: Text(_days[i]),
                            selected: user.quietDays & (1 << i) != 0,
                            showCheckmark: false,
                            onSelected: (_) => _update(context, quietDays: user.quietDays ^ (1 << i)),
                          ),
                      ],
                    ),
                  ),
                  header('Uhrzeit'),
                  ListTile(
                    title: const Text('Beginn'),
                    trailing: Text('${_clock(user.quietStart)} Uhr', style: theme.textTheme.titleMedium),
                    onTap: () => _pickTime(context, user.quietStart, start: true),
                  ),
                  ListTile(
                    title: const Text('Ende'),
                    trailing: Text('${_clock(user.quietEnd)} Uhr', style: theme.textTheme.titleMedium),
                    onTap: () => _pickTime(context, user.quietEnd, start: false),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Was in der Ruhezeit passiert: Ein neuer Laden kommt danach. Check-ins von Freunden fallen weg, die sind bis dahin '
              'vorbei. Beides steht in den Mitteilungen auf Start. Es gilt die Uhrzeit dort, wo dein Handy gerade ist.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
        ],
      ),
    );
  }
}
