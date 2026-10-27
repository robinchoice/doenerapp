import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../ui/brand.dart';

typedef MapPin = ({BitmapDescriptor icon, Offset anchor});

/// Pin colours: favourites pink, visited green, the rest in the app's tone.
const favoritePinColor = Color(0xFFF06292);
const visitedPinColor = newGlow;
final placePinColor = bandColor((appBand.from + appBand.to) / 2, glow);

/// A pin like Google's: the [score] in a pill with a tip, the [name] beside
/// it. Without a score only a small dot, anchored at its centre.
Future<MapPin> drawPin({
  required Color color,
  required Brightness brightness,
  required double pixelRatio,
  String? score,
  String? name,
}) async {
  final dark = brightness == Brightness.dark;
  // Same as the map's ground (see mapStyle), so pins and names stand out.
  final ground = dark ? const Color(0xFF1C1B21) : Colors.white;
  const border = 2.0, tip = 5.0, gap = 4.0, halo = 3.0;

  final scorePainter = score == null
      ? null
      : (TextPainter(
          text: TextSpan(
            text: score,
            style: numberStyle.copyWith(fontSize: 15, color: ink),
          ),
          textDirection: TextDirection.ltr,
        )..layout());
  final pill = scorePainter == null ? const Size(16, 16) : Size(scorePainter.width + 16, 24);

  TextPainter? namePainter(TextStyle style) => name == null
      ? null
      : (TextPainter(
          text: TextSpan(text: name, style: style),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…',
        )..layout(maxWidth: 140));
  const nameStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w700);
  final nameFill = namePainter(nameStyle.copyWith(color: dark ? nightText : ink));
  final nameHalo = namePainter(
    nameStyle.copyWith(
      foreground: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = halo
        ..strokeJoin = StrokeJoin.round
        ..color = ground,
    ),
  );

  // Room above a small dot so a taller name isn't cut off.
  final top = math.max(border, nameFill == null ? 0.0 : nameFill.height / 2 + halo - pill.height / 2);
  final pillCenterY = top + pill.height / 2;
  final width = border * 2 + pill.width + (nameFill == null ? 0 : gap + nameFill.width + halo);
  final height = math.max(
    top + pill.height + border + (scorePainter == null ? 0 : tip),
    nameFill == null ? 0.0 : pillCenterY + nameFill.height / 2 + halo,
  );

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(pixelRatio);
  final pillRect = Rect.fromLTWH(border, top, pill.width, pill.height);
  final centerX = pillRect.center.dx;
  final shape = Path()..addRRect(RRect.fromRectAndRadius(pillRect, Radius.circular(pill.height / 2)));
  if (scorePainter != null) {
    shape
      ..moveTo(centerX - tip, pillRect.bottom - 1)
      ..lineTo(centerX, pillRect.bottom + tip)
      ..lineTo(centerX + tip, pillRect.bottom - 1)
      ..close();
  }
  canvas.drawPath(
    shape,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = border * 2
      ..strokeJoin = StrokeJoin.round
      ..color = ground,
  );
  canvas.drawPath(shape, Paint()..color = color);
  scorePainter?.paint(canvas, pillRect.center - Offset(scorePainter.width / 2, scorePainter.height / 2));
  if (nameFill != null) {
    final at = Offset(pillRect.right + border + gap, pillRect.center.dy - nameFill.height / 2);
    nameHalo!.paint(canvas, at);
    nameFill.paint(canvas, at);
  }

  final image = await recorder.endRecording().toImage((width * pixelRatio).ceil(), (height * pixelRatio).ceil());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final logicalWidth = image.width / pixelRatio, logicalHeight = image.height / pixelRatio;
  image.dispose();
  return (
    icon: BytesMapBitmap(bytes!.buffer.asUint8List(), imagePixelRatio: pixelRatio),
    anchor: scorePainter == null
        ? Offset(centerX / logicalWidth, pillRect.center.dy / logicalHeight)
        : Offset(centerX / logicalWidth, (pillRect.bottom + tip) / logicalHeight),
  );
}
