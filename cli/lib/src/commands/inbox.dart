import 'package:doener_models/doener_models.dart';

import '../client.dart';
import '../command.dart';

/// What happened in the last 7 days, like the bell on Start. New entries are
/// marked with •; `--seen` marks everything as seen, on all devices.
final inbox = Command(
  help: [
    ('inbox [--seen]', 'Was in den letzten 7 Tagen passiert ist, wie die Glocke in der App; --seen markiert alles als gesehen'),
  ],
  options: (parser) => parser.addFlag('seen', negatable: false),
  run: (ctx) async {
    requireLogin(ctx);
    final bell = parse(await ctx.api.get('/me/inbox'), InboxDto.fromJson);
    if (ctx.args.flag('seen')) await ctx.api.post('/me/inbox/seen');
    bool isNew(InboxItemDto item) => bell.seenAt == null || item.timestamp.isAfter(bell.seenAt!);
    return (
      data: bell.toJson(),
      text: [
        if (bell.items.isEmpty) 'Nichts Neues in den letzten 7 Tagen.',
        for (final item in bell.items)
          [
            '${isNew(item) ? '•' : ' '} ${day(item.timestamp)} ${item.title}',
            ?item.body,
          ].join(' · '),
      ].join('\n'),
    );
  },
);
