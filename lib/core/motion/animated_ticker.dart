import 'package:flutter/material.dart';

import 'motion_tokens.dart';

/// Odometer-style text: every digit rolls from its previous value to its
/// new one (on first mount, from zero), with a slight left-to-right stagger
/// and a soft vertical fade. Non-digit characters (",", ".", "%", units)
/// stay put.
///
/// The final string is always present as a real [Text] (transparent while
/// rolling), so layout, accessibility and `find.text` behave exactly like a
/// plain `Text`.
///
/// ```dart
/// AnimatedTicker('8,432', style: t.headlineMedium)
/// AnimatedTicker.value(72.5, fractionDigits: 1, suffix: ' kg')
/// ```
class AnimatedTicker extends StatefulWidget {
  const AnimatedTicker(
    this.text, {
    super.key,
    this.style,
    this.duration = AppMotion.data,
    this.curve = AppMotion.emphasizedDecelerate,
    this.textAlign,
    this.animateOnMount = true,
    this.semanticsLabel,
  });

  /// Formats [value] (thousands separators, fixed decimals) and ticks it.
  factory AnimatedTicker.value(
    num value, {
    Key? key,
    int fractionDigits = 0,
    String prefix = '',
    String suffix = '',
    TextStyle? style,
    Duration duration = AppMotion.data,
    TextAlign? textAlign,
  }) => AnimatedTicker(
    '$prefix${_group(value, fractionDigits)}$suffix',
    key: key,
    style: style,
    duration: duration,
    textAlign: textAlign,
  );

  final String text;
  final TextStyle? style;
  final Duration duration;
  final Curve curve;
  final TextAlign? textAlign;
  final bool animateOnMount;
  final String? semanticsLabel;

  static String _group(num v, int digits) {
    final fixed = v.abs().toStringAsFixed(digits);
    final parts = fixed.split('.');
    final intPart = parts[0];
    final b = StringBuffer(v < 0 ? '-' : '');
    for (var i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) b.write(',');
      b.write(intPart[i]);
    }
    if (parts.length > 1) b.write('.${parts[1]}');
    return b.toString();
  }

  @override
  State<AnimatedTicker> createState() => _AnimatedTickerState();
}

class _AnimatedTickerState extends State<AnimatedTicker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  late String _from;
  bool _started = false;

  static bool _isDigit(String ch) =>
      ch.codeUnitAt(0) >= 48 && ch.codeUnitAt(0) <= 57;

  @override
  void initState() {
    super.initState();
    _from = widget.text.replaceAll(RegExp('[0-9]'), '0');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final hasDigits = widget.text.contains(RegExp('[1-9]'));
    if (!widget.animateOnMount || !hasDigits || AppMotion.reduced(context)) {
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  @override
  void didUpdateWidget(AnimatedTicker old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) {
      _from = old.text;
      if (AppMotion.reduced(context) ||
          !widget.text.contains(RegExp('[0-9]'))) {
        _c.value = 1;
      } else {
        _c.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(widget.style);
    final text = Text(
      widget.text,
      style: style,
      textAlign: widget.textAlign,
      maxLines: 1,
      softWrap: false,
      semanticsLabel: widget.semanticsLabel,
    );
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        if (_c.isCompleted || _c.value >= 1) return text;
        final scaler = MediaQuery.textScalerOf(context);
        final dir = Directionality.of(context);
        return Semantics(
          label: widget.semanticsLabel ?? widget.text,
          excludeSemantics: true,
          child: Stack(
            children: [
              Opacity(opacity: 0, child: text),
              Positioned.fill(
                child: ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (r) => const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x00FFFFFF),
                      Color(0xFFFFFFFF),
                      Color(0xFFFFFFFF),
                      Color(0x00FFFFFF),
                    ],
                    stops: [0, 0.16, 0.84, 1],
                  ).createShader(r),
                  child: CustomPaint(
                    painter: _TickerPainter(
                      from: _from,
                      to: widget.text,
                      t: widget.curve.transform(_c.value),
                      style: style,
                      scaler: scaler,
                      direction: dir,
                      align: widget.textAlign,
                      isDigit: _isDigit,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TickerPainter extends CustomPainter {
  _TickerPainter({
    required this.from,
    required this.to,
    required this.t,
    required this.style,
    required this.scaler,
    required this.direction,
    required this.align,
    required this.isDigit,
  });

  final String from;
  final String to;
  final double t;
  final TextStyle style;
  final TextScaler scaler;
  final TextDirection direction;
  final TextAlign? align;
  final bool Function(String) isDigit;

  TextPainter _tp(String s) => TextPainter(
    text: TextSpan(text: s, style: style),
    textDirection: direction,
    textScaler: scaler,
    maxLines: 1,
  )..layout();

  static num? _num(String s) =>
      num.tryParse(s.replaceAll(RegExp(r'[^0-9.\-]'), ''));

  @override
  void paint(Canvas canvas, Size size) {
    final full = _tp(to);
    final dx = switch (align) {
      TextAlign.right || TextAlign.end => size.width - full.width,
      TextAlign.center => (size.width - full.width) / 2,
      _ => 0.0,
    };
    final h = full.height;
    final digits = [for (var d = 0; d < 10; d++) _tp('$d')];
    final a = _num(from);
    final b = _num(to);
    final down = a != null && b != null && b < a;
    final n = to.length;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (var i = 0; i < n; i++) {
      final ch = to[i];
      final x0 = full.getOffsetForCaret(TextPosition(offset: i), Rect.zero).dx;
      final x1 = i + 1 < n
          ? full.getOffsetForCaret(TextPosition(offset: i + 1), Rect.zero).dx
          : full.width;
      final w = x1 - x0;
      // Right-align old and new strings so units line up.
      final j = from.length - (n - i);
      final old = j >= 0 && j < from.length ? from[j] : null;
      // Left columns start slightly later: a gentle wave.
      final lag = n <= 1 ? 0.0 : 0.22 * (i / (n - 1));
      final lt = ((t - lag) / (1 - lag)).clamp(0.0, 1.0);
      if (!isDigit(ch)) {
        final tp = _tp(ch);
        tp.paint(canvas, Offset(dx + x0, 0));
        continue;
      }
      final target = int.parse(ch);
      final start = old != null && isDigit(old) ? int.parse(old) : 0;
      var steps = (target - start) % 10;
      if (down && steps != 0) steps -= 10;
      final p = start + steps * lt;
      final lower = p.floorToDouble();
      final frac = p - lower;
      final d0 = digits[lower.toInt() % 10];
      final d1 = digits[(lower.toInt() + 1) % 10];
      final cx = dx + x0 + (w - d0.width) / 2;
      d0.paint(canvas, Offset(cx, -frac * h));
      if (frac > 0.001) d1.paint(canvas, Offset(cx, (1 - frac) * h));
    }
    canvas.restore();
    full.dispose();
    for (final d in digits) {
      d.dispose();
    }
  }

  @override
  bool shouldRepaint(_TickerPainter old) =>
      old.t != t || old.to != to || old.from != from || old.style != style;
}
