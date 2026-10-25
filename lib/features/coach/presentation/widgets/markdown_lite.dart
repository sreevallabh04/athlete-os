import 'package:flutter/material.dart';

/// Minimal, safe markdown renderer for chat: paragraphs, `- `/`* `/`• `
/// bullets, `1.` numbered lines, `#` headings and `**bold**` / `` `code` ``
/// inline spans. Everything else is shown as plain text (no links, no HTML).
///
/// [reveal] (word count, fractional) fades words in one by one for the
/// "streaming" effect; null shows everything. The plain text of every
/// paragraph is always complete, so finders and screen readers see the
/// whole answer immediately.
class MarkdownLite extends StatelessWidget {
  const MarkdownLite(
    this.text, {
    super.key,
    this.style,
    this.reveal,
    this.accent,
    this.boldColor,
  });

  final String text;
  final TextStyle? style;
  final double? reveal;

  /// Bullet marker colour.
  final Color? accent;

  /// Colour for `**bold**` spans (key numbers); defaults to the text colour.
  final Color? boldColor;

  static final _bullet = RegExp(r'^\s*([-*•])\s+(.*)$');
  static final _numbered = RegExp(r'^\s*(\d{1,2})[.)]\s+(.*)$');
  static final _heading = RegExp(r'^\s*#{1,4}\s+(.*)$');

  /// Number of words [text] reveals (for animation durations).
  static int wordCount(String text) => RegExp(r'\S+').allMatches(text).length;

  @override
  Widget build(BuildContext context) {
    final base = style ?? Theme.of(context).textTheme.bodyLarge!;
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    final children = <Widget>[];
    var paragraph = <String>[];
    final counter = _WordCounter(reveal);

    void flush() {
      if (paragraph.isEmpty) return;
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text.rich(
            TextSpan(
              children: inlineSpans(
                paragraph.join(' '),
                base,
                counter: counter,
                boldColor: boldColor,
              ),
            ),
          ),
        ),
      );
      paragraph = [];
    }

    for (final raw in lines) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        flush();
        continue;
      }
      final h = _heading.firstMatch(line);
      final b = _bullet.firstMatch(line);
      final n = _numbered.firstMatch(line);
      if (h != null) {
        flush();
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Text.rich(
              TextSpan(
                children: inlineSpans(
                  h.group(1)!,
                  base.copyWith(fontWeight: FontWeight.w700),
                  counter: counter,
                  boldColor: boldColor,
                ),
              ),
            ),
          ),
        );
      } else if (b != null || n != null) {
        flush();
        final body = b != null ? b.group(2)! : n!.group(2)!;
        final markerOpacity = counter.peek();
        final markerColor = accent ?? base.color ?? Colors.white;
        final fontSize = base.fontSize ?? 16;
        children.add(
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 18,
                  child: b != null
                      ? Container(
                          alignment: Alignment.topLeft,
                          padding: EdgeInsets.only(
                            top: fontSize * (base.height ?? 1.4) / 2 - 1,
                          ),
                          child: Opacity(
                            opacity: markerOpacity,
                            child: Container(
                              width: 7,
                              height: 2,
                              decoration: BoxDecoration(
                                color: markerColor,
                                borderRadius: BorderRadius.circular(1),
                                boxShadow: [
                                  BoxShadow(
                                    color: markerColor.withValues(alpha: 0.6),
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        )
                      : Text(
                          '${n!.group(1)}.',
                          style: base.copyWith(
                            color: markerColor.withValues(alpha: markerOpacity),
                          ),
                        ),
                ),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: inlineSpans(
                        body,
                        base,
                        counter: counter,
                        boldColor: boldColor,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      } else {
        paragraph.add(line.trim());
      }
    }
    flush();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  /// Splits `**bold**` and `` `code` `` into styled spans. With a reveal
  /// [counter] every word becomes its own span whose opacity follows it.
  static List<InlineSpan> inlineSpans(
    String s,
    TextStyle base, {
    Object? counter,
    Color? boldColor,
  }) {
    final c = counter is _WordCounter ? counter : null;
    final spans = <InlineSpan>[];
    final re = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`');
    var last = 0;
    void emit(String text, TextStyle style) {
      if (c == null || c.reveal == null) {
        spans.add(TextSpan(text: text, style: style));
        return;
      }
      // One span per word (trailing whitespace attached), each with its own
      // alpha, so words materialise one by one.
      final color = style.color ?? base.color ?? Colors.white;
      for (final m in RegExp(r'\S+\s*|\s+').allMatches(text)) {
        final piece = m.group(0)!;
        final o = piece.trim().isEmpty ? c.peek() : c.next();
        spans.add(
          TextSpan(
            text: piece,
            style: style.copyWith(color: color.withValues(alpha: color.a * o)),
          ),
        );
      }
    }

    for (final m in re.allMatches(s)) {
      if (m.start > last) emit(s.substring(last, m.start), base);
      if (m.group(1) != null) {
        emit(
          m.group(1)!,
          base.copyWith(fontWeight: FontWeight.w700, color: boldColor),
        );
      } else {
        emit(m.group(2)!, base.copyWith(fontFamily: 'JetBrainsMono'));
      }
      last = m.end;
    }
    if (last < s.length) emit(s.substring(last), base);
    return spans;
  }
}

/// Walks words in document order and returns each one's reveal opacity.
class _WordCounter {
  _WordCounter(this.reveal);
  final double? reveal;
  int _i = 0;

  /// Words fade in over a 3-word window behind the reveal head.
  double _at(int i) {
    final r = reveal;
    if (r == null) return 1;
    return ((r - i) / 3).clamp(0.0, 1.0);
  }

  double next() => _at(_i++);
  double peek() => _at(_i);
}
