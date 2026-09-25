/// EPUB reading (`parse.py` DocParser, `_toc`, `parse_epub`, `_cover`).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:xml/xml.dart';

import '../errors.dart';
import '../py/py_compat.dart';
import '../py/py_re.dart';
import 'html_parser.dart';
import 'parse.dart';

const int maxEpubMembers = 20000;
const int maxEpubMemberBytes = 32 * 1024 * 1024;
const int maxEpubExpandedBytes = 512 * 1024 * 1024;
const Set<String> blockTags = <String>{
  'p', 'div', 'section', 'article', 'li', 'blockquote', 'tr', 'dd', 'dt', //
  'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'pre', 'figcaption', 'caption',
};
const Set<String> skipTags = <String>{
  'head',
  'title',
  'script',
  'style',
  'template',
  'noscript',
  'iframe',
  'object',
  'embed',
  'svg',
  'rt',
  'rp',
};
const Set<String> voidTags = <String>{
  'br',
  'hr',
  'img',
  'meta',
  'link',
  'input',
  'source',
  'wbr',
  'area',
  'base',
  'col',
  'param',
  'image',
};

/// `html.escape(s, quote=True)`.
String htmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#x27;');

String _local(String name) {
  final int i = name.lastIndexOf('}');
  final String s = i >= 0 ? name.substring(i + 1) : name;
  final int c = s.indexOf(':');
  return c >= 0 ? s.substring(c + 1) : s;
}

/// ElementTree `.text`: text before the first child element.
String? etText(XmlElement e) {
  final StringBuffer out = StringBuffer();
  bool any = false;
  for (final XmlNode n in e.children) {
    if (n is XmlElement) break;
    if (n is XmlText || n is XmlCDATA) {
      out.write(n.value);
      any = true;
    }
  }
  return any ? out.toString() : null;
}

/// ElementTree `.tail`: text after [e] up to its next sibling element.
String? etTail(XmlElement e) {
  final XmlNode? parent = e.parent;
  if (parent == null) return null;
  final List<XmlNode> siblings = parent.children;
  final StringBuffer out = StringBuffer();
  bool any = false;
  for (int i = siblings.indexOf(e) + 1; i < siblings.length; i++) {
    final XmlNode n = siblings[i];
    if (n is XmlElement) break;
    if (n is XmlText || n is XmlCDATA) {
      out.write(n.value);
      any = true;
    }
  }
  return any ? out.toString() : null;
}

/// ElementTree `itertext()`.
String itertext(XmlElement e) {
  final StringBuffer out = StringBuffer();
  for (final XmlNode n in e.descendants) {
    if (n is XmlText || n is XmlCDATA) out.write(n.value);
  }
  return out.toString();
}

/// ElementTree `iter()`: the element and every descendant element.
Iterable<XmlElement> etIter(XmlElement e) sync* {
  yield e;
  yield* e.descendants.whereType<XmlElement>();
}

String? _attr(XmlElement e, String name) {
  for (final XmlAttribute a in e.attributes) {
    if (a.name.qualified == name) return a.value;
  }
  return null;
}

String? _nsAttr(XmlElement e, String ns, String local) {
  for (final XmlAttribute a in e.attributes) {
    if (a.name.local == local && a.name.namespaceUri == ns) return a.value;
  }
  return null;
}

final RegExp _tags = pyRe(r'<[^>]+>');

