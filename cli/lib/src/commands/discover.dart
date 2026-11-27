import 'dart:convert';
import 'dart:typed_data';

import 'package:doener_models/discover.dart';
import 'package:doener_models/doener_models.dart';
import 'package:pointycastle/export.dart' show AEADParameters, AESEngine, GCMBlockCipher, InvalidCipherTextException, KeyParameter;

import '../client.dart';
import '../command.dart';

/// The profile in a directory box (AES-256-GCM, base64 of nonce || ciphertext
/// || tag), null if [output] does not open it. The apps do this natively.
Map<String, dynamic>? _open(List<int> output, String box) {
  try {
    final bytes = base64Decode(box);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(discoverBoxKey(output)), 128, bytes.sublist(0, 12), Uint8List(0)));
    final json = jsonDecode(utf8.decode(cipher.process(bytes.sublist(12))));
    return json is Map<String, dynamic> ? json : null;
  } on InvalidCipherTextException {
    return null;
  } on FormatException {
    return null;
  } on RangeError {
    return null;
  }
}

String _e164(String raw) =>
    toE164(raw, IsoCode.DE) ?? (throw Failure('$raw ist keine gültige Handynummer.', Exit.usage));

final discover = <String, Command>{
  'phone': Command(
    help: [
      ('phone --number <nummer>', 'Eigene Handynummer per SMS-Code bestätigen, dann findet man dich über sie'),
      ('phone --remove', 'Nicht mehr über die Nummer auffindbar'),
    ],
    options: (parser) => parser
      ..addOption('number')
      ..addFlag('remove', negatable: false),
    run: (ctx) async {
      requireLogin(ctx);
      if (ctx.args.flag('remove')) {
        final account = parse(await ctx.api.delete('/me/phone'), AccountDto.fromJson);
        return (data: {'discoverable': account.discoverable}, text: 'Nicht mehr über deine Nummer auffindbar.');
      }
      final raw = ctx.args.option('number') ?? (throw const Failure('--number <nummer> fehlt.', Exit.usage));
      final phone = _e164(raw);
      await ctx.api.post('/me/phone', {'phone': phone});
      ctx.io.err('Der Code ist per SMS an ${maskNumber(phone)} unterwegs.');
      final code = (await ctx.io.ask('Code aus der SMS: ')).trim();
      final account = parse(await ctx.api.post('/me/phone/verify', {'phone': phone, 'code': code}), AccountDto.fromJson);
      return (data: {'discoverable': account.discoverable}, text: 'Über deine Nummer auffindbar.');
    },
  ),
  // The numbers leave the machine only blinded, see package:doener_models/discover.dart.
  'discover': Command(
    help: [('discover --number <nummer> …', 'Wer mit diesen Nummern dabei ist, ohne dass der Server sie sieht')],
    options: (parser) => parser..addMultiOption('number', splitCommas: false),
    run: (ctx) async {
      requireLogin(ctx);
      final numbers = {for (final raw in ctx.args.multiOption('number')) _e164(raw)}.toList();
      if (numbers.isEmpty) throw const Failure('--number <nummer> fehlt.', Exit.usage);
      final client = OprfClient();
      final outputs = <String, Uint8List>{};
      for (var start = 0; start < numbers.length; start += evaluateChunk) {
        final chunk = numbers.skip(start).take(evaluateChunk).toList();
        final blinded = [for (final number in chunk) client.blind(utf8.encode(number))];
        final answer = await ctx.api.post('/discover/evaluate', {'blinded': [for (final b in blinded) base64Encode(b.element)]});
        final evaluated = switch (answer) {
          {'evaluated': final List<Object?> list} when list.length == chunk.length => list,
          _ => throw const Failure('Unerwartete Antwort der API.', Exit.error),
        };
        for (var i = 0; i < chunk.length; i++) {
          try {
            outputs[chunk[i]] = client.finalize(blinded[i], base64Decode(evaluated[i] as String));
          } on Object {
            throw const Failure('Unerwartete Antwort der API.', Exit.error);
          }
        }
      }
      final boxes = switch (await ctx.api.get('/discover/directory')) {
        {'entries': final List<Object?> entries} => {
            for (final entry in entries)
              if (entry case {'tag': final String tag, 'box': final String box}) tag: box,
          },
        _ => throw const Failure('Unerwartete Antwort der API.', Exit.error),
      };
      final matches = [
        for (final MapEntry(key: number, value: output) in outputs.entries)
          if (boxes[discoverTag(output)] case final box?)
            if (_open(output, box) case {'id': final String id, 'name': final String name}) {'number': number, 'id': id, 'name': name},
      ];
      return (
        data: {'matches': matches},
        text: matches.isEmpty
            ? 'Niemand mit diesen Nummern ist auffindbar.'
            : [for (final m in matches) '${m['number']} · ${m['name']} · ${m['id']}'].join('\n'),
      );
    },
  ),
};
