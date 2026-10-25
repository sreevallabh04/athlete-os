// Renders the Athlete OS launcher icon + splash artwork from the same
// `EmblemPainter` the app uses at runtime.
//
//   flutter test tool/render_icon_test.dart
//   dart run flutter_launcher_icons
//   dart run flutter_native_splash:create
//
// Outputs (all under assets/icon/):
//   icon.png             1024² legacy/full-bleed icon (master)
//   icon_foreground.png  1024² adaptive foreground (launcher adds 16 % inset)
//   icon_background.png  1024² adaptive background
//   icon_monochrome.png  1024² Android 13 themed icon (white on transparent)
//   splash.png           480²  pre-Android-12 splash (120 dp at xxxhdpi)
//   splash_android12.png 1152² Android 12+ splash icon (emblem in 768 circle)
//   preview_48.png       48²   legibility check at launcher size
import 'dart:io';
import 'dart:ui' as ui;

import 'package:athlete_os/core/widgets/emblem.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _render(
  String name,
  int px,
  void Function(Canvas canvas, Size size) paint,
) async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  paint(canvas, Size(px.toDouble(), px.toDouble()));
  final picture = rec.endRecording();
  final image = await picture.toImage(px, px);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('assets/icon/$name');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes!.buffer.asUint8List());
  image.dispose();
  picture.dispose();
}

void main() {
  testWidgets('render launcher icon and splash artwork', (tester) async {
    await tester.runAsync(() async {
      // Legacy / master: full-bleed background + emblem sized for circle masks.
      await _render('icon.png', 1024, (c, s) {
        const IconBackgroundPainter().paint(c, s);
        const EmblemPainter(scale: 0.74).paint(c, s);
      });
      await _render('icon_foreground.png', 1024, (c, s) {
        // flutter_launcher_icons wraps adaptive layers in a 16 % inset, so
        // the emblem fills this canvas; the result lands inside the 66 dp
        // safe zone of the 108 dp adaptive icon.
        const EmblemPainter(scale: 0.92).paint(c, s);
      });
      await _render('icon_background.png', 1024, (c, s) {
        const IconBackgroundPainter().paint(c, s);
      });
      await _render('icon_monochrome.png', 1024, (c, s) {
        const EmblemPainter(scale: 0.92, style: EmblemStyle.mono).paint(c, s);
      });
      // Splash emblems use scale 0.9 so the bloom is not clipped; the boot
      // sequence starts with a 108 dp AthleteEmblem to match exactly.
      await _render('splash.png', 480, (c, s) {
        const EmblemPainter(scale: 0.9).paint(c, s);
      });
      await _render('splash_android12.png', 1152, (c, s) {
        c.save();
        c.translate((1152 - 480) / 2, (1152 - 480) / 2);
        const EmblemPainter(scale: 0.9).paint(c, const Size(480, 480));
        c.restore();
      });
      await _render('preview_48.png', 48, (c, s) {
        c.clipRRect(
          RRect.fromRectAndRadius(Offset.zero & s, const Radius.circular(24)),
        );
        const IconBackgroundPainter().paint(c, s);
        const EmblemPainter(scale: 0.74).paint(c, s);
      });
    });
  });
}
