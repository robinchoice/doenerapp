import 'dart:convert';
import 'dart:typed_data';

import 'package:doener_models/discover.dart';
import 'package:test/test.dart';

import 'oprf_vectors.dart';

String coord(BigInt value) => value.toRadixString(16).padLeft(64, '0');

void main() {
  final hashDst = utf8.encode('QUUX-V01-CS02-with-P256_XMD:SHA-256_SSWU_RO_');

  test('expand_message_xmd matches RFC 9380 K.1', () {
    final dst = utf8.encode('QUUX-V01-CS02-with-expander-SHA256-128');
    for (final vector in expandVectors) {
      expect(toHex(expandMessageXmd(utf8.encode(vector.msg), dst, vector.length)), vector.uniform,
          reason: '${vector.msg.length} ${vector.length}');
    }
  });

  test('hash_to_curve matches RFC 9380 J.1.1 step by step', () {
    for (final v in hashToCurveVectors) {
      final msg = utf8.encode(v.msg);
      final u = hashToField(msg, hashDst);
      expect([coord(u[0]), coord(u[1])], [v.u0, v.u1]);
      final q0 = mapToCurveSswu(u[0]);
      final q1 = mapToCurveSswu(u[1]);
      expect([coord(q0.$1), coord(q0.$2)], [v.q0x, v.q0y]);
      expect([coord(q1.$1), coord(q1.$2)], [v.q1x, v.q1y]);
      final p = hashToCurve(msg, hashDst);
      expect(coord(p.x!.toBigInteger()!), v.px);
      expect(coord(p.y!.toBigInteger()!), v.py);
    }
  });

  group('RFC 9497 A.3.1 OPRF mode P256-SHA256', () {
    const key = '159749d750713afe245d2d39ccfaae8381c53ce92d098a9375ee70739c7ac0bf';
    final blind = BigInt.parse('3338fa65ec36e0290022b48eb562889d89dbfa691d1cde91517fa222ed7ad364', radix: 16);
    const vectors = [
      (
        input: '00',
        blinded: '03723a1e5c09b8b9c18d1dcbca29e8007e95f14f4732d9346d490ffc195110368d',
        evaluated: '030de02ffec47a1fd53efcdd1c6faf5bdc270912b8749e783c7ca75bb412958832',
        output: 'a0b34de5fa4c5b6da07e72af73cc507cceeb48981b97b7285fc375345fe495dd',
      ),
      (
        input: '5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a',
        blinded: '03cc1df781f1c2240a64d1c297b3f3d16262ef5d4cf102734882675c26231b0838',
        evaluated: '03a0395fe3828f2476ffcd1f4fe540e5a8489322d398be3c4e5a869db7fcb7c52c',
        output: 'c748ca6dd327f0ce85f4ae3a8cd6d4d5390bbb804c9e12dcf94f853fece3dcce',
      ),
    ];

    test('client and server match byte for byte', () {
      final client = OprfClient();
      final server = OprfServer.fromHex(key);
      for (final v in vectors) {
        final blinded = client.blind(hexBytes(v.input), blind: blind);
        expect(toHex(blinded.element), v.blinded);
        expect(toHex(server.blindEvaluate(blinded.element)), v.evaluated);
        expect(toHex(client.finalize(blinded, hexBytes(v.evaluated))), v.output);
        expect(toHex(server.evaluate(hexBytes(v.input))), v.output);
      }
    });

    test('regression: an element that is not a valid point is refused', () {
      final client = OprfClient();
      final server = OprfServer.fromHex(key);
      final blinded = client.blind(hexBytes('00'), blind: blind);
      final good = hexBytes(vectors[0].evaluated);
      final offCurve = Uint8List.fromList(good)..[32] ^= 1;
      for (final bad in [offCurve, good.sublist(1), Uint8List.fromList([4, ...good.sublist(1)]), Uint8List(33)]) {
        expect(() => client.finalize(blinded, bad), throwsFormatException, reason: toHex(bad));
        expect(() => server.blindEvaluate(bad), throwsFormatException, reason: toHex(bad));
      }
    });
  });

  test('a blinded number unblinds into its phone key', () {
    final server = OprfServer.fromHex('11' * 32);
    final client = OprfClient();
    const number = '+4915123456789';
    final a = client.blind(utf8.encode(number));
    final b = client.blind(utf8.encode(number));
    expect(toHex(a.element), isNot(toHex(b.element)));
    expect(toHex(client.finalize(a, server.blindEvaluate(a.element))), phoneKey(server, number));
    expect(toHex(client.finalize(b, server.blindEvaluate(b.element))), phoneKey(server, number));
    expect(phoneKey(server, '+4915123456780'), isNot(phoneKey(server, number)));
  });

  test('regression: OPRF_KEY must be a valid scalar', () {
    for (final bad in ['', '00' * 32, 'ff' * 32, '11' * 31, 'zz' * 32]) {
      expect(() => OprfServer.fromHex(bad), throwsFormatException, reason: bad);
    }
  });

  test('numbers become E.164, numbers without a country code count as from the region', () {
    expect(toE164('0151 23456789', IsoCode.DE), '+4915123456789');
    expect(toE164('+49 (151) 234-56789', IsoCode.AT), '+4915123456789');
    expect(toE164('0664 1234567', IsoCode.AT), '+436641234567');
    expect(toE164('112', IsoCode.DE), isNull);
    expect(toE164('kein Telefon', IsoCode.DE), isNull);
    expect(e164.hasMatch('+4915123456789'), isTrue);
    expect(maskNumber('+4915123456789'), '+49 151 •••• 789');
  });

  test('tag and box key differ and depend on the output', () {
    final output = List.filled(32, 7);
    expect(discoverTag(output), hasLength(32));
    expect(discoverTag(output), isNot(discoverTag(List.filled(32, 8))));
    expect(toHex(discoverBoxKey(output)), isNot(startsWith(discoverTag(output))));
  });
}
