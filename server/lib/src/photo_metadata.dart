import 'dart:typed_data';

import 'package:postgres/postgres.dart';

/// Strips the photos stored before uploads were stripped, one at a time.
/// Runs once: afterwards it removes its own schedule.
Future<void> stripStoredPhotos(Session db) async {
  final ids = await db.execute('SELECT id FROM review_photos ORDER BY created_at');
  for (final [id as String] in ids) {
    final rows = await db.execute(Sql.named('SELECT content_type, data FROM review_photos WHERE id = @id:uuid'), parameters: {'id': id});
    if (rows.isEmpty) continue;
    final [type as String, data as List<int>] = rows.single;
    final Uint8List stripped;
    try {
      stripped = stripPhotoMetadata(data, type);
    } on FormatException {
      print('Photo $id is broken, deleted');
      await db.execute(Sql.named('DELETE FROM review_photos WHERE id = @id:uuid'), parameters: {'id': id});
      continue;
    }
    if (stripped.length == data.length) continue;
    await db.execute(Sql.named('UPDATE review_photos SET data = @data:bytea WHERE id = @id:uuid'), parameters: {'id': id, 'data': stripped});
  }
  await db.execute("DELETE FROM schedules WHERE name = 'photo_metadata'");
}

/// [bytes] of a review photo without its metadata: no location, time, camera
/// or embedded thumbnails, which everyone who sees the photo could read.
/// JPEGs keep their orientation, so phones' photos don't turn sideways.
/// Throws a [FormatException] if the file is broken.
Uint8List stripPhotoMetadata(List<int> bytes, String type) => switch (type) {
      'image/jpeg' => _jpeg(bytes),
      'image/png' => _png(bytes),
      'image/webp' => _webp(bytes),
      _ => throw FormatException('Unknown photo type $type'),
    };

Uint8List _jpeg(List<int> b) {
  final out = BytesBuilder(copy: false)..add(const [0xff, 0xd8]);
  var i = 2;
  int u16(int at) => b[at] << 8 | b[at + 1];
  while (true) {
    if (i + 1 >= b.length || b[i] != 0xff) throw const FormatException('Broken JPEG');
    final marker = b[i + 1];
    if (marker == 0xff) {
      i++; // fill byte
      continue;
    }
    if (marker == 0xd9) break; // end of image; whatever follows (more images, videos) goes
    if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      out.add([0xff, marker]);
      i += 2;
      continue;
    }
    if (i + 3 >= b.length) throw const FormatException('Broken JPEG');
    final length = u16(i + 2);
    final end = i + 2 + length;
    if (length < 2 || end > b.length) throw const FormatException('Broken JPEG');
    final payload = b.sublist(i + 4, end);
    if (marker == 0xe1) {
      final orientation = _startsWith(payload, 'Exif\x00\x00') ? _orientation(payload.sublist(6)) : null;
      if (orientation != null && orientation != 1) out.add(_orientationExif(orientation));
    } else if (_keepSegment(marker, payload)) {
      out.add(b.sublist(i, end));
    }
    i = end;
    if (marker == 0xda) {
      // Entropy-coded scan data runs to the next marker that isn't a stuffed
      // 0xff or a restart marker.
      var j = i;
      while (j + 1 < b.length && !(b[j] == 0xff && b[j + 1] != 0 && (b[j + 1] < 0xd0 || b[j + 1] > 0xd7))) {
        j++;
      }
      if (j + 1 >= b.length) throw const FormatException('Broken JPEG');
      out.add(b.sublist(i, j));
      i = j;
    }
  }
  out.add(const [0xff, 0xd9]);
  return out.takeBytes();
}

/// Everything but application segments and comments is image data. Of the
/// application segments only JFIF, the colour profile and Adobe's colour
/// transform matter for the picture.
bool _keepSegment(int marker, List<int> payload) => switch (marker) {
      0xfe => false,
      0xe0 => _startsWith(payload, 'JFIF\x00'),
      0xe2 => _startsWith(payload, 'ICC_PROFILE\x00'),
      0xee => _startsWith(payload, 'Adobe'),
      >= 0xe0 && <= 0xef => false,
      _ => true,
    };

