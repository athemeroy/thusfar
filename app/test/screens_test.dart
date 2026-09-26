// Renders the real screens with real fonts and a DeepSeek-processed book,
// writing PNGs to test/shots/ for visual review:
//   flutter test test/screens_test.dart --update-goldens
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/main.dart';

Future<void> _font(String family, String path) async {
  final FontLoader loader = FontLoader(family)
    ..addFont(
      Future<ByteData>.value(
        ByteData.sublistView(File(path).readAsBytesSync()),
      ),
    );
  await loader.load();
}

void _copy(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final FileSystemEntity e in from.listSync()) {
    final String name = e.uri.pathSegments
        .where((String s) => s.isNotEmpty)
        .last;
    if (e is Directory) {
      _copy(e, Directory('${to.path}/$name'));
    } else if (e is File) {
      e.copySync('${to.path}/$name');
    }
  }
}

Future<void> settle(WidgetTester tester) async {
  for (int i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> shot(WidgetTester tester, String name) async {
  await settle(tester);
  await expectLater(
    find.byType(HomeShell),
    matchesGoldenFile('shots/$name.png'),
  );
}

void main() {
  late Directory root;
  setUpAll(() async {
    final String sdkRoot =
        Platform.environment['FLUTTER_ROOT'] ??
        '${Platform.environment['HOME']}/.local/share/flutter';
    final String sdk = '$sdkRoot/bin/cache/artifacts/material_fonts';
    await _font('MaterialIcons', '$sdk/MaterialIcons-Regular.otf');
    await _font(
      'Roboto',
      Platform.environment['THUSFAR_TEST_SANS_FONT'] ??
          '${Platform.environment['HOME']}/.local/share/fonts/NotoSansSC.ttf',
    );
    await _font('NotoSerifSC', 'assets/fonts/NotoSerifSC-Regular.otf');
    await _font('ZCOOLXiaoWei', 'assets/fonts/ZCOOLXiaoWei-Regular.ttf');
    root = Directory.systemTemp.createTempSync('thusfar-shots');
    _copy(
      Directory('../oracle/goldens/books/aq_deepseek'),
      Directory('${root.path}/books/aqdeepseek000001'),
    );
    _copy(
      Directory('../oracle/goldens/books/jekyll_partial_deepseek'),
      Directory('${root.path}/books/jekyll0000000002'),
    );
    File('${root.path}/progress.json').writeAsStringSync(
      '{"aqdeepseek000001":{"pos":1740,"cutoff":2400,"t":1790300000,"pct":11.0}}',
    );
  });

  testWidgets('screens', (WidgetTester tester) async {
    final bool previousShadows = debugDisableShadows;
    debugDisableShadows = false;
    try {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      final AppModel model = AppModel(root);
      await tester.runAsync(model.library.scan);
      await tester.pumpWidget(ThusfarApp(model: model));
      await tester.runAsync(() async {
        for (final Element e in find.byType(Image).evaluate()) {
          await precacheImage((e.widget as Image).image, e);
        }
      });
      await shot(tester, '01-shelf');

      // Open the book: reader page.
      await tester.tap(find.text('继续').first);
      await settle(tester);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('shots/02-reader.png'),
      );

      // Toolbar.
      final Size size = tester.view.physicalSize / tester.view.devicePixelRatio;
      await tester.tapAt(Offset(size.width / 2, size.height / 2));
      await settle(tester);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('shots/03-toolbar.png'),
      );

      // People drawer from the toolbar.
      await tester.tap(find.text('人物'));
      await settle(tester);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('shots/04-people.png'),
      );

      // First person → person card pushed inside the drawer.
      final Finder rows = find.byType(InkWell);
      await tester.tap(find.text('全部'));
      await settle(tester);
      await tester.tap(find.text('阿Q').first);
      await settle(tester);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('shots/05-person.png'),
      );
      expect(rows, findsWidgets);

      // Full height.
      await tester.drag(find.text('简介'), const Offset(0, -400));
      await settle(tester);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('shots/06-person-full.png'),
      );

      await tester.binding.handlePopRoute();
      await settle(tester);
      await tester.binding.handlePopRoute();
      await settle(tester);

      // TOC.
      await tester.tapAt(Offset(size.width / 2, size.height / 2));
      await settle(tester);
      await tester.tap(find.text('目录'));
      await settle(tester);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('shots/07-toc.png'),
      );
      await tester.binding.handlePopRoute();
      await settle(tester);

      // Recap.
      await tester.tapAt(Offset(size.width / 2, size.height / 2));
      await settle(tester);
      await tester.tap(find.text('前情'));
      await settle(tester);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('shots/08-recap.png'),
      );
      await tester.binding.handlePopRoute();
      await settle(tester);

      // Native grounded-question sheet, without sending a model request.
      await tester.tapAt(Offset(size.width / 2, size.height / 2));
      await settle(tester);
      await tester.tap(find.text('问书'));
      await settle(tester);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('shots/10-ask.png'),
      );
      await tester.binding.handlePopRoute();
      await settle(tester);

      // Long press to select.
      await tester.longPressAt(Offset(size.width / 2, size.height * 0.4));
      await settle(tester);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('shots/09-select.png'),
      );
    } finally {
      // Restore before flutter_test verifies painting invariants; addTearDown
      // runs after that check on the pinned Flutter release.
      debugDisableShadows = previousShadows;
    }
  });
}
