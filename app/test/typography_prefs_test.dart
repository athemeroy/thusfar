import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/prefs.dart';
import 'package:thusfar_app/reader/paginator.dart';

void main() {
  test('older spacing survives and precise reading metrics persist', () {
    final Directory temp = Directory.systemTemp.createTempSync('type-prefs-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final File file = File('${temp.path}/app-prefs.json');
    file.writeAsStringSync('{"spacing":2,"fontSize":19}');

    final Prefs prefs = Prefs(file);
    expect(prefs.lineHeight, 2.1);
    expect(prefs.letterSpacing, 0);
    expect(prefs.pageHorizontalMargin, 20);
    expect(prefs.pageVerticalMargin, 16);

    prefs.update((Prefs p) {
      p.fontSize = 23.5;
      p.lineHeightOverride = 1.75;
      p.letterSpacing = 0.6;
      p.pageHorizontalMargin = 44;
      p.pageVerticalMargin = 26;
    });

    final Prefs restored = Prefs(file);
    expect(restored.fontSize, 23.5);
    expect(restored.lineHeight, 1.75);
    expect(restored.letterSpacing, 0.6);
    expect(restored.pageHorizontalMargin, 44);
    expect(restored.pageVerticalMargin, 26);
  });

  test('letter spacing participates in page layout identity', () {
    const PageSpec plain = PageSpec(
      width: 420,
      height: 760,
      fontSize: 19,
      lineHeight: 1.85,
      fontFamily: 'NotoSerifSC',
      color: Color(0xff222222),
      textScaler: TextScaler.noScaling,
    );
    const PageSpec spaced = PageSpec(
      width: 420,
      height: 760,
      fontSize: 19,
      lineHeight: 1.85,
      letterSpacing: 0.6,
      fontFamily: 'NotoSerifSC',
      color: Color(0xff222222),
      textScaler: TextScaler.noScaling,
    );
    expect(plain, isNot(spaced));
    expect(spaced.body.letterSpacing, 0.6);
  });
}