/// The orientation tag (0x0112) in IFD0 of a TIFF header, or null.
int? _orientation(List<int> tiff) {
  if (tiff.length < 8) return null;
  final little = tiff[0] == 0x49;
  int read(int at, int size) {
    var value = 0;
    for (var k = 0; k < size; k++) {
      value |= tiff[at + k] << (8 * (little ? k : size - 1 - k));
    }
    return value;
  }

  final ifd = read(4, 4);
  if (ifd + 2 > tiff.length) return null;
  final count = read(ifd, 2);
  for (var e = 0; e < count; e++) {
    final at = ifd + 2 + e * 12;
    if (at + 12 > tiff.length) return null;
    if (read(at, 2) == 0x0112) {
      final value = read(at + 8, 2);
      return value >= 1 && value <= 8 ? value : null;
    }
  }
  return null;
}

/// An APP1 segment with an EXIF block holding nothing but the orientation.
List<int> _orientationExif(int orientation) => [
      0xff, 0xe1, 0x00, 0x22, // marker, length 34
      ...'Exif\x00\x00'.codeUnits,
      ...'MM'.codeUnits, 0x00, 0x2a, 0x00, 0x00, 0x00, 0x08, // big-endian TIFF, IFD0 at 8
      0x00, 0x01, // one entry
      0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, orientation, 0x00, 0x00, // orientation, SHORT
      0x00, 0x00, 0x00, 0x00, // no next IFD
    ];

/// Text, time and EXIF chunks go, the picture stays.
Uint8List _png(List<int> b) {
  const drop = {'eXIf', 'tEXt', 'zTXt', 'iTXt', 'tIME'};
  if (b.length < 8) throw const FormatException('Broken PNG');
  final out = BytesBuilder(copy: false)..add(b.sublist(0, 8));
  var i = 8;
  while (true) {
    if (i + 8 > b.length) throw const FormatException('Broken PNG');
    final length = b[i] << 24 | b[i + 1] << 16 | b[i + 2] << 8 | b[i + 3];
    final type = String.fromCharCodes(b.sublist(i + 4, i + 8));
    final end = i + 12 + length;
    if (end > b.length) throw const FormatException('Broken PNG');
    if (!drop.contains(type)) out.add(b.sublist(i, end));
    i = end;
    if (type == 'IEND') break;
  }
  return out.takeBytes();
}

/// EXIF and XMP chunks go, and VP8X no longer announces them.
Uint8List _webp(List<int> b) {
  if (b.length < 12) throw const FormatException('Broken WebP');
  final out = BytesBuilder(copy: false)..add(b.sublist(0, 12));
  var i = 12;
  int size(int at) => b[at] | b[at + 1] << 8 | b[at + 2] << 16 | b[at + 3] << 24;
  final riffEnd = 8 + size(4);
  if (riffEnd > b.length) throw const FormatException('Broken WebP');
  while (i + 8 <= riffEnd) {
    final fourcc = String.fromCharCodes(b.sublist(i, i + 4));
    final end = i + 8 + size(i + 4) + size(i + 4) % 2;
    if (end > riffEnd) throw const FormatException('Broken WebP');
    if (fourcc == 'VP8X') {
      final chunk = b.sublist(i, end);
      chunk[8] &= ~0x0c; // EXIF and XMP flags
      out.add(chunk);
    } else if (fourcc != 'EXIF' && fourcc != 'XMP ') {
      out.add(b.sublist(i, end));
    }
    i = end;
  }
  final result = out.takeBytes();
  ByteData.sublistView(result).setUint32(4, result.length - 8, Endian.little);
  return result;
}

bool _startsWith(List<int> bytes, String prefix) =>
    bytes.length >= prefix.length && Iterable.generate(prefix.length).every((k) => bytes[k] == prefix.codeUnitAt(k));
