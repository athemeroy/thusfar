import 'dart:io';

import 'package:flutter/foundation.dart';

import '../reader/tap_layout.dart';
import 'library.dart';

enum PageAnim { slide, cover, none }

enum NightMode { system, always, never }

/// Reader and app preferences, stored as `app-prefs.json` next to the books.
class Prefs extends ChangeNotifier {
  Prefs(this.file) {
    final Json j = (readJson(file) as Json?) ?? <String, Object?>{};
    fontSize = _readMetric(j, 'fontSize', 19, 14, 32);
    spacing = ((j['spacing'] as num?)?.toInt() ?? 1).clamp(0, 2);
    final Object? savedLineHeight = j['lineHeight'];
    lineHeightOverride = savedLineHeight is num && savedLineHeight.isFinite
        ? savedLineHeight.toDouble().clamp(1.2, 2.4)
        : null;
    letterSpacing = _readMetric(j, 'letterSpacing', 0, -0.5, 2.5);
    paragraphSpacing = _readMetric(j, 'paragraphSpacing', 0, 0, 2);
    firstLineIndent = _readMetric(j, 'firstLineIndent', 2, 0, 4);
    pageHorizontalMargin = _readMetric(j, 'pageHorizontalMargin', 20, 8, 96);
    pageVerticalMargin = _readMetric(j, 'pageVerticalMargin', 16, 4, 48);
    font = (j['font'] as num?)?.toInt() ?? 0;
    paper = (j['paper'] as num?)?.toInt() ?? 0;
    anim = PageAnim.values[(j['anim'] as num?)?.toInt() ?? 0];
    volumeKeys = j['volumeKeys'] as bool? ?? true;
    tapLayout = ReaderTapLayout.fromJson(j['tapLayout']);
    night = NightMode.values[(j['night'] as num?)?.toInt() ?? 0];
    sort = (j['sort'] as num?)?.toInt() ?? 0;
    listView = j['listView'] as bool? ?? false;
    updateCheckedAt = (j['updateCheckedAt'] as num?)?.toInt() ?? 0;
    dismissedUpdateTag = j['dismissedUpdateTag'] as String? ?? '';
  }

  final File file;
  late double fontSize;

  /// 0 紧 · 1 中 · 2 松.
  late int spacing;

  /// Custom line height overrides the three older spacing presets.
  late double? lineHeightOverride;
  late double letterSpacing;

  /// Extra space before a paragraph in font-size units, independent of leading.
  /// Zero preserves the original reader layout for existing preferences.
  late double paragraphSpacing;

  /// First-line indent in font-size units. Two preserves the original layout.
  late double firstLineIndent;
  late double pageHorizontalMargin;
  late double pageVerticalMargin;

  /// 0 宋 · 1 楷 · 2 黑.
  late int font;
  late int paper;
  late PageAnim anim;
  late bool volumeKeys;
  late ReaderTapLayout tapLayout;
  late NightMode night;

  /// Shelf sort: 0 最近阅读 · 1 书名 · 2 阅读进度 · 3 最近加入.
  late int sort;
  late bool listView;
  late int updateCheckedAt;
  late String dismissedUpdateTag;

  double get lineHeight =>
      lineHeightOverride ?? const <double>[1.6, 1.85, 2.1][spacing];

  String? get fontFamily {
    switch (font) {
      case 0:
        return 'NotoSerifSC';
      case 1:
        return 'LXGWWenKaiScreen';
      case 2:
        return 'NotoSansSC';
      default:
        return 'NotoSerifSC';
    }
  }

  List<String> get fontFallback {
    switch (font) {
      case 0: // 宋
        return const <String>[
          'NotoSerifSC',
          'Songti SC',
          'STSong',
          'SimSun',
          'serif',
        ];
      case 1: // 楷：固定使用随应用打包的屏幕阅读版，避免设备映射成黑体。
        return const <String>['NotoSerifSC', 'serif'];
      case 2: // 黑：打包中文无衬线字体，各平台和离线阅读保持一致。
        return const <String>[
          'MiSans',
          'MiSans Normal',
          'Noto Sans CJK SC',
          'Source Han Sans SC',
          'PingFang SC',
          'Heiti SC',
          'Microsoft YaHei',
          'SimHei',
          'sans-serif',
          'NotoSerifSC',
        ];
      default:
        return const <String>['NotoSerifSC', 'serif'];
    }
  }

  void update(void Function(Prefs p) change) {
    change(this);
    writeJson(file, <String, Object?>{
      'fontSize': fontSize,
      'spacing': spacing,
      if (lineHeightOverride != null) 'lineHeight': lineHeightOverride,
      'letterSpacing': letterSpacing,
      'paragraphSpacing': paragraphSpacing,
      'firstLineIndent': firstLineIndent,
      'pageHorizontalMargin': pageHorizontalMargin,
      'pageVerticalMargin': pageVerticalMargin,
      'font': font,
      'paper': paper,
      'anim': anim.index,
      'volumeKeys': volumeKeys,
      'tapLayout': tapLayout.toJson(),
      'night': night.index,
      'sort': sort,
      'listView': listView,
      'updateCheckedAt': updateCheckedAt,
      'dismissedUpdateTag': dismissedUpdateTag,
    });
    notifyListeners();
  }
}

double _readMetric(
  Json data,
  String key,
  double fallback,
  double minimum,
  double maximum,
) {
  final Object? value = data[key];
  return value is num && value.isFinite
      ? value.toDouble().clamp(minimum, maximum)
      : fallback;
}