String mathText(String source) {
  final XmlElement root;
  try {
    root = XmlDocument.parse(source).rootElement;
  } on Object {
    final String t = clean(pySub(_tags, unescape(source), ''));
    return t.isNotEmpty ? t : '［公式格式无法解析］';
  }
  final String? accessible =
      _attr(root, 'alttext') ?? _attr(root, 'aria-label');
  if (accessible != null && accessible.isNotEmpty) return accessible;
  if (_local(root.name.qualified) == 'svg') {
    final List<String> labels = <String>[];
    for (final XmlElement node in etIter(root)) {
      if (const <String>[
        'title',
        'desc',
        'text',
      ].contains(_local(node.name.qualified))) {
        final String l = clean(itertext(node));
        if (l.isNotEmpty && !labels.contains(l)) labels.add(l);
      }
    }
    final String readable = labels.join('；');
    return readable.isNotEmpty ? '［图形：$readable］' : '［图形缺少可读取文本］';
  }
  String render(XmlElement node) {
    final String tag = _local(node.name.qualified);
    final List<XmlElement> children = node.childElements.toList();
    final List<String> parts = <String>[
      for (final XmlElement c in children) render(c),
    ];
    if (tag == 'annotation' || tag == 'annotation-xml') return '';
    if (tag == 'mfrac' && parts.length == 2)
      return '(${parts[0]})/(${parts[1]})';
    if ((tag == 'msup' || tag == 'msub') && parts.length == 2)
      return '(${parts[0]})${tag == 'msup' ? '^' : '_'}(${parts[1]})';
    if (tag == 'msubsup' && parts.length == 3)
      return '(${parts[0]})_(${parts[1]})^(${parts[2]})';
    if (tag == 'msqrt' || tag == 'mroot') return 'sqrt(${parts.join(',')})';
    final StringBuffer out = StringBuffer(etText(node) ?? '');
    for (int i = 0; i < children.length; i++) {
      out
        ..write(parts[i])
        ..write(etTail(children[i]) ?? '');
    }
    return out.toString();
  }

  final String t = clean(render(root));
  return t.isNotEmpty ? t : '［公式缺少可读取文本］';
}

final RegExp _displayNone = pyRe(r'display\s*:\s*none', ignoreCase: true);
final RegExp _heading = pyRe(r'h[1-6]');
final RegExp _noteLabel = pyRe(
  r'[\[\(（〔【]?\s*(?:注)?\d{1,3}\s*[\]\)）〕】]?|[*†‡]+',
);

String _lstrip(String s, String chars) {
  int i = 0;
  while (i < s.length && chars.contains(s[i])) {
    i++;
  }
  return s.substring(i);
}

/// Collects the blocks of one XHTML document, remembering anchors and notes.
class DocParser extends PyHtmlParser {
  DocParser(this.doc);

  final String doc;
  final List<Json> blocks = <Json>[];
  Json? cur;
  List<String> buf = <String>[];
  int skip = 0;
  final List<(String, bool)> stack = <(String, bool)>[];
  List<String> pendingIds = <String>[];
  Json? ref;
  int mathDepth = 0;
  List<String> mathParts = <String>[];

  void _flush() {
    final Json? c = cur;
    if (c == null) return;
    final String raw = buf.join();
    final String text = clean(raw);
    final List<Object?> fn = <Object?>[];
    final List<(int, String)> fnRaw = c['fn_raw']! as List<(int, String)>;
    if (fnRaw.isNotEmpty) {
      final int lead = raw.length - _lstrip(raw, ' \t\r\n 　').length;
      for (final (int off, String target) in fnRaw) {
        final String prefix = off > lead ? clean(raw.substring(0, off)) : '';
        fn.add(<Object?>[u16(prefix), target]);
      }
    }
    if (text.isNotEmpty || (c['ids']! as List<String>).isNotEmpty) {
      blocks.add(<String, Object?>{
        'k': c['k'],
        't': text,
        'ids': c['ids'],
        'fn': fn,
        'cls': c['cls'],
      });
    }
    cur = null;
    buf = <String>[];
  }

  void _start(String kind, String? cls) {
    _flush();
    cur = <String, Object?>{
      'k': kind,
      'ids': pendingIds,
      'fn_raw': <(int, String)>[],
      'cls': cls,
    };
    pendingIds = <String>[];
  }

