import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyEvent, KeyUpEvent, LogicalKeyboardKey;
import 'package:thusfar_core/thusfar_core.dart' as knowledge;
import 'package:thusfar_core/chapter_verdicts.dart' show titleCheckPending;

import '../data/library_zip.dart';
import '../ui/theme.dart';



class _WebCover extends StatelessWidget {
  const _WebCover({
    required this.title,
    required this.id,
    this.compact = false,
  });

  final String title;
  final String id;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    const List<Color> colors = <Color>[
      Color(0xFF6D4A3A),
      Color(0xFF35507A),
      Color(0xFF4F7A5A),
      Color(0xFF8A5A2B),
      Color(0xFF3D5D6B),
    ];
    final int color =
        id.codeUnits.fold<int>(0, (int a, int b) => a + b) % colors.length;
    return Container(
      width: compact ? 72 : 100,
      height: compact ? 104 : 138,
      padding: const EdgeInsets.fromLTRB(13, 17, 13, 13),
      decoration: BoxDecoration(
        color: colors[color],
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(3),
          bottomLeft: Radius.circular(3),
          topRight: Radius.circular(9),
          bottomRight: Radius.circular(9),
        ),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x30000000),
            blurRadius: 7,
            offset: Offset(1, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: display,
                color: Color(0xFFF6EDE2),
                fontSize: 15,
                height: 1.3,
              ),
            ),
          ),
          Container(height: 1, color: const Color(0x99FFFFFF)),
        ],
      ),
    );
  }
}


class _WebPageFragment {
  const _WebPageFragment({
    required this.block,
    required this.kind,
    required this.startLine,
    required this.lines,
    required this.height,
    this.text = '',
    this.sourceStart = 0,
    this.sourceEnd = 0,
  });

  final int block;
  final String kind;
  final int startLine;
  final int lines;
  final double height;
  final String text;

  /// Offsets in the original block, excluding the reader's visual indent.
  final int sourceStart;
  final int sourceEnd;
}


class _WebPersonMention {
  const _WebPersonMention(this.start, this.end, this.id);

  final int start;
  final int end;
  final String id;
}


class _WebPersonLink {
  const _WebPersonLink(this.start, this.end, this.name, this.id);

  final int start;
  final int end;
  final String name;
  final String? id;
}


class WebReaderPrefs {
  WebReaderPrefs() {
    try {
      final String? raw = html.window.localStorage['thusfar-web-prefs'];
      if (raw == null) return;
      final Json json = jsonDecode(raw) as Json;
      fontSize = ((json['fontSize'] as num?)?.toDouble() ?? 21).clamp(
        14.0,
        34.0,
      );
      lineHeight = ((json['lineHeight'] as num?)?.toDouble() ?? 1.75).clamp(
        1.2,
        2.4,
      );
      letterSpacing = ((json['letterSpacing'] as num?)?.toDouble() ?? 0).clamp(
        -0.5,
        2.5,
      );
      margin = ((json['margin'] as num?)?.toDouble() ?? 24).clamp(8.0, 90.0);
      columnWidth = ((json['columnWidth'] as num?)?.toDouble() ?? 640).clamp(
        520.0,
        1400.0,
      );
      paper = ((json['paper'] as num?)?.toInt() ?? 0).clamp(
        0,
        Tokens.paperColors.length - 1,
      );
      font = ((json['font'] as num?)?.toInt() ?? 0).clamp(0, 2);
      pageMode = json['pageMode'] is bool ? json['pageMode'] as bool : true;
    } on Object {
      // A malformed preference must never prevent the book from opening.
    }
  }

  double fontSize = 21;
  double lineHeight = 1.75;
  double letterSpacing = 0;
  double margin = 24;
  double columnWidth = 640;
  int paper = 0;
  int font = 0;
  bool pageMode = true;

  Color get paperColor => Tokens.paperColors[paper].$2;
  bool get dark => paper == Tokens.paperColors.length - 1;
  Color get ink => dark ? Tokens.night.ink : Tokens.light.ink;
  Color get muted => dark ? Tokens.night.ink2 : Tokens.light.ink2;
  String get family =>
      const <String>['NotoSerifSC', 'LXGWWenKaiScreen', 'NotoSansSC'][font];

  void save() {
    html.window.localStorage['thusfar-web-prefs'] =
        jsonEncode(<String, Object?>{
          'fontSize': fontSize,
          'lineHeight': lineHeight,
          'letterSpacing': letterSpacing,
          'margin': margin,
          'columnWidth': columnWidth,
          'paper': paper,
          'font': font,
          'pageMode': pageMode,
        });
  }
}

