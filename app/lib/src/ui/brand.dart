import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

// Pleasance family band, see DESIGN.md in the starter: glow for gradient
// surfaces and dark backgrounds, deep for text on light ones.
const glow = [
  Color(0xFFF2545B),
  Color(0xFFFB8C45),
  Color(0xFFF2C14E),
  Color(0xFF6CCF8E),
  Color(0xFF46BFE0),
  Color(0xFF8E92F8),
  Color(0xFFC39BF2),
];
const deep = [
  Color(0xFFB3262D),
  Color(0xFFA8461A),
  Color(0xFF876008),
  Color(0xFF1D6A44),
  Color(0xFF156A88),
  Color(0xFF3B3EA8),
  Color(0xFF6A33A0),
];

/// This app's section of the band.
const appBand = (from: 2.55, to: 3.20);

/// The vegan seal's section, so it differs from the overall one next to it.
const veganBand = (from: 3.40, to: 4.00);

const paper = Color(0xFFF4F4F1);
const ink = Color(0xFF17171A);
const muted = Color(0xFF5E5E66);
const hairline = Color(0x2917171A);
const night = Color(0xFF0E0D12);
const nightRaised = Color(0xFF16151B);
const nightText = Color(0xFFF2F0EA);
const nightMuted = Color(0xFF9A98A3);
const nightLine = Color(0x14FFFFFF);
const tileColor = Color(0xFF121117);

// Signal colours, see DESIGN.md in the starter: the same in every product, never the product colour.
// Filled counters take glow with ink text, text and lines on paper take deep.
const needsGlow = Color(0xFFF4B44C);
const needsDeep = Color(0xFF8F5A0C);
const newGlow = Color(0xFF6CCF8E);
const newDeep = Color(0xFF1D6A44);
const errorGlow = Color(0xFFF2545B);
const errorDeep = Color(0xFFB3262D);
const displayFont = 'Bricolage Grotesque';

/// Product name, titles and big numbers: narrow and bold.
const displayStyle = TextStyle(
  fontFamily: displayFont,
  fontWeight: FontWeight.w800,
  letterSpacing: -0.2,
  fontVariations: [FontVariation('wdth', 78), FontVariation('wght', 780)],
);

/// Ranks and scores, a notch narrower.
const numberStyle = TextStyle(
  fontFamily: displayFont,
  fontWeight: FontWeight.w800,
  height: 1,
  fontVariations: [FontVariation('wdth', 75), FontVariation('wght', 800)],
);

/// Colour at a position from 1 to 7, linear between neighbouring stages.
Color bandColor(double position, List<Color> tones) {
  final p = position.clamp(1.0, 7.0);
  final i = math.min(5, (p - 1).floor());
  return Color.lerp(tones[i], tones[i + 1], p - 1 - i)!;
}

/// Gradient of this app's section (or [band]), from bottom left to top right.
LinearGradient bandGradient(List<Color> tones, {({double from, double to}) band = appBand}) => LinearGradient(
      begin: Alignment.bottomLeft,
      end: Alignment.topRight,
      colors: [
        bandColor(band.from, tones),
        bandColor((band.from + band.to) / 2, tones),
        bandColor(band.to, tones),
      ],
    );

final actionGradient = bandGradient(glow);

/// The middle of the section: deep on light ground, glow on dark.
Color accentFor(Brightness brightness) =>
    bandColor((appBand.from + appBand.to) / 2, brightness == Brightness.dark ? glow : deep);

/// Dark tile with the app's sign, a skewer, in the gradient.
class BrandTile extends StatelessWidget {
  final double size;
  const BrandTile({super.key, this.size = 40});

  @override
  Widget build(BuildContext context) =>
      Semantics(label: 'Döner App', child: CustomPaint(size: Size.square(size), painter: const _TilePainter()));
}

