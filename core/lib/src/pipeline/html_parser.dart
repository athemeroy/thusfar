/// Python 3.11 `html.parser.HTMLParser` with `convert_charrefs=True`.
///
/// The EPUB reader depends on exactly how Python splits markup into start
/// tags, end tags and text, so this follows `goahead`, `parse_starttag` and
/// `parse_endtag` step by step rather than using an HTML5 tree builder.
library;

import 'package:html_unescape/html_unescape.dart';

import '../py/py_re.dart';

final HtmlUnescape _unescaper = HtmlUnescape();

/// `html.unescape`.
String unescape(String s) => s.contains('&') ? _unescaper.convert(s) : s;

final RegExp _starttagopen = pyRe('<[a-zA-Z]');
final RegExp _tagfindTolerant = pyRe(
  r'([a-zA-Z][^\t\n\r\f />\x00]*)(?:\s|/(?!>))*',
);
final RegExp _attrfindTolerant = pyRe(
  r'''((?<=['"\s/])[^\s/>][^\s/=>]*)(\s*=+\s*('[^']*'|"[^"]*"|(?!['"])[^>\s]*))?(?:\s|/(?!>))*''',
);
final RegExp _locatestarttagendTolerant = pyRe(r'''
  <[a-zA-Z][^\t\n\r\f />\x00]*
  (?:[\s/]*
    (?:(?<=['"\s/])[^\s/>][^\s/=>]*
      (?:\s*=+\s*
        (?:'[^']*'
          |"[^"]*"
          |(?!['"])[^>\s]*
         )
        \s*
       )?(?:\s|/(?!>))*
     )*
   )?
  \s*
''', verbose: true);
final RegExp _endtagfind = pyRe(r'</\s*([a-zA-Z][-.a-zA-Z0-9:_]*)\s*>');
final RegExp _commentclose = pyRe(r'--\s*>');
final RegExp _markedsectionclose = pyRe(r']\s*]\s*>');
final RegExp _msmarkedsectionclose = pyRe(r']\s*>');
final RegExp _declname = pyRe(r'[a-zA-Z][-_.a-zA-Z0-9]*\s*');

/// Callbacks mirror the Python method names.
abstract class PyHtmlParser {
  String _raw = '';
  String? _cdataElem;
  String? _starttagText;
  RegExp? _interestingCdata;

  String? getStarttagText() => _starttagText;

  void handleStarttag(String tag, List<(String, String?)> attrs) {}

  void handleEndtag(String tag) {}

  void handleStartendtag(String tag, List<(String, String?)> attrs) {
    handleStarttag(tag, attrs);
    handleEndtag(tag);
  }

  void handleData(String data) {}

  /// `feed(text); close()` in one call.
  void feedAll(String text) {
    _raw = text;
    _goahead();
  }

  void _goahead() {
    final String raw = _raw;
    final int n = raw.length;
    int i = 0;
    while (i < n) {
      int j;
      if (_cdataElem == null) {
        j = raw.indexOf('<', i);
        if (j < 0) j = n;
      } else {
        final RegExpMatch? m = _first(_interestingCdata!, raw, i);
        j = m == null ? n : m.start;
      }
      if (i < j)
        handleData(
          _cdataElem == null
              ? unescape(raw.substring(i, j))
              : raw.substring(i, j),
        );
      i = j;
      if (i == n) break;
      int k;
      if (_starttagopen.matchAsPrefix(raw, i) != null) {
        k = _parseStarttag(i);
      } else if (raw.startsWith('</', i)) {
        k = _parseEndtag(i);
      } else if (raw.startsWith('<!--', i)) {
        k = _parseComment(i);
      } else if (raw.startsWith('<?', i)) {
        final int gt = raw.indexOf('>', i + 2);
        k = gt < 0 ? -1 : gt + 1;
      } else if (raw.startsWith('<!', i)) {
        k = _parseHtmlDeclaration(i);
      } else if (i + 1 < n) {
        handleData('<');
        k = i + 1;
      } else {
        k = -1;
      }
      if (k < 0) {
        k = raw.indexOf('>', i + 1);
        if (k < 0) {
          k = raw.indexOf('<', i + 1);
          if (k < 0) k = i + 1;
        } else {
          k += 1;
        }
        handleData(
          _cdataElem == null
              ? unescape(raw.substring(i, k))
              : raw.substring(i, k),
        );
      }
      i = k;
    }
  }

  RegExpMatch? _first(RegExp re, String s, int from) {
    for (final RegExpMatch m in re.allMatches(s, from)) {
      return m;
    }
    return null;
  }

