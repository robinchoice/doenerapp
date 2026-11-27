/// Finding people from the address book by phone number without the server
/// seeing a number: the OPRF of RFC 9497 (mode OPRF, suite P256-SHA256),
/// hashing to the curve per RFC 9380 (P256_XMD:SHA-256_SSWU_RO_).
///
/// An account confirms its own number by SMS; the server stores only the OPRF
/// output of it, its "phone key". The app blinds the numbers of its address
/// book, the server applies its secret key without seeing them, the app
/// unblinds the answers into the same outputs. The directory lists one tag and
/// one sealed box per discoverable account, both derived from the output, so
/// only who knows a number finds and opens its entry. Not constant time: the
/// inputs are the phone's own address book.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:phone_numbers_parser/phone_numbers_parser.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart';

export 'package:phone_numbers_parser/phone_numbers_parser.dart' show IsoCode;

/// Numbers per evaluate request, the most the API takes.
const evaluateChunk = 200;

/// Numbers a confirmed phone number may check per day, against trying out numbers.
const maxDiscoverNumbersPerDay = 1000;

/// Length of a serialized element: a compressed SEC1 point.
const elementLength = 33;

final _curve = ECCurve_secp256r1();
final _n = _curve.n;
final _a = BigInt.from(-3);
final _b = _curve.curve.b!.toBigInteger()!;
final _z = BigInt.from(-10);

// secp256r1 field prime, 2^256 - 2^224 + 2^192 + 2^96 - 1
final _fieldPrime = (BigInt.one << 256) - (BigInt.one << 224) + (BigInt.one << 192) + (BigInt.one << 96) - BigInt.one;

final _contextString = [...utf8.encode('OPRFV1-'), 0, ...utf8.encode('-P256-SHA256')];

/// DST of the hash to the curve: "HashToGroup-" || contextString
final hashToGroupDst = Uint8List.fromList([...utf8.encode('HashToGroup-'), ..._contextString]);

Uint8List sha256(List<int> data) => SHA256Digest().process(Uint8List.fromList(data));

List<int> _i2osp(int value, int length) => [for (var i = length - 1; i >= 0; i--) (value >> (8 * i)) & 0xff];

BigInt _os2ip(List<int> bytes) => bytes.fold(BigInt.zero, (sum, byte) => (sum << 8) | BigInt.from(byte));

Uint8List _i2ospBig(BigInt value, int length) {
  final out = Uint8List(length);
  var rest = value;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (rest & BigInt.from(0xff)).toInt();
    rest >>= 8;
  }
  return out;
}

/// RFC 9380 section 5.3.1 with SHA-256
Uint8List expandMessageXmd(List<int> msg, List<int> dst, int length) {
  final ell = (length + 31) ~/ 32;
  if (ell > 255 || length > 65535 || dst.length > 255) throw ArgumentError('expand_message_xmd input too large');
  final dstPrime = [...dst, ..._i2osp(dst.length, 1)];
  final b0 = sha256([...List.filled(64, 0), ...msg, ..._i2osp(length, 2), 0, ...dstPrime]);
  var b = sha256([...b0, 1, ...dstPrime]);
  final out = <int>[...b];
  for (var i = 2; i <= ell; i++) {
    b = sha256([for (var j = 0; j < 32; j++) b0[j] ^ b[j], i, ...dstPrime]);
    out.addAll(b);
  }
  return Uint8List.fromList(out.sublist(0, length));
}

/// RFC 9380 section 5.2 for P-256: two field elements, 48 bytes each
List<BigInt> hashToField(List<int> msg, List<int> dst) {
  final bytes = expandMessageXmd(msg, dst, 96);
  return [for (var i = 0; i < 2; i++) _os2ip(bytes.sublist(48 * i, 48 * (i + 1))) % _fieldPrime];
}

BigInt _mod(BigInt value) => value % _fieldPrime;
BigInt _inv0(BigInt value) => value == BigInt.zero ? BigInt.zero : value.modInverse(_fieldPrime);
BigInt _pow(BigInt base, BigInt exponent) => base.modPow(exponent, _fieldPrime);

// p = 3 mod 4
BigInt _sqrt(BigInt value) => _pow(value, (_fieldPrime + BigInt.one) >> 2);

bool _isSquare(BigInt value) => _pow(value, (_fieldPrime - BigInt.one) >> 1) != _fieldPrime - BigInt.one;

BigInt _curveRhs(BigInt x) => _mod(x * x * x + _a * x + _b);

/// RFC 9380 section 6.6.2, simplified SWU for A != 0, B != 0
(BigInt, BigInt) mapToCurveSswu(BigInt u) {
  final z = _mod(_z);
  final a = _mod(_a);
  final u2 = _mod(u * u);
  final tv1 = _inv0(_mod(z * z * u2 * u2 + z * u2));
  var x1 = _mod(_mod(-_b) * _inv0(a) * (BigInt.one + tv1));
  if (tv1 == BigInt.zero) x1 = _mod(_b * _inv0(_mod(z * a)));
  final gx1 = _curveRhs(x1);
  final x2 = _mod(z * u2 * x1);
  final gx2 = _curveRhs(x2);
  final (x, root) = _isSquare(gx1) ? (x1, _sqrt(gx1)) : (x2, _sqrt(gx2));
  final y = root.isOdd == u.isOdd ? root : _mod(-root);
  return (x, y);
}

ECPoint _point(BigInt x, BigInt y) => _curve.curve.createPoint(x, y);