  @override
  void handleStarttag(String tag, List<(String, String?)> attrs) {
    final Map<String, String?> a = <String, String?>{
      for (final (String k, String? v) in attrs) k: v,
    };
    if (mathDepth > 0 ||
        ((tag == 'math' || tag == 'svg') &&
            skip == 0 &&
            a['aria-hidden'] != 'true')) {
      mathDepth++;
      mathParts.add(getStarttagText()!);
      return;
    }
    final bool hidden =
        skipTags.contains(tag) ||
        a.containsKey('hidden') ||
        a['aria-hidden'] == 'true' ||
        pySearch(_displayNone, a['style'] ?? '') != null;
    if (!voidTags.contains(tag)) {
      stack.add((tag, hidden));
      if (hidden) skip++;
    }
    if (skip > 0) return;
    final String? id = a['id'];
    if (id != null && id.isNotEmpty) {
      if (cur != null) {
        (cur!['ids']! as List<String>).add(id);
      } else {
        pendingIds.add(id);
      }
    }
    if (blockTags.contains(tag)) {
      final String kind = pyFullmatch(_heading, tag) != null ? 'h' : 'p';
      _start(kind, a['class']);
      if (kind == 'h') cur!['level'] = int.parse(tag.substring(1));
    } else if (tag == 'br') {
      if (cur != null && PyCompat.strip(buf.join()).isNotEmpty) {
        _start(cur!['k']! as String, cur!['cls'] as String?);
      }
    } else if (tag == 'img' || tag == 'image') {
      final String? src =
          _nonEmpty(a['src']) ??
          _nonEmpty(a['xlink:href']) ??
          _nonEmpty(a['href']);
      if (src != null) {
        _flush();
        blocks.add(<String, Object?>{
          'k': 'img',
          't': '',
          'src': src,
          'alt': a['alt'] ?? '',
          'ids': pendingIds,
          'fn': <Object?>[],
        });
        pendingIds = <String>[];
      }
    } else if (tag == 'a' && (a['href'] ?? '').contains('#')) {
      ref = <String, Object?>{
        'href': a['href'],
        'text': '',
        'raw_at': buf.join().length,
      };
    } else if (tag == 'sup' && ref != null) {
      ref!['sup'] = true;
    }
  }

  static String? _nonEmpty(String? s) => s == null || s.isEmpty ? null : s;

  @override
  void handleEndtag(String tag) {
    if (mathDepth > 0) {
      mathParts.add('</$tag>');
      mathDepth--;
      if (mathDepth == 0) {
        final String value = mathText(mathParts.join());
        mathParts = <String>[];
        handleData(' $value ');
      }
      return;
    }
    for (int i = stack.length - 1; i >= 0; i--) {
      if (stack[i].$1 == tag) {
        for (int j = i; j < stack.length; j++) {
          if (stack[j].$2) skip--;
        }
        stack.removeRange(i, stack.length);
        break;
      }
    }
    if (skip > 0) return;
    if (tag == 'a' && ref != null) {
      final Json r = ref!;
      ref = null;
      final String label = PyCompat.strip(r['text']! as String);
      final bool isNote =
          r['sup'] == true || pyFullmatch(_noteLabel, label) != null;
      if (isNote && cur != null) {
        final String joined = buf.join();
        final int start = r['raw_at']! as int;
        buf = <String>[
          joined.substring(0, start < joined.length ? start : joined.length),
        ];
        (cur!['fn_raw']! as List<(int, String)>).add((
          start,
          r['href']! as String,
        ));
      }
      return;
    }
    if (blockTags.contains(tag)) _flush();
  }

  @override
  void handleStartendtag(String tag, List<(String, String?)> attrs) {
    final Map<String, String?> a = <String, String?>{
      for (final (String k, String? v) in attrs) k: v,
    };
    if (mathDepth > 0) {
      mathParts.add(getStarttagText()!);
    } else if ((tag == 'math' || tag == 'svg') &&
        skip == 0 &&
        a['aria-hidden'] != 'true') {
      handleData(' ${mathText(getStarttagText()!)} ');
    } else {
      super.handleStartendtag(tag, attrs);
    }
  }

  @override
  void handleData(String data) {
    if (mathDepth > 0) {
      mathParts.add(htmlEscape(data));
      return;
    }
    if (skip > 0) return;
    if (ref != null) ref!['text'] = '${ref!['text']}$data';
    if (cur == null) {
      if (PyCompat.strip(data).isEmpty) return;
      _start('p', null);
    }
    buf.add(data);
  }

  void close() {
    if (mathDepth > 0) {
      mathDepth = 0;
      handleData('［未闭合公式或图形］${mathText(mathParts.join())}');
      mathParts = <String>[];
    }
    _flush();
  }
}

// ---------------------------------------------------------------- paths

/// `posixpath.normpath`.
String normpath(String path) {
  if (path.isEmpty) return '.';
  final bool abs = path.startsWith('/');
  final List<String> out = <String>[];
  for (final String part in path.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..' && (out.isNotEmpty && out.last != '..')) {
      out.removeLast();
    } else if (part == '..' && abs) {
      continue;
    } else {
      out.add(part);
    }
  }
  final String joined = out.join('/');
  final String result = abs ? '/$joined' : joined;
  return result.isEmpty ? '.' : result;
}

String dirname(String p) {
  final int i = p.lastIndexOf('/');
  if (i < 0) return '';
  String head = p.substring(0, i + 1);
  if (head.isNotEmpty && head != '/' * head.length)
    head = head.replaceFirst(RegExp(r'/+$'), '');
  return head;
}