  int _checkForWholeStartTag(int i) {
    final String raw = _raw;
    final Match? m = _locatestarttagendTolerant.matchAsPrefix(raw, i);
    if (m == null) return -1;
    final int j = m.end;
    if (j >= raw.length) return -1;
    final String next = raw[j];
    if (next == '>') return j + 1;
    if (next == '/') {
      if (raw.startsWith('/>', j)) return j + 2;
      if (raw.startsWith('/', j)) return -1;
      return j > i ? j : i + 1;
    }
    if ('abcdefghijklmnopqrstuvwxyz=/ABCDEFGHIJKLMNOPQRSTUVWXYZ'.contains(next))
      return -1;
    return j > i ? j : i + 1;
  }

  int _parseStarttag(int i) {
    final int endpos = _checkForWholeStartTag(i);
    if (endpos < 0) return endpos;
    final String raw = _raw;
    _starttagText = raw.substring(i, endpos);
    final List<(String, String?)> attrs = <(String, String?)>[];
    final Match match = _tagfindTolerant.matchAsPrefix(raw, i + 1)!;
    int k = match.end;
    final String tag = match.group(1)!.toLowerCase();
    while (k < endpos) {
      final Match? m = _attrfindTolerant.matchAsPrefix(raw, k);
      if (m == null) break;
      final String name = m.group(1)!;
      final String? rest = m.group(2);
      String? value = m.group(3);
      if (rest == null || rest.isEmpty) {
        value = null;
      } else if (value != null &&
          value.length >= 2 &&
          ((value.startsWith("'") && value.endsWith("'")) ||
              (value.startsWith('"') && value.endsWith('"')))) {
        value = value.substring(1, value.length - 1);
      } else if (value != null && (value == "'" || value == '"')) {
        // A lone quote: Python's slicing leaves it as is.
      }
      if (value != null && value.isNotEmpty) value = unescape(value);
      attrs.add((name.toLowerCase(), value));
      k = m.end;
    }
    final String end = raw.substring(k, endpos).trim();
    if (end != '>' && end != '/>') {
      handleData(raw.substring(i, endpos));
      return endpos;
    }
    if (end.endsWith('/>')) {
      handleStartendtag(tag, attrs);
    } else {
      handleStarttag(tag, attrs);
      if (tag == 'script' || tag == 'style') {
        _cdataElem = tag;
        _interestingCdata = pyRe('</\\s*$tag\\s*>', ignoreCase: true);
      }
    }
    return endpos;
  }

  int _parseEndtag(int i) {
    final String raw = _raw;
    final int gt = raw.indexOf('>', i + 1);
    if (gt < 0) return -1;
    final int gtpos = gt + 1;
    final Match? match = _endtagfind.matchAsPrefix(raw, i);
    if (match == null || match.end != gtpos) {
      if (_cdataElem != null) {
        handleData(raw.substring(i, gtpos));
        return gtpos;
      }
      final Match? name = _tagfindTolerant.matchAsPrefix(raw, i + 2);
      if (name == null) {
        if (raw.startsWith('</>', i)) return i + 3;
        final int pos = raw.indexOf('>', i + 2);
        return pos < 0 ? -1 : pos + 1;
      }
      final String tag = name.group(1)!.toLowerCase();
      final int close = raw.indexOf('>', name.end);
      handleEndtag(tag);
      return close + 1;
    }
    final String elem = match.group(1)!.toLowerCase();
    if (_cdataElem != null && elem != _cdataElem) {
      handleData(raw.substring(i, gtpos));
      return gtpos;
    }
    handleEndtag(elem);
    _cdataElem = null;
    _interestingCdata = null;
    return gtpos;
  }

  int _parseComment(int i) {
    final RegExpMatch? m = _first(_commentclose, _raw, i + 4);
    return m == null ? -1 : m.end;
  }

  int _parseHtmlDeclaration(int i) {
    final String raw = _raw;
    if (raw.startsWith('<!--', i)) return _parseComment(i);
    if (raw.startsWith('<![', i)) {
      final Match? name = _declname.matchAsPrefix(raw, i + 3);
      final String sect =
          name == null ? '' : name.group(0)!.trim().toLowerCase();
      final RegExp close =
          const <String>[
                'temp',
                'cdata',
                'ignore',
                'include',
                'rcdata',
              ].contains(sect)
              ? _markedsectionclose
              : _msmarkedsectionclose;
      final RegExpMatch? m = _first(close, raw, i + 3);
      return m == null ? -1 : m.end;
    }
    if (raw.length >= i + 9 &&
        raw.substring(i, i + 9).toLowerCase() == '<!doctype') {
      final int gt = raw.indexOf('>', i + 9);
      return gt < 0 ? -1 : gt + 1;
    }
    final int pos = raw.indexOf('>', i + 2);
    return pos < 0 ? -1 : pos + 1;
  }
}
