import 'package:flutter/material.dart';

/// Minimal, safe markdown renderer for chat: paragraphs, `- `/`* `/`• `
/// bullets, `1.` numbered lines, `#` headings and `**bold**` / `` `code` ``
/// inline spans. Everything else is shown as plain text (no links, no HTML).
class MarkdownLite extends StatelessWidget {
  const MarkdownLite(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  static final _bullet = RegExp(r'^\s*([-*•])\s+(.*)$');
  static final _numbered = RegExp(r'^\s*(\d{1,2})[.)]\s+(.*)$');
  static final _heading = RegExp(r'^\s*#{1,4}\s+(.*)$');

  @override
  Widget build(BuildContext context) {
    final base = style ?? Theme.of(context).textTheme.bodyLarge!;
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    final children = <Widget>[];
    var paragraph = <String>[];

    void flush() {
      if (paragraph.isEmpty) return;
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text.rich(
            TextSpan(children: inlineSpans(paragraph.join(' '), base)),
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
                ),
              ),
            ),
          ),
        );
      } else if (b != null || n != null) {
        flush();
        final marker = b != null ? '•' : '${n!.group(1)}.';
        final body = b != null ? b.group(2)! : n!.group(2)!;
        children.add(
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 20, child: Text(marker, style: base)),
                Expanded(
                  child: Text.rich(TextSpan(children: inlineSpans(body, base))),
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

  /// Splits `**bold**` and `` `code` `` into styled spans.
  static List<InlineSpan> inlineSpans(String s, TextStyle base) {
    final spans = <InlineSpan>[];
    final re = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`');
    var last = 0;
    for (final m in re.allMatches(s)) {
      if (m.start > last) {
        spans.add(TextSpan(text: s.substring(last, m.start), style: base));
      }
      if (m.group(1) != null) {
        spans.add(
          TextSpan(
            text: m.group(1),
            style: base.copyWith(fontWeight: FontWeight.w700),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: m.group(2),
            style: base.copyWith(fontFamily: 'monospace'),
          ),
        );
      }
      last = m.end;
    }
    if (last < s.length) {
      spans.add(TextSpan(text: s.substring(last), style: base));
    }
    return spans;
  }
}