String _join(String a, String b) {
  if (b.startsWith('/')) return b;
  if (a.isEmpty || a.endsWith('/')) return '$a$b';
  return '$a/$b';
}

final RegExp _scheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*:');

/// `_ref(base, href)`: (path inside the zip, fragment), or ('', '') for URLs.
(String, String) resolveRef(String base, String href) {
  String rest = href;
  String scheme = '';
  final RegExpMatch? m = _scheme.firstMatch(rest);
  if (m != null) {
    scheme = m.group(0)!;
    rest = rest.substring(scheme.length);
  }
  String netloc = '';
  if (rest.startsWith('//')) {
    final int end = rest.indexOf(RegExp(r'[/?#]'), 2);
    netloc = end < 0 ? rest.substring(2) : rest.substring(2, end);
    rest = end < 0 ? '' : rest.substring(end);
  }
  String fragment = '';
  final int hash = rest.indexOf('#');
  if (hash >= 0) {
    fragment = rest.substring(hash + 1);
    rest = rest.substring(0, hash);
  }
  final int q = rest.indexOf('?');
  if (q >= 0) rest = rest.substring(0, q);
  if (scheme.isNotEmpty || netloc.isNotEmpty) return ('', '');
  final String path =
      rest.isNotEmpty ? normpath(_join(base, _unquote(rest))) : '';
  return (path, fragment);
}

String _unquote(String s) {
  if (!s.contains('%')) return s;
  final List<int> bytes = <int>[];
  final StringBuffer out = StringBuffer();
  void flush() {
    if (bytes.isNotEmpty) {
      out.write(utf8.decode(bytes, allowMalformed: true));
      bytes.clear();
    }
  }

  for (int i = 0; i < s.length; i++) {
    if (s[i] == '%' &&
        i + 2 < s.length &&
        RegExp(r'^[0-9a-fA-F]{2}$').hasMatch(s.substring(i + 1, i + 3))) {
      bytes.add(int.parse(s.substring(i + 1, i + 3), radix: 16));
      i += 2;
    } else {
      flush();
      out.write(s[i]);
    }
  }
  flush();
  return out.toString();
}

String _suffix(String path) {
  final String name = path.substring(path.lastIndexOf('/') + 1);
  final int dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot);
}

// ---------------------------------------------------------------- EPUB

final RegExp _doctype = RegExp(r'<!DOCTYPE[^>]*>');

XmlElement _xml(Uint8List raw) {
  String text = utf8.decode(raw, allowMalformed: true);
  if (text.startsWith('﻿')) text = text.substring(1);
  text = text.replaceAll(_doctype, '');
  if (text.toUpperCase().contains('<!ENTITY'))
    throw const ValueError('电子书 XML 含有不允许的实体声明。');
  return XmlDocument.parse(text).rootElement;
}

class _Zip {
  _Zip(this.archive) {
    for (final ArchiveFile f in archive.files) {
      if (f.isFile) byName[f.name] = f;
    }
  }

  final Archive archive;
  final Map<String, ArchiveFile> byName = <String, ArchiveFile>{};

  Set<String> get names => byName.keys.toSet();

  Uint8List read(String name) {
    final ArchiveFile? f = byName[name];
    if (f == null)
      throw ValueError("There is no item named '$name' in the archive");
    return f.content;
  }
}

