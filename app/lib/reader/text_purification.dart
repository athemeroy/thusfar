import 'dart:math' as math;

/// Literal, paragraph-local replacements. No user input is evaluated as regex.
class PurificationRule {
  const PurificationRule({
    required this.id,
    required this.find,
    this.replacement = '',
    this.bookId,
    this.enabled = true,
  });

  final String id;
  final String find;
  final String replacement;
  final String? bookId;
  final bool enabled;

  static const int maxRules = 64;
  static const int maxText = 512;

  String? get error {
    if (find.isEmpty) return '请填写要匹配的原文';
    if (find.length > maxText || replacement.length > maxText) {
      return '每段文字最多 512 个字符';
    }
    if (find.contains(RegExp(r'[\r\n]')) ||
        replacement.contains(RegExp(r'[\r\n]'))) {
      return '每条规则只处理一段内的文字，请去掉换行';
    }
    if (!validUtf16(find) || !validUtf16(replacement)) return '文字不完整，请重新输入';
    if (replacement.length > find.length * 8) return '替换文字不能超过原文长度的 8 倍';
    return null;
  }

  PurificationRule copyWith({bool? enabled}) => PurificationRule(
    id: id,
    find: find,
    replacement: replacement,
    bookId: bookId,
    enabled: enabled ?? this.enabled,
  );
}

bool validUtf16(String value) {
  for (int i = 0; i < value.length; i++) {
    final int unit = value.codeUnitAt(i);
    if (_high(unit)) {
      if (++i >= value.length || !_low(value.codeUnitAt(i))) return false;
    } else if (_low(unit)) {
      return false;
    }
  }
  return true;
}

bool _high(int unit) => unit >= 0xd800 && unit <= 0xdbff;
bool _low(int unit) => unit >= 0xdc00 && unit <= 0xdfff;

class _Run {
  const _Run(this.a, this.z, this.s, this.e, {this.literal = false});
  final int a, z, s, e;
  final bool literal;
}

/// Bidirectional UTF-16 coordinates for one immutable source paragraph.
/// Replacement characters cite the complete original match. Deleted characters
/// have no display span. A selection crossing a deletion still quotes source.
class PurifiedText {
  PurifiedText._(this.source, this.text, this._runs);
  factory PurifiedText.original(String source) => PurifiedText._(
    source,
    source,
    source.isEmpty
        ? const <_Run>[]
        : <_Run>[_Run(0, source.length, 0, source.length)],
  );

  final String source;
  final String text;
  final List<_Run> _runs;

  _Run? _at(int index) {
    int lo = 0, hi = _runs.length;
    while (lo < hi) {
      final int mid = (lo + hi) ~/ 2;
      if (_runs[mid].z <= index) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo < _runs.length ? _runs[lo] : null;
  }

  int sourceStart(int display) {
    final int at = display.clamp(0, text.length);
    final _Run? run = _at(at);
    if (run == null) return source.length;
    return run.literal ? run.s : run.s + at - run.a;
  }

  int sourceEnd(int display) {
    final int at = display.clamp(0, text.length);
    if (at == 0) return 0;
    final _Run run = _at(at - 1)!;
    return run.literal ? run.e : run.s + at - run.a;
  }

  /// Display character hit, widened to complete Unicode/source replacement.
  (int, int)? sourceCharacter(int display) {
    if (text.isEmpty) return null;
    int a = display.clamp(0, text.length - 1), z = a + 1;
    if (a > 0 && _low(text.codeUnitAt(a))) a--;
    if (z < text.length && _high(text.codeUnitAt(z - 1))) z++;
    return (sourceStart(a), sourceEnd(z));
  }

  /// First displayed character overlapping a source range starting at [source].
  int displayStart(int source) {
    final int at = source.clamp(0, this.source.length);
    int lo = 0, hi = _runs.length;
    while (lo < hi) {
      final int mid = (lo + hi) ~/ 2;
      if (_runs[mid].e <= at) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo == _runs.length) return text.length;
    final _Run run = _runs[lo];
    return run.literal ? run.a : run.a + math.max(0, at - run.s);
  }

  int displayEnd(int source) {
    final int at = source.clamp(0, this.source.length);
    int lo = 0, hi = _runs.length;
    while (lo < hi) {
      final int mid = (lo + hi) ~/ 2;
      if (_runs[mid].s < at) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo == 0) return 0;
    final _Run run = _runs[lo - 1];
    return run.literal ? run.z : run.a + math.min(at - run.s, run.e - run.s);
  }
}

/// Matches original text once, left to right. At the same position the earlier
/// rule wins; emitted replacements are never matched again. Escaped literals
/// and a fixed rule/text budget avoid user-controlled regex and cascade growth.
class TextPurifier {
  TextPurifier(Iterable<PurificationRule> rules)
    : rules = List<PurificationRule>.unmodifiable(
        rules.where((r) => r.enabled),
      ) {
    if (this.rules.length > PurificationRule.maxRules ||
        this.rules.any((r) => r.error != null)) {
      throw const FormatException('净化规则无效');
    }
    if (this.rules.isNotEmpty) {
      _pattern = RegExp(
        this.rules.map((r) => RegExp.escape(r.find)).join('|'),
        unicode: true,
      );
      for (final PurificationRule rule in this.rules) {
        _byText.putIfAbsent(rule.find, () => rule);
      }
    }
  }

  final List<PurificationRule> rules;
  RegExp? _pattern;
  final Map<String, PurificationRule> _byText = <String, PurificationRule>{};

  PurifiedText apply(String source) {
    final RegExp? pattern = _pattern;
    if (pattern == null || source.isEmpty) return PurifiedText.original(source);
    final StringBuffer out = StringBuffer();
    final List<_Run> runs = <_Run>[];
    int from = 0, offset = 0;
    void unchanged(int end) {
      if (end == from) return;
      out.write(source.substring(from, end));
      runs.add(_Run(offset, offset + end - from, from, end));
      offset += end - from;
    }

    for (final RegExpMatch match in pattern.allMatches(source)) {
      unchanged(match.start);
      final String replacement = _byText[match.group(0)]!.replacement;
      if (replacement.isNotEmpty) {
        out.write(replacement);
        runs.add(
          _Run(
            offset,
            offset + replacement.length,
            match.start,
            match.end,
            literal: replacement != match.group(0),
          ),
        );
        offset += replacement.length;
      }
      from = match.end;
    }
    unchanged(source.length);
    return PurifiedText._(source, out.toString(), runs);
  }
}