/// RFC 9380 hash_to_curve, P256_XMD:SHA-256_SSWU_RO_
ECPoint hashToCurve(List<int> msg, List<int> dst) {
  final [u0, u1] = hashToField(msg, dst);
  final (x0, y0) = mapToCurveSswu(u0);
  final (x1, y1) = mapToCurveSswu(u1);
  // The cofactor of P-256 is 1
  return (_point(x0, y0) + _point(x1, y1))!;
}

/// SerializeElement: compressed SEC1
Uint8List serializeElement(ECPoint point) {
  final x = point.x!.toBigInteger()!;
  final y = point.y!.toBigInteger()!;
  return Uint8List.fromList([y.isOdd ? 3 : 2, ..._i2ospBig(x, 32)]);
}

/// DeserializeElement: a compressed point on the curve, not the identity.
/// Throws [FormatException] for anything else.
ECPoint deserializeElement(List<int> bytes) {
  if (bytes.length != elementLength || (bytes[0] != 2 && bytes[0] != 3)) {
    throw const FormatException('Invalid OPRF element');
  }
  final x = _os2ip(bytes.sublist(1));
  if (x >= _fieldPrime) throw const FormatException('Invalid OPRF element');
  final rhs = _curveRhs(x);
  var y = _sqrt(rhs);
  if (_mod(y * y) != rhs) throw const FormatException('Invalid OPRF element');
  if (y.isOdd != (bytes[0] == 3)) y = _mod(-y);
  return _point(x, y);
}

Uint8List _finalize(List<int> input, ECPoint unblinded) => sha256([
      ..._i2osp(input.length, 2),
      ...input,
      ..._i2osp(elementLength, 2),
      ...serializeElement(unblinded),
      ...utf8.encode('Finalize'),
    ]);

/// What [OprfClient.blind] hands back: [element] goes to the server, [input]
/// and the secret [blind] stay here for [OprfClient.finalize].
class Blinded {
  final Uint8List input;
  final BigInt blind;
  final Uint8List element;
  const Blinded(this.input, this.blind, this.element);
}

class OprfClient {
  final Random _random;
  OprfClient({Random? random}) : _random = random ?? Random.secure();

  BigInt _randomScalar() {
    while (true) {
      final scalar = _os2ip([for (var i = 0; i < 32; i++) _random.nextInt(256)]);
      if (scalar > BigInt.zero && scalar < _n) return scalar;
    }
  }

  /// A fixed [blind] is for the RFC test vectors only.
  Blinded blind(List<int> input, {BigInt? blind}) {
    final r = blind ?? _randomScalar();
    final point = hashToCurve(input, hashToGroupDst);
    if (point.isInfinity) throw const FormatException('Input maps to identity');
    final blinded = (point * r)!;
    if (blinded.isInfinity) throw const FormatException('Blind is invalid');
    return Blinded(Uint8List.fromList(input), r, serializeElement(blinded));
  }

  /// The output (32 bytes) for the server's answer to [blinded]. Throws
  /// [FormatException] if the answer is not a valid point.
  Uint8List finalize(Blinded blinded, List<int> evaluated) {
    final element = deserializeElement(evaluated);
    final unblinded = (element * blinded.blind.modInverse(_n))!;
    if (unblinded.isInfinity) throw const FormatException('Invalid OPRF element');
    return _finalize(blinded.input, unblinded);
  }
}

/// The server's side with its secret key (`OPRF_KEY`, 32 bytes hex).
class OprfServer {
  final BigInt _key;

  OprfServer._(this._key);

  /// Throws [FormatException] unless [hex] is a valid P-256 scalar.
  factory OprfServer.fromHex(String hex) {
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hex)) throw const FormatException('OPRF_KEY must be 64 hex digits');
    final key = BigInt.parse(hex, radix: 16);
    if (key == BigInt.zero || key >= _n) throw const FormatException('OPRF_KEY is no valid scalar');
    return OprfServer._(key);
  }

  /// The output for [input] without blinding: the phone key of a confirmed number.
  Uint8List evaluate(List<int> input) => _finalize(input, (hashToCurve(input, hashToGroupDst) * _key)!);

  /// Applies the key to a blinded element. Throws [FormatException] on an invalid one.
  Uint8List blindEvaluate(List<int> element) => serializeElement((deserializeElement(element) * _key)!);
}

/// The phone key of [phone] in E.164, hex.
String phoneKey(OprfServer server, String phone) => toHex(server.evaluate(utf8.encode(phone)));

/// The tag a directory entry carries for the OPRF output [output] of a number.
String discoverTag(List<int> output) => toHex(sha256([...utf8.encode('Doener discover tag'), ...output]).sublist(0, 16));

/// The AES-256-GCM key of the box that belongs to [output].
Uint8List discoverBoxKey(List<int> output) => sha256([...utf8.encode('Doener discover box'), ...output]);

/// The number in E.164, null if it is no valid phone number. Numbers without
/// a country code count as from [region].
String? toE164(String raw, IsoCode region) {
  try {
    final number = PhoneNumber.parse(raw.trim(), callerCountry: region);
    return number.isValid() ? number.international : null;
  } on PhoneNumberException {
    return null;
  }
}

/// E.164 as the server takes it.
final e164 = RegExp(r'^\+[1-9]\d{6,14}$');

/// Country code and the first and last digits, the middle hidden: +49 151 •••• 789
String maskNumber(String e164) {
  final number = PhoneNumber.parse(e164);
  final nsn = number.nsn;
  if (nsn.length < 7) return '+${number.countryCode} •••• ${nsn.substring(nsn.length - 2)}';
  return '+${number.countryCode} ${nsn.substring(0, 3)} •••• ${nsn.substring(nsn.length - 3)}';
}

String toHex(List<int> bytes) => [for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0')].join();

Uint8List hexBytes(String hex) =>
    Uint8List.fromList([for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);