List<Json> _toc(
  _Zip z,
  XmlElement opf,
  String opfDir,
  Map<String, XmlElement> manifest,
) {
  final List<Json> out = <Json>[];
  XmlElement? nav;
  for (final XmlElement it in manifest.values) {
    if ((_attr(it, 'properties') ?? '').split(RegExp(r'\s+')).contains('nav')) {
      nav = it;
      break;
    }
  }
  if (nav != null) {
    final (String path, _) = resolveRef(opfDir, _attr(nav, 'href') ?? '');
    final String base = dirname(path);
    try {
      final XmlElement root = _xml(z.read(path));
      for (final XmlElement navel in etIter(root)) {
        if (_local(navel.name.qualified) != 'nav') continue;
        final String kind =
            _nsAttr(navel, 'http://www.idpf.org/2007/ops', 'type') ??
            _attr(navel, 'epub:type') ??
            '';
        if (kind.isNotEmpty && kind != 'toc') continue;
        void walk(XmlElement ol, int depth) {
          for (final XmlElement li in ol.childElements) {
            if (_local(li.name.qualified) != 'li') continue;
            XmlElement? a;
            for (final XmlElement x in li.childElements) {
              if (const <String>[
                'a',
                'span',
              ].contains(_local(x.name.qualified))) {
                a = x;
                break;
              }
            }
            if (a != null) {
              final String title = clean(itertext(a));
              final (String doc, String frag) = resolveRef(
                base,
                _attr(a, 'href') ?? '',
              );
              if (title.isNotEmpty && doc.isNotEmpty)
                out.add(<String, Object?>{
                  'title': title,
                  'depth': depth,
                  'doc': doc,
                  'frag': frag,
                });
            }
            for (final XmlElement sub in li.childElements) {
              if (_local(sub.name.qualified) == 'ol') walk(sub, depth + 1);
            }
          }
        }

        for (final XmlElement ol in navel.childElements) {
          if (_local(ol.name.qualified) == 'ol') walk(ol, 0);
        }
        if (out.isNotEmpty) return out;
      }
    } on Object {
      out.clear();
    }
  }
  XmlElement? spine;
  for (final XmlElement n in etIter(opf)) {
    if (_local(n.name.qualified) == 'spine') {
      spine = n;
      break;
    }
  }
  final String? ncxId = spine == null ? null : _attr(spine, 'toc');
  XmlElement? ncx = ncxId != null && ncxId.isNotEmpty ? manifest[ncxId] : null;
  if (ncx == null) {
    for (final XmlElement it in manifest.values) {
      if ((_attr(it, 'media-type') ?? '').endsWith('dtbncx+xml')) {
        ncx = it;
        break;
      }
    }
  }
  if (ncx == null) return out;
  final (String path, _) = resolveRef(opfDir, _attr(ncx, 'href') ?? '');
  final String base = dirname(path);
  final XmlElement root = _xml(z.read(path));
  void walk(XmlElement node, int depth) {
    for (final XmlElement np in node.childElements) {
      if (_local(np.name.qualified) != 'navPoint') continue;
      XmlElement? label;
      for (final XmlElement x in etIter(np)) {
        if (_local(x.name.qualified) == 'text') {
          label = x;
          break;
        }
      }
      XmlElement? content;
      for (final XmlElement x in np.childElements) {
        if (_local(x.name.qualified) == 'content') {
          content = x;
          break;
        }
      }
      final String title = label != null ? clean(etText(label) ?? '') : '';
      if (content != null && title.isNotEmpty) {
        final (String doc, String frag) = resolveRef(
          base,
          _attr(content, 'src') ?? '',
        );
        out.add(<String, Object?>{
          'title': title,
          'depth': depth,
          'doc': doc,
          'frag': frag,
        });
      }
      walk(np, depth + 1);
    }
  }

  for (final XmlElement x in etIter(root)) {
    if (_local(x.name.qualified) == 'navMap') {
      walk(x, 0);
      break;
    }
  }
  return out;
}

/// Where images go: `(name, bytes)` is written to `<book>/img/<name>`.
typedef SaveImage = void Function(String name, Uint8List data);

final RegExp _noteNumber = pyRe(r'^[\[\(（〔【]?\d{1,3}[\]\)）〕】]?\s*');