class _TilePainter extends CustomPainter {
  const _TilePainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 100);
    canvas.drawRRect(RRect.fromLTRBR(0, 0, 100, 100, const Radius.circular(24)), Paint()..color = tileColor);
    final sign = Path()
      ..moveTo(41, 26)
      ..lineTo(59, 26)
      ..moveTo(50, 26)
      ..lineTo(50, 33)
      ..moveTo(32, 33)
      ..lineTo(68, 33)
      ..quadraticBezierTo(67, 52, 59, 65)
      ..lineTo(41, 65)
      ..quadraticBezierTo(33, 52, 32, 33)
      ..close()
      ..moveTo(50, 65)
      ..lineTo(50, 74);
    canvas.drawPath(
      sign,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..shader = actionGradient.createShader(const Rect.fromLTRB(22, 22, 78, 78)),
    );
  }

  @override
  bool shouldRepaint(_TilePainter oldDelegate) => false;
}

/// Gradient mark of the active tab: a 2 px line above its icon.
class ActiveTabMark extends StatelessWidget {
  final Widget icon;
  const ActiveTabMark({super.key, required this.icon});

  @override
  Widget build(BuildContext context) => Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          icon,
          Positioned(
            top: -16,
            child: Container(
              width: 32,
              height: 2,
              decoration: BoxDecoration(gradient: actionGradient, borderRadius: BorderRadius.circular(1)),
            ),
          ),
        ],
      );
}

/// Progress in the gradient.
class GradientProgress extends StatelessWidget {
  final double value;
  const GradientProgress({super.key, required this.value});

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Container(
          height: 8,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06),
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: value.clamp(0, 1),
            child: DecoratedBox(
              decoration: BoxDecoration(gradient: actionGradient, borderRadius: BorderRadius.circular(4)),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
}

/// Sender line at the bottom of a screen: made by Pleasance and where this app
/// sits on the family band. The app speaks German only, so there's no
/// language button.
class PleasanceFooter extends StatelessWidget {
  const PleasanceFooter({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.outline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: theme.dividerColor))),
      child: Row(
        children: [
          Text('ein Werkzeug von', style: theme.textTheme.bodySmall?.copyWith(color: color)),
          const SizedBox(width: 8),
          SvgPicture.asset(
            'assets/pleasance-wordmark.svg',
            height: 13,
            colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
            semanticsLabel: 'Pleasance',
          ),
          const SizedBox(width: 16),
          const Expanded(child: Align(alignment: Alignment.centerRight, heightFactor: 1, child: _BandLine())),
        ],
      ),
    );
  }
}

class _BandLine extends StatelessWidget {
  const _BandLine();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dim = theme.brightness == Brightness.dark ? Colors.black.withValues(alpha: 0.55) : Colors.white.withValues(alpha: 0.6);
    // 120 wide, narrower when the footer runs out of room
    return SizedBox(
      width: 120,
      height: 9,
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: 3,
              height: 3,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.all(Radius.circular(2)),
                  gradient: LinearGradient(colors: [for (final c in glow) Color.alphaBlend(dim, c)]),
                ),
              ),
            ),
            Positioned(
              left: constraints.maxWidth * (appBand.from - 1) / 6,
              top: 0,
              width: math.max(9, constraints.maxWidth * (appBand.to - appBand.from) / 6),
              height: 9,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: actionGradient,
                  borderRadius: const BorderRadius.all(Radius.circular(5)),
                  boxShadow: [BoxShadow(color: theme.scaffoldBackgroundColor, spreadRadius: 2)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Round main action in the gradient, grey while not [active]. Without
/// [onPressed] it only draws, e.g. as the icon of a navigation item.
class GradientCircle extends StatelessWidget {
  final double size;
  final bool active;
  final VoidCallback? onPressed;
  final Widget child;
  const GradientCircle({super.key, required this.size, required this.active, this.onPressed, required this.child});

  @override
  Widget build(BuildContext context) => Material(
        type: MaterialType.transparency,
        child: Ink(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: active ? actionGradient : null,
            color: active ? null : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08),
          ),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox.square(
              dimension: size,
              child: Center(child: IconTheme.merge(data: IconThemeData(color: ink, size: size * 0.46), child: child)),
            ),
          ),
        ),
      );
}
