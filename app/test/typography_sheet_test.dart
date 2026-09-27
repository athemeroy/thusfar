import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/prefs.dart';
import 'package:thusfar_app/sheets/typography_sheet.dart';
import 'package:thusfar_app/ui/theme.dart';

void main() {
  test('bundled Kai license remains readable from the app asset bundle', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final String license = await rootBundle.loadString(
      'assets/fonts/OFL-LXGWWenKaiScreen.txt',
    );
    expect(license, contains('SIL OPEN FONT LICENSE Version 1.1'));
    expect(license, contains('Copyright 2021-2026 LXGW'));
  });

  Future<void> loadFont(String family, String path) async {
    await (FontLoader(family)..addFont(
          Future<ByteData>.value(
            ByteData.sublistView(File(path).readAsBytesSync()),
          ),
        ))
        .load();
  }

  setUpAll(() async {
    final String sdk =
        Platform.environment['FLUTTER_ROOT'] ??
        '${Platform.environment['HOME']}/.local/share/flutter';
    await loadFont(
      'MaterialIcons',
      '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    await loadFont(
      'Roboto',
      Platform.environment['THUSFAR_TEST_SANS_FONT'] ??
          '${Platform.environment['HOME']}/.local/share/fonts/NotoSansSC.ttf',
    );
    await loadFont('NotoSerifSC', 'assets/fonts/NotoSerifSC-Regular.otf');
    await loadFont('LXGWWenKaiScreen', 'assets/fonts/LXGWWenKaiScreen.ttf');
  });

  testWidgets('narrow phone can adjust margins and choose bundled Kai font', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final Directory temp = Directory.systemTemp.createTempSync('type-sheet-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final Prefs prefs = Prefs(File('${temp.path}/app-prefs.json'));

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => openTypography(context, prefs),
              child: const Text('排版'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('排版'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('左右边距'), findsOneWidget);
    expect(find.text('上下边距'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('shots/typography-sheet-phone.png'),
    );

    final TestGesture drag = await tester.startGesture(
      tester.getCenter(find.byType(Slider).first),
    );
    await drag.moveBy(const Offset(55, 0));
    await tester.pump();
    expect(prefs.fontSize, 19);
    await drag.up();
    await tester.pumpAndSettle();
    expect(prefs.fontSize, isNot(19));

    await tester.tap(find.byTooltip('左右边距增加'));
    await tester.pumpAndSettle();
    expect(prefs.pageHorizontalMargin, 22);

    await tester.dragUntilVisible(
      find.text('楷'),
      find.byType(ListView).last,
      const Offset(0, -100),
    );
    await tester.tap(find.text('楷'));
    await tester.pumpAndSettle();
    expect(prefs.fontFamily, 'LXGWWenKaiScreen');
    prefs.update((Prefs p) => p.spacing = 2);
    await tester.tap(find.text('恢复文字默认值'));
    await tester.pumpAndSettle();
    expect(prefs.lineHeight, 1.85);
    expect(prefs.pageHorizontalMargin, 20);
    expect(tester.takeException(), isNull);
  });
}