Json parseEpub(Uint8List bytes, String stem, SaveImage save) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } on Object {
    throw const ValueError('不是有效的 EPUB 文件。');
  }
  final List<ArchiveFile> entries =
      archive.files.where((ArchiveFile f) => f.isFile).toList();
  int expanded = 0;
  for (final ArchiveFile e in entries) {
    expanded += e.size;
  }
  if (entries.length > maxEpubMembers ||
      expanded > maxEpubExpandedBytes ||
      entries.any((ArchiveFile e) => e.size > maxEpubMemberBytes)) {
    throw const ValueError('EPUB 解压规模超过限制，请拆分文件后导入。');
  }
  if (entries.map((ArchiveFile e) => e.name).toSet().length != entries.length) {
    throw const ValueError('EPUB 包含重复文件名，无法可靠解析。');
  }
  final _Zip z = _Zip(archive);
  final Set<String> names = z.names;
  if (names.contains('META-INF/encryption.xml'))
    throw const ValueError('此 EPUB 有 DRM 加密，无法读取。');
  final XmlElement container = _xml(z.read('META-INF/container.xml'));
  String? opfPath;
  for (final XmlElement n in etIter(container)) {
    if (_local(n.name.qualified) == 'rootfile') {
      opfPath = _attr(n, 'full-path');
      break;
    }
  }
  if (opfPath == null) throw const ValueError('EPUB 缺少 OPF 文件。');
  final XmlElement opf = _xml(z.read(opfPath));
  final String opfDir = dirname(opfPath);
  final Map<String, String> meta = <String, String>{};
  for (final XmlElement n in etIter(opf)) {
    final String t = _local(n.name.qualified);
    final String? text = etText(n);
    if ((t == 'title' || t == 'creator') &&
        text != null &&
        text.isNotEmpty &&
        !meta.containsKey(t))
      meta[t] = clean(text);
  }
  final Map<String, XmlElement> manifest = <String, XmlElement>{};
  for (final XmlElement n in etIter(opf)) {
    if (_local(n.name.qualified) == 'item') manifest[_attr(n, 'id') ?? ''] = n;
  }
  final List<XmlElement> spine = <XmlElement>[
    for (final XmlElement n in etIter(opf))
      if (_local(n.name.qualified) == 'itemref' &&
          manifest.containsKey(_attr(n, 'idref')))
        manifest[_attr(n, 'idref')]!,
  ];
  final List<Json> toc = _toc(z, opf, opfDir, manifest);

  final List<(String, List<Json>)> docs = <(String, List<Json>)>[];
  int parsedChars = 0;
  for (final XmlElement item in spine) {
    final (String doc, _) = resolveRef(opfDir, _attr(item, 'href') ?? '');
    if (doc.isEmpty || !names.contains(doc)) continue;
    final String media = _attr(item, 'media-type') ?? '';
    if (!media.contains('html') &&
        !doc.endsWith('.html') &&
        !doc.endsWith('.htm') &&
        !doc.endsWith('.xhtml'))
      continue;
    final DocParser p = DocParser(doc);
    String text = utf8.decode(z.read(doc), allowMalformed: true);
    if (text.startsWith('﻿')) text = text.substring(1);
    p
      ..feedAll(text)
      ..close();
    for (final Json b in p.blocks) {
      parsedChars += cpLen(b['t']! as String);
    }
    if (parsedChars > maxChars) throw const ValueError('EPUB 正文超过字符限制，请拆分后导入。');
    final String base = dirname(doc);
    for (final Json b in p.blocks) {
      b['fn'] = <Object?>[
        for (final Object? f in b['fn']! as List<Object?>)
          _resolveFn(base, doc, f! as List<Object?>),
      ];
    }
    docs.add((doc, p.blocks));
  }
  final List<(String, Json)> seq = <(String, Json)>[
    for (final (String doc, List<Json> bl) in docs)
      for (final Json b in bl) (doc, b),
  ];
  final Map<String, int> firstRef = <String, int>{};
  for (int i = 0; i < seq.length; i++) {
    for (final Object? f in seq[i].$2['fn']! as List<Object?>) {
      final (String, String) tgt =
          (f! as List<Object?>)[1]! as (String, String);
      firstRef.putIfAbsent('${tgt.$1}\u0000${tgt.$2}', () => i);
    }
  }
  final Map<String, String> notes = <String, String>{};
  final Set<int> noteBlocks = <int>{};
  for (int i = 0; i < seq.length; i++) {
    final (String doc, Json b) = seq[i];
    if (b['k'] != 'p') continue;
    String? hit;
    for (final String x in (b['ids'] as List<String>?) ?? const <String>[]) {
      if ((firstRef['$doc\u0000$x'] ?? i) < i) {
        hit = x;
        break;
      }
    }
    if (hit != null) {
      notes['$doc#$hit'] = pySub(_noteNumber, b['t']! as String, '');
      noteBlocks.add(i);
    }
  }
  final List<Json> blocks = <Json>[];
  final Map<String, int> docFirst = <String, int>{};
  final Map<String, int> anchors = <String, int>{};
  final Map<String, String> images = <String, String>{};
  for (int i = 0; i < seq.length; i++) {
    final (String doc, Json b) = seq[i];
    docFirst.putIfAbsent(doc, () => blocks.length);
    if (noteBlocks.contains(i)) continue;
    final int idx = blocks.length;
    for (final String x
        in (b.remove('ids') as List<String>?) ?? const <String>[]) {
      anchors.putIfAbsent('$doc\u0000$x', () => idx);
    }
    final List<Object?> kept = <Object?>[];
    for (final Object? raw in b['fn']! as List<Object?>) {
      final List<Object?> f = raw! as List<Object?>;
      if (notes.containsKey(_key(f))) kept.add(<Object?>[f[0], _key(f)]);
    }
    b['fn'] = kept;
    if (b['k'] == 'img') {
      final (String ipath, _) = resolveRef(dirname(doc), b['src']! as String);
      if (names.contains(ipath)) {
        if (!images.containsKey(ipath)) {
          final Uint8List data = z.read(ipath);
          if (data.length > 1500) {
            final String suffix = _suffix(ipath).toLowerCase();
            final String name =
                crypto.sha1
                    .convert(utf8.encode(ipath))
                    .toString()
                    .substring(0, 12) +
                (suffix.isEmpty ? '.jpg' : suffix);
            save(name, data);
            images[ipath] = name;
          } else {
            images[ipath] = '';
          }
        }
        if (images[ipath]!.isNotEmpty) {
          blocks.add(<String, Object?>{
            'k': 'img',
            't': '',
            'src': images[ipath],
            'alt': b['alt'] ?? '',
          });
        }
      }
      continue;
    }
    if ((b['t']! as String).isEmpty) continue;
    blocks.add(b);
  }
  final List<(int, String, int)> starts = <(int, String, int)>[];
  for (final Json e in toc) {
    final String frag = e['frag']! as String;
    int? idx = frag.isNotEmpty ? anchors['${e['doc']}\u0000$frag'] : null;
    idx ??= docFirst[e['doc']];
    if (idx == null) continue;
    starts.add((idx, e['title']! as String, e['depth']! as int));
  }
  final String? cover = _cover(z, opf, opfDir, manifest, names, save);
  final Json book = finish(
    blocks,
    starts,
    notes,
    meta['title'] ?? stem,
    meta['creator'] ?? '',
  );
  final StringBuffer sample = StringBuffer();
  int remaining = 200000;
  for (final Json block in blocks) {
    if (remaining <= 0) break;
    final String part = cpPrefix(block['t']! as String, remaining);
    sample.write(part);
    remaining -= cpLen(part);
  }
  book['lang'] = detectLang(sample.toString());
  if (cover != null) book['cover'] = cover;
  return book;
}

