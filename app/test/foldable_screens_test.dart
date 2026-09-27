import 'dart:io';
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/main.dart';
import 'package:thusfar_app/reader/page_body.dart';
import 'package:thusfar_app/screens/settings_screen.dart';
import 'package:thusfar_app/screens/shelf_screen.dart';
import 'package:thusfar_app/ui/cover.dart';

Future<void> _font(String family, String path) async {
  await (FontLoader(family)..addFont(
        Future<ByteData>.value(
          ByteData.sublistView(File(path).readAsBytesSync()),
        ),
      ))
      .load();
}

void _copy(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final FileSystemEntity entity in from.listSync()) {
    final String name = entity.uri.pathSegments
        .where((String part) => part.isNotEmpty)
        .last;
    if (entity is Directory) {
      _copy(entity, Directory('${to.path}/$name'));
    } else if (entity is File) {
      entity.copySync('${to.path}/$name');
    }
  }
}

void main() {
  late Directory root;

  setUpAll(() async {
    final String sdk =
        Platform.environment['FLUTTER_ROOT'] ??
        '${Platform.environment['HOME']}/.local/share/flutter';
    await _font(
      'MaterialIcons',
      '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    await _font(
      'Roboto',
      Platform.environment['THUSFAR_TEST_SANS_FONT'] ??
          '${Platform.environment['HOME']}/.local/share/fonts/NotoSansSC.ttf',
    );
    await _font('NotoSerifSC', 'assets/fonts/NotoSerifSC-Regular.otf');
    await _font('ZCOOLXiaoWei', 'assets/fonts/ZCOOLXiaoWei-Regular.ttf');
    await _font('LXGWWenKaiScreen', 'assets/fonts/LXGWWenKaiScreen.ttf');
  });

  Future<AppModel> fixture() async {
    root = Directory.systemTemp.createTempSync('thusfar-foldable-shots-');
    _copy(
      Directory('../oracle/goldens/books/aq_deepseek'),
      Directory('${root.path}/books/aqfoldable00001'),
    );
    final AppModel model = AppModel(root);
    await model.library.scan();
    return model;
  }

  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('unfolded vertical hinge gives the book the full screen', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(840, 900)
      ..devicePixelRatio = 1
      ..padding = const FakeViewPadding(top: 24, bottom: 24)
      ..viewPadding = const FakeViewPadding(top: 24, bottom: 24)
      ..displayFeatures = const <DisplayFeature>[
        DisplayFeature(
          bounds: Rect.fromLTWH(410, 0, 20, 900),
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.postureHalfOpened,
        ),
      ];
    addTearDown(() {
      tester.view
        ..resetDisplayFeatures()
        ..resetPadding()
        ..resetViewPadding()
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });
    final AppModel model = await fixture();
    addTearDown(() {
      model.dispose();
      root.deleteSync(recursive: true);
    });

    await tester.pumpWidget(ThusfarApp(model: model));
    await settle(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('shots/foldable-vertical-home.png'),
    );
    expect(
      find.byKey(const ValueKey<String>('foldable-nav-0')),
      findsOneWidget,
    );
    expect(find.text('书架'), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
    expect(
      tester
          .getRect(find.byKey(const ValueKey<String>('foldable-featured-book')))
          .right,
      lessThanOrEqualTo(410),
    );
    expect(
      tester.getRect(find.byType(ShelfScreen)).left,
      greaterThanOrEqualTo(430),
    );
    final Finder covers = find.byType(BookCover);
    for (int i = 0; i < covers.evaluate().length; i++) {
      final Rect cover = tester.getRect(covers.at(i));
      expect(
        cover.right <= 410 || cover.left >= 430,
        isTrue,
        reason: 'Book cover $i crosses the physical hinge: $cover',
      );
    }
    await tester.tap(find.byKey(const ValueKey<String>('foldable-nav-1')));
    await tester.pumpAndSettle();
    expect(find.text('读书时长按一句话，就能摘录或写笔记'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('foldable-nav-2')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('foldable-nav-0')));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('foldable-featured-book')),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('shots/foldable-vertical-reader.png'),
    );
    expect(find.text('目录与书签'), findsNothing);
    final Rect page = tester.getRect(find.byType(PageBody).first);
    final int pageStart = tester
        .widget<PageBody>(find.byType(PageBody).first)
        .page
        .start;
    final int pageEnd = tester
        .widget<PageBody>(find.byType(PageBody).first)
        .page
        .end;
    expect(page.width, greaterThan(410));
    await tester.tapAt(const Offset(390, 700));
    await tester.pumpAndSettle();
    expect(find.text('目录').hitTestable(), findsOneWidget);
    final Rect controls = tester.getRect(
      find.byKey(const ValueKey<String>('reader-toolbar-panel')),
    );
    final Rect visiblePage = tester.getRect(
      find.byKey(const ValueKey<String>('reader-page-viewport')),
    );
    expect(visiblePage.bottom, lessThanOrEqualTo(controls.top + 1));
    expect(
      tester.getRect(find.byType(PageBody).first).bottom,
      lessThanOrEqualTo(controls.top + 1),
    );
    expect(
      tester.widget<PageBody>(find.byType(PageBody).first).page.start,
      pageStart,
    );
    expect(
      tester.widget<PageBody>(find.byType(PageBody).first).page.end,
      pageEnd,
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('shots/foldable-vertical-reader-tools.png'),
    );
    await tester.tapAt(const Offset(390, 500));
    await tester.pumpAndSettle();
    expect(
      tester.widget<PageBody>(find.byType(PageBody).first).page.start,
      pageStart,
    );
    expect(
      tester.widget<PageBody>(find.byType(PageBody).first).page.end,
      pageEnd,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tabletop hinge keeps controls behind a tap', (tester) async {
    tester.view
      ..physicalSize = const Size(430, 900)
      ..devicePixelRatio = 1
      ..padding = const FakeViewPadding(top: 24, bottom: 24)
      ..viewPadding = const FakeViewPadding(top: 24, bottom: 24)
      ..displayFeatures = const <DisplayFeature>[
        DisplayFeature(
          bounds: Rect.fromLTWH(0, 430, 430, 20),
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.postureHalfOpened,
        ),
      ];
    addTearDown(() {
      tester.view
        ..resetDisplayFeatures()
        ..resetPadding()
        ..resetViewPadding()
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });
    final AppModel model = await fixture();
    addTearDown(() {
      model.dispose();
      root.deleteSync(recursive: true);
    });

    await tester.pumpWidget(ThusfarApp(model: model));
    await settle(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('shots/foldable-tabletop-home.png'),
    );
    expect(find.byType(NavigationBar), findsOneWidget);

    await tester.tap(find.text('阿Q正传').first);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('shots/foldable-tabletop-reader.png'),
    );
    expect(find.text('工具栏'), findsNothing);
    expect(
      tester.getRect(find.byType(PageBody).first).bottom,
      greaterThan(450),
    );
    await tester.tapAt(const Offset(215, 650));
    await tester.pumpAndSettle();
    expect(find.text('目录').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('phone reader keeps the title clear when controls appear', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1
      ..padding = const FakeViewPadding(top: 24, bottom: 24)
      ..viewPadding = const FakeViewPadding(top: 24, bottom: 24)
      ..resetDisplayFeatures();
    addTearDown(() {
      tester.view
        ..resetPadding()
        ..resetViewPadding()
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });
    final AppModel model = await fixture();
    addTearDown(() {
      model.dispose();
      root.deleteSync(recursive: true);
    });

    await tester.pumpWidget(ThusfarApp(model: model));
    await settle(tester);
    await tester.tap(find.text('阿Q正传').first);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('shots/phone-reader.png'),
    );
    final int pageStart = tester
        .widget<PageBody>(find.byType(PageBody).first)
        .page
        .start;
    final int pageEnd = tester
        .widget<PageBody>(find.byType(PageBody).first)
        .page
        .end;
    await tester.tapAt(const Offset(195, 500));
    await tester.pumpAndSettle();
    expect(find.byTooltip('回书架').hitTestable(), findsOneWidget);
    expect(tester.getRect(find.byTooltip('回书架')).top, greaterThan(500));
    final Rect controls = tester.getRect(
      find.byKey(const ValueKey<String>('reader-toolbar-panel')),
    );
    final Rect visiblePage = tester.getRect(
      find.byKey(const ValueKey<String>('reader-page-viewport')),
    );
    expect(visiblePage.bottom, lessThanOrEqualTo(controls.top + 1));
    expect(
      tester.getRect(find.byType(PageBody).first).bottom,
      lessThanOrEqualTo(controls.top + 1),
    );
    expect(
      tester.widget<PageBody>(find.byType(PageBody).first).page.start,
      pageStart,
    );
    expect(
      tester.widget<PageBody>(find.byType(PageBody).first).page.end,
      pageEnd,
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('shots/phone-reader-tools.png'),
    );
    await tester.tapAt(const Offset(195, 350));
    await tester.pumpAndSettle();
    expect(
      tester.widget<PageBody>(find.byType(PageBody).first).page.start,
      pageStart,
    );
    expect(
      tester.widget<PageBody>(find.byType(PageBody).first).page.end,
      pageEnd,
    );
    await tester.tapAt(const Offset(355, 500));
    await tester.pumpAndSettle();
    expect(
      tester.widget<PageBody>(find.byType(PageBody).first).page.start,
      pageEnd,
    );
    await tester.tapAt(const Offset(35, 500));
    await tester.pumpAndSettle();
    expect(
      tester.widget<PageBody>(find.byType(PageBody).first).page.start,
      pageStart,
    );
    await tester.tapAt(const Offset(195, 350));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(355, 500));
    await tester.pumpAndSettle();
    expect(
      tester.widget<PageBody>(find.byType(PageBody).first).page.start,
      pageEnd,
    );
    expect(find.byTooltip('回书架').hitTestable(), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('wide landscape keeps navigation and reader column usable', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(900, 440)
      ..devicePixelRatio = 1
      ..padding = const FakeViewPadding(top: 24, bottom: 24)
      ..viewPadding = const FakeViewPadding(top: 24, bottom: 24)
      ..resetDisplayFeatures();
    addTearDown(() {
      tester.view
        ..resetPadding()
        ..resetViewPadding()
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });
    final AppModel model = await fixture();
    addTearDown(() {
      model.dispose();
      root.deleteSync(recursive: true);
    });

    await tester.pumpWidget(ThusfarApp(model: model));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    await tester.tap(find.text('阿Q正传').first);
    await tester.pumpAndSettle();
    final Rect page = tester.getRect(find.byType(PageBody).first);
    final Rect viewport = tester.getRect(
      find.byKey(const ValueKey<String>('reader-page-viewport')),
    );
    expect(viewport.left, 0);
    expect(viewport.right, 900);
    expect(page.left, model.prefs.pageHorizontalMargin);
    expect(page.right, 900 - model.prefs.pageHorizontalMargin);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
