import 'dart:io';

import 'package:flutter/foundation.dart';

import 'library.dart';

enum PageAnim { slide, cover, none }

enum NightMode { system, always, never }

/// Reader and app preferences, stored as `app-prefs.json` next to the books.
class Prefs extends ChangeNotifier {
  Prefs(this.file) {
    final Json j = (readJson(file) as Json?) ?? <String, Object?>{};
    fontSize = (j['fontSize'] as num?)?.toDouble() ?? 19;
    spacing = (j['spacing'] as num?)?.toInt() ?? 1;
    font = (j['font'] as num?)?.toInt() ?? 0;
    paper = (j['paper'] as num?)?.toInt() ?? 0;
    anim = PageAnim.values[(j['anim'] as num?)?.toInt() ?? 0];
    volumeKeys = j['volumeKeys'] as bool? ?? true;
    night = NightMode.values[(j['night'] as num?)?.toInt() ?? 0];
    sort = (j['sort'] as num?)?.toInt() ?? 0;
    listView = j['listView'] as bool? ?? false;
  }

  final File file;
  late double fontSize;

  /// 0 紧 · 1 中 · 2 松.
  late int spacing;

  /// 0 宋 · 1 楷 · 2 黑.
  late int font;
  late int paper;
  late PageAnim anim;
  late bool volumeKeys;
  late NightMode night;

  /// Shelf sort: 0 最近阅读 · 1 书名 · 2 阅读进度 · 3 最近加入.
  late int sort;
  late bool listView;

  double get lineHeight => const <double>[1.6, 1.85, 2.1][spacing];

  String? get fontFamily =>
      const <String?>['NotoSerifSC', 'serif', 'sans-serif'][font];

  void update(void Function(Prefs p) change) {
    change(this);
    writeJson(file, <String, Object?>{
      'fontSize': fontSize,
      'spacing': spacing,
      'font': font,
      'paper': paper,
      'anim': anim.index,
      'volumeKeys': volumeKeys,
      'night': night.index,
      'sort': sort,
      'listView': listView,
    });
    notifyListeners();
  }
}
