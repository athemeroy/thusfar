import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/prefs.dart';
import 'package:thusfar_app/main.dart';
import 'package:thusfar_app/reader/page_body.dart';
import 'package:thusfar_app/reader/paginator.dart';
import 'package:thusfar_app/reader/tap_layout.dart';
import 'package:thusfar_app/sheets/reading_controls_sheet.dart';
import 'package:thusfar_app/sheets/typography_sheet.dart';
import 'package:thusfar_app/ui/theme.dart';

import 'support/viewport.dart';

void main() {
  test('classic defaults retain all three original columns and boundaries', () {
    final ReaderTapLayout layout = ReaderTapLayout.fromJson(null);
    expect(layout.matchingPreset, ReaderTapPreset.classic);
    for (final double y in <double>[0, .2, .5, .8, 1]) {
      expect(layout.actionAt(0, y), ReaderTapAction.previous);
      expect(layout.actionAt(1 / 3 - .001, y), ReaderTapAction.previous);
      expect(layout.actionAt(1 / 3, y), ReaderTapAction.tools);
      expect(layout.actionAt(2 / 3, y), ReaderTapAction.tools);
      expect(layout.actionAt(2 / 3 + .001, y), ReaderTapAction.next);
      expect(layout.actionAt(1, y), ReaderTapAction.next);
    }
  });

  test('one-handed layouts mirror across the centre without losing tools', () {
    final ReaderTapLayout left = ReaderTapLayout.preset(
      ReaderTapPreset.leftHanded,
    );
    final ReaderTapLayout right = ReaderTapLayout.preset(
      ReaderTapPreset.rightHanded,
    );
    for (int row = 0; row < 3; row++) {
      for (int col = 0; col < 3; col++) {
        expect(left.actions[row * 3 + col], right.actions[row * 3 + 2 - col]);
      }
    }
    expect(left.actionAt(.1, .5), ReaderTapAction.next);
    expect(right.actionAt(.9, .5), ReaderTapAction.next);
    expect(left.actionAt(.1, .1), ReaderTapAction.previous);
    expect(right.actionAt(.9, .1), ReaderTapAction.previous);
    expect(left.actionAt(.5, .5), ReaderTapAction.tools);
    expect(right.actionAt(.5, .5), ReaderTapAction.tools);
  });

  test('custom taps persist independently and corrupt settings are safe', () {
    final Directory temp = Directory.systemTemp.createTempSync('tap-prefs-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final File file = File('${temp.path}/app-prefs.json');
    file.writeAsStringSync('{"fontSize":23,"volumeKeys":false}');
    final Prefs prefs = Prefs(file);
    expect(prefs.tapLayout.matchingPreset, ReaderTapPreset.classic);
    for (final ReaderTapPreset preset in ReaderTapPreset.values) {
      prefs.update((Prefs p) => p.tapLayout = ReaderTapLayout.preset(preset));
      expect(Prefs(file).tapLayout.matchingPreset, preset);
    }
    prefs.update(
      (Prefs p) =>
          p.tapLayout = p.tapLayout.withAction(0, ReaderTapAction.none),
    );
    expect(Prefs(file).tapLayout.actions[0], ReaderTapAction.none);
    expect(Prefs(file).tapLayout.matchingPreset, isNull);
    expect(Prefs(file).fontSize, 23);
    expect(Prefs(file).volumeKeys, isFalse);
    expect(
      prefs.tapLayout.withAction(4, ReaderTapAction.none).actions[4],
      ReaderTapAction.tools,
    );
    expect(
      () => prefs.tapLayout.actions[0] = ReaderTapAction.next,
      throwsUnsupportedError,
    );
    for (final Object? bad in <Object?>[
      null,
      42,
      'left',
      <String>[],
      List<String>.filled(9, 'unknown'),
    ]) {
      file.writeAsStringSync(jsonEncode(<String, Object?>{'tapLayout': bad}));
      expect(Prefs(file).tapLayout.matchingPreset, ReaderTapPreset.classic);
    }
    final ReaderTapLayout rescued = ReaderTapLayout.fromJson(
      List<String>.filled(9, 'none'),
    );
    expect(rescued.actions[4], ReaderTapAction.tools);
    expect(rescued.actionAt(double.nan, 0), ReaderTapAction.none);
  });

  testWidgets(
    'preview edits repeatedly, resets only taps and survives dismissal',
    (tester) async {
      await setTestViewport(tester, const Size(360, 740));
      addTearDown(() => setTestViewport(tester, null));
      final Directory temp = Directory.systemTemp.createTempSync('tap-sheet-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final Prefs prefs = Prefs(File('${temp.path}/prefs.json'));
      prefs.update((Prefs p) {
        p.volumeKeys = false;
        p.fontSize = 24;
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => openTypography(context, prefs),
                child: const Text('排版'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('排版'));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.text('点击区域'),
        find.byType(ListView).last,
        const Offset(0, -240),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('点击区域'));
      await tester.pumpAndSettle();
      for (final ReaderTapPreset preset in <ReaderTapPreset>[
        ReaderTapPreset.leftHanded,
        ReaderTapPreset.rightHanded,
        ReaderTapPreset.classic,
        ReaderTapPreset.leftHanded,
      ]) {
        await tester.tap(
          find.byKey(ValueKey<String>('tap-preset-${preset.name}')),
        );
        await tester.pumpAndSettle();
        expect(prefs.tapLayout.matchingPreset, preset);
        expect(Prefs(prefs.file).tapLayout.matchingPreset, preset);
      }
      await tester.tap(find.byKey(const ValueKey<String>('tap-zone-0')));
      await _show(
        tester,
        find.byKey(const ValueKey<String>('tap-action-none')),
      );
      await tester.tap(find.byKey(const ValueKey<String>('tap-action-none')));
      await tester.pumpAndSettle();
      expect(prefs.tapLayout.actions[0], ReaderTapAction.none);
      await tester.tap(find.byTooltip('关闭点击区域'));
      await tester.pumpAndSettle();
      expect(find.text('阅读排版'), findsOneWidget);
      await tester.tap(find.text('点击区域'));
      await tester.pumpAndSettle();
      expect(prefs.tapLayout.actions[0], ReaderTapAction.none);
      await tester.tapAt(const Offset(180, 20));
      await tester.pumpAndSettle();
      expect(find.text('阅读排版'), findsOneWidget);
      expect(find.byTooltip('关闭点击区域'), findsNothing);
      await tester.tap(find.text('点击区域'));
      await tester.pumpAndSettle();
      await _show(tester, find.text('恢复点击默认值'));
      await tester.tap(find.text('恢复点击默认值'));
      await tester.pumpAndSettle();
      expect(prefs.tapLayout.matchingPreset, ReaderTapPreset.classic);
      expect(prefs.fontSize, 24);
      expect(prefs.volumeKeys, isFalse);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('阅读排版'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('阅读排版'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final Size size in <Size>[const Size(320, 568), const Size(900, 900)]) {
    testWidgets('tap controls remain reachable with large text at $size', (
      tester,
    ) async {
      await setTestViewport(tester, size);
      addTearDown(() => setTestViewport(tester, null));
      final Directory temp = Directory.systemTemp.createTempSync('tap-access-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final Prefs prefs = Prefs(File('${temp.path}/prefs.json'));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => openReadingControls(context, prefs),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await _show(
        tester,
        find.byKey(const ValueKey<String>('tap-preset-leftHanded')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('tap-preset-leftHanded')),
      );
      await tester.pumpAndSettle();
      await _show(tester, find.byKey(const ValueKey<String>('tap-zone-8')));
      await tester.tap(find.byKey(const ValueKey<String>('tap-zone-8')));
      await _show(
        tester,
        find.byKey(const ValueKey<String>('tap-action-none')),
      );
      await tester.tap(find.byKey(const ValueKey<String>('tap-action-none')));
      await tester.pumpAndSettle();
      expect(prefs.tapLayout.actions[8], ReaderTapAction.none);
      await _show(tester, find.text('恢复点击默认值'));
      await tester.tap(find.text('恢复点击默认值'));
      await tester.pumpAndSettle();
      expect(prefs.tapLayout.matchingPreset, ReaderTapPreset.classic);
      await tester.tap(find.byTooltip('关闭点击区域'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  for (final PageAnim anim in PageAnim.values) {
    testWidgets(
      '$anim keeps selection, swipes and volume directions under custom taps',
      (tester) async {
        await setTestViewport(tester, const Size(430, 900));
        addTearDown(() => setTestViewport(tester, null));
        final (Directory root, AppModel model) = await _readerModel();
        model.prefs.update((Prefs p) => p.anim = anim);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          model.dispose();
          root.deleteSync(recursive: true);
        });
        await tester.pumpWidget(ThusfarApp(model: model));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Tap fixture').first);
        await tester.pumpAndSettle();
        Rect viewport() => tester.getRect(
          find.byKey(const ValueKey<String>('reader-page-viewport')),
        );
        Finder visibleBody() {
          final Finder bodies = find.byType(PageBody);
          for (int i = 0; i < bodies.evaluate().length; i++) {
            if (tester.getRect(bodies.at(i)).contains(viewport().center)) {
              return bodies.at(i);
            }
          }
          throw StateError('Missing current page');
        }

        PageBody body() => tester.widget<PageBody>(visibleBody());
        Future<void> tap(double x, double y) async {
          final Rect rect = viewport();
          await tester.tapAt(
            Offset(rect.left + rect.width * x, rect.top + rect.height * y),
          );
          await tester.pumpAndSettle();
        }

        final Paginator originalPager = body().pager;
        final int first = body().page.start;
        await tap(.9, .5);
        final int second = body().page.start;
        expect(second, greaterThan(first));
        await tap(.1, .5);
        expect(body().page.start, first);
        for (final ReaderTapPreset preset in <ReaderTapPreset>[
          ReaderTapPreset.leftHanded,
          ReaderTapPreset.rightHanded,
          ReaderTapPreset.leftHanded,
        ]) {
          model.prefs.update(
            (Prefs p) => p.tapLayout = ReaderTapLayout.preset(preset),
          );
          await tester.pumpAndSettle();
          expect(body().pager, same(originalPager));
          await tap(preset == ReaderTapPreset.leftHanded ? .1 : .9, .5);
          expect(body().page.start, second);
          await tap(preset == ReaderTapPreset.leftHanded ? .1 : .9, .1);
          expect(body().page.start, first);
        }
        // Select actual text, then change controls without losing its source range.
        final PageBody initial = body();
        final Frag fragment = initial.page.frags.first;
        final Block block = initial.pager.book.blocks[fragment.block];
        final TextPainter painter = initial.pager.painterFor(block);
        final Offset caret = painter.getOffsetForCaret(
          TextPosition(offset: fragment.start + 3 + indentShift),
          Rect.zero,
        );
        painter.dispose();
        await tester.longPressAt(
          tester.getTopLeft(visibleBody()) +
              Offset(
                caret.dx + initial.pager.spec.fontSize / 4,
                caret.dy - fragment.top + initial.pager.spec.line / 2,
              ),
        );
        await tester.pumpAndSettle();
        final (int, int)? selection = body().layers.selection;
        expect(selection, isNotNull);
        model.prefs.update(
          (Prefs p) =>
              p.tapLayout = p.tapLayout.withAction(0, ReaderTapAction.none),
        );
        await tester.pumpAndSettle();
        expect(body().layers.selection, selection);
        expect(body().pager, same(originalPager));
        await tap(.1, .5); // Next-page region only clears the selection first.
        expect(body().layers.selection, isNull);
        expect(body().page.start, first);
        await tap(
          .1,
          .1,
        ); // A disabled region never turns the page or opens tools.
        expect(body().page.start, first);
        expect(find.text('排版').hitTestable(), findsNothing);
        await tap(.1, .5);
        expect(body().page.start, second);
        await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeUp);
        await tester.pumpAndSettle();
        expect(body().page.start, first);
        await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeDown);
        await tester.pumpAndSettle();
        expect(body().page.start, second);
        await tester.fling(
          find.byKey(const ValueKey<String>('reader-page-viewport')),
          const Offset(320, 0),
          1200,
        );
        await tester.pumpAndSettle();
        expect(body().page.start, first);
        await tester.fling(
          find.byKey(const ValueKey<String>('reader-page-viewport')),
          const Offset(-320, 0),
          1200,
        );
        await tester.pumpAndSettle();
        expect(body().page.start, second);
        await tap(.5, .5);
        expect(find.text('排版').hitTestable(), findsOneWidget);
        await tester.tap(find.text('排版'));
        await tester.pumpAndSettle();
        await tester.dragUntilVisible(
          find.text('点击区域'),
          find.byType(ListView).last,
          const Offset(0, -160),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('点击区域'));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeDown);
        await tester.pumpAndSettle();
        expect(body().page.start, second);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('阅读排版'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(body().page.start, second);
        // Switching between page-turn widgets still rebases at the same page.
        for (final PageAnim changed in <PageAnim>[
          PageAnim.cover,
          PageAnim.slide,
          PageAnim.none,
          anim,
        ]) {
          model.prefs.update((Prefs p) => p.anim = changed);
          await tester.pumpAndSettle();
          expect(body().page.start, second);
          await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeUp);
          await tester.pumpAndSettle();
          expect(body().page.start, first);
          await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeDown);
          await tester.pumpAndSettle();
          expect(body().page.start, second);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'one-handed taps use the active foldable pane including margins',
    (tester) async {
      await setTestViewport(tester, const Size(900, 1000));
      tester.view.displayFeatures = const <ui.DisplayFeature>[
        ui.DisplayFeature(
          bounds: Rect.fromLTWH(80, 0, 20, 1000),
          type: ui.DisplayFeatureType.hinge,
          state: ui.DisplayFeatureState.postureHalfOpened,
        ),
      ];
      addTearDown(() async {
        tester.view.resetDisplayFeatures();
        await setTestViewport(tester, null);
      });
      final (Directory root, AppModel model) = await _readerModel();
      model.prefs.update((Prefs p) {
        p.anim = PageAnim.none;
        p.pageHorizontalMargin = 96;
        p.tapLayout = ReaderTapLayout.preset(ReaderTapPreset.leftHanded);
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        root.deleteSync(recursive: true);
      });
      await tester.pumpWidget(ThusfarApp(model: model));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tap fixture').first);
      await tester.pumpAndSettle();
      final Rect pane = tester.getRect(
        find.byKey(const ValueKey<String>('reader-page-viewport')),
      );
      expect(pane.left, 100);
      final PageController controller = tester
          .widget<PageView>(find.byType(PageView))
          .controller!;
      final double before = controller.page!;
      await tester.tapAt(Offset(pane.left + 12, pane.center.dy));
      await tester.pumpAndSettle();
      expect(controller.page, before + 1);
      await tester.tapAt(Offset(pane.left + 12, pane.top + 12));
      await tester.pumpAndSettle();
      expect(controller.page, before);
      await tester.tapAt(pane.center);
      await tester.pumpAndSettle();
      expect(find.text('排版').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<(Directory, AppModel)> _readerModel() async {
  final Directory root = Directory.systemTemp.createTempSync('tap-reader-');
  final Directory dir = Directory('${root.path}/books/tapfixture')
    ..createSync(recursive: true);
  final String passage =
      'A familiar passage with words for selection and page turns. ' * 300;
  writeJson(File('${dir.path}/book.json'), <String, Object?>{
    'title': 'Tap fixture',
    'author': '',
    'lang': 'en',
    'len': passage.length,
    'notes': <String, Object?>{},
    'blocks': <Json>[
      <String, Object?>{'k': 'p', 't': passage, 'o': 0},
    ],
    'chapters': <Json>[
      <String, Object?>{
        'title': 'Chapter one',
        'b0': 0,
        'b1': 1,
        'o0': 0,
        'o1': passage.length,
        'kind': 'body',
      },
    ],
  });
  writeJson(File('${dir.path}/status.json'), <String, Object?>{
    'state': 'idle',
  });
  final AppModel model = AppModel(root);
  await model.library.scan();
  return (root, model);
}

Future<void> _show(WidgetTester tester, Finder finder) async {
  await tester.dragUntilVisible(
    finder,
    find.byType(ListView).last,
    const Offset(0, -120),
  );
  await tester.pumpAndSettle();
}