List<Object?> _resolveFn(String base, String doc, List<Object?> f) {
  final (String path, String frag) = resolveRef(base, f[1]! as String);
  return <Object?>[f[0], (path.isEmpty ? doc : path, frag)];
}

String _key(List<Object?> f) {
  final (String a, String b) = f[1]! as (String, String);
  return '$a#$b';
}

String? _cover(
  _Zip z,
  XmlElement opf,
  String opfDir,
  Map<String, XmlElement> manifest,
  Set<String> names,
  SaveImage save,
) {
  XmlElement? item;
  for (final XmlElement n in etIter(opf)) {
    if (_local(n.name.qualified) == 'meta' &&
        _attr(n, 'name') == 'cover' &&
        manifest.containsKey(_attr(n, 'content'))) {
      item = manifest[_attr(n, 'content')];
    }
  }
  if (item == null) {
    for (final XmlElement it in manifest.values) {
      if ((_attr(it, 'properties') ?? '')
          .split(RegExp(r'\s+'))
          .contains('cover-image')) {
        item = it;
        break;
      }
    }
  }
  if (item == null || !(_attr(item, 'media-type') ?? '').startsWith('image/'))
    return null;
  final (String path, _) = resolveRef(opfDir, _attr(item, 'href') ?? '');
  if (!names.contains(path)) return null;
  final Uint8List data = z.read(path);
  if (data.length > 8000000) return null;
  final String suffix = _suffix(path).toLowerCase();
  final String name = 'cover${suffix.isEmpty ? '.jpg' : suffix}';
  save(name, data);
  return name;
}

/// `parse_file` for an EPUB's bytes.
Json parseEpubFile(Uint8List bytes, String stem, SaveImage save) {
  final Json book = parseEpub(bytes, stem, save);
  if (!(book['blocks']! as List<Object?>).any(
    (Object? b) => ((b! as Json)['t']! as String).isNotEmpty,
  )) {
    throw const ValueError('没有读到文字内容。');
  }
  return splitLongChapters(book);
}
