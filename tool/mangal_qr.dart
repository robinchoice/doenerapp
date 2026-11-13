import 'dart:io';

import 'package:qr/qr.dart';

void main(List<String> args) {
  final image = QrImage(
    QrCode(
      payload: QrPayload.fromString(args.single),
      errorCorrectLevel: QrErrorCorrectLevel.medium,
    ),
  );
  final size = image.moduleCount + 8;
  final path = StringBuffer();
  for (var row = 0; row < image.moduleCount; row++) {
    for (var col = 0; col < image.moduleCount; col++) {
      if (image.isDark(row, col)) path.write('M${col + 4} ${row + 4}h1v1h-1z');
    }
  }
  stdout.write(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $size $size" shape-rendering="crispEdges">'
    '<rect width="$size" height="$size" fill="white"/><path d="$path" fill="black"/></svg>',
  );
}
