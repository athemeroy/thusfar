import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/main.dart';

import 'support/viewport.dart';

// Keep this separate from the screenshot-font suite: registering Roboto in
// that suite replaces the fallback metrics that exposed the fixed grid budget.
void main() {
  setUpAll(() async {
    for (final (String, String) font in <(String, String)>[
      ('NotoSerifSC', 'assets/fonts/NotoSerifSC-Regular.otf'),
      ('LXGWWenKaiScreen', 'assets/fonts/LXGWWenKaiScreen.ttf'),
      ('NotoSansSC', 'assets/fonts/NotoSansSC.ttf'),
    ]) {
      await (FontLoader(font.$1)..addFont(
            Future<ByteData>.value(
              ByteData.sublistView(File(font.$2).readAsBytesSync()),
            ),
          ))
          .load();
    }
  });

  for (final double scale in <double>[1, 1.6, 2]) {
    testWidgets('shelf grows for fallback metrics at ${scale}x', (
      tester,
    ) async {
      await setTestViewport(tester, const Size(360, 780));
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(() async {
        tester.platformDispatcher.clearTextScaleFactorTestValue();
        await setTestViewport(tester, null);
      });
      final Directory root = Directory.systemTemp.createTempSync(
        'shelf-metrics-',
      );
      final Directory book = Directory('${root.path}/books/fixture')
        ..createSync(recursive: true);
      writeJson(File('${book.path}/book.json'), <String, Object?>{
        'title': '段落排版测试',
        'lang': 'zh',
        'len': 100,
        'blocks': <Object?>[],
        'chapters': <Object?>[],
      });
      writeJson(File('${book.path}/status.json'), <String, Object?>{
        'state': 'idle',
      });
      final AppModel model = AppModel(root);
      await model.library.scan();
      addTearDown(() {
        model.dispose();
        root.deleteSync(recursive: true);
      });
      await tester.pumpWidget(ThusfarApp(model: model));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
