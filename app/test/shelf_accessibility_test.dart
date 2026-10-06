import 'dart:io';
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/prefs.dart';
import 'package:thusfar_app/main.dart';
import 'package:thusfar_app/screens/shelf_screen.dart';
import 'package:thusfar_app/ui/cover.dart';
import 'package:thusfar_app/ui/theme.dart';

import 'support/viewport.dart';

void main() {
  setUpAll(() async {
    for (final (String, String) font in <(String, String)>[
      ('Roboto', 'assets/fonts/NotoSansSC.ttf'),
      ('NotoSansSC', 'assets/fonts/NotoSansSC.ttf'),
      ('NotoSerifSC', 'assets/fonts/NotoSerifSC-Regular.otf'),
      ('ZCOOLXiaoWei', 'assets/fonts/ZCOOLXiaoWei-Regular.ttf'),
    ]) {
      await (FontLoader(font.$1)..addFont(
            Future<ByteData>.value(
              ByteData.sublistView(File(font.$2).readAsBytesSync()),
            ),
          ))
          .load();
    }
  });

  late Directory root;
  late Library library;
  late Prefs prefs;
  const List<String> states = <String>[
    'idle',
    'queued',
    'running',
    'finalizing',
    'cancelling',
    'paused',
    'error',
    'done',
  ];
  const List<String> labels = <String>[
    '整理',
    '查看任务',
    '整理中',
    '收尾中',
    '暂停中',
    '继续整理',
    '查看整理',
    '已整理',
  ];
  Future<void> fixture({bool single = false, bool progress = true}) async {
    root = Directory.systemTemp.createTempSync('thusfar-scaled-shelf-');
    for (int i = 0; i < (single ? 1 : states.length); i++) {
      final Directory dir = Directory('${root.path}/books/book-$i')
        ..createSync(recursive: true);
      writeJson(File('${dir.path}/book.json'), <String, Object?>{
        'title': i.isEven
            ? '$i 一本很长的中文书名与折叠屏上的阅读故事'
            : '$i A long English title about reading on a narrow folding screen',
        'author': i.isEven ? '一位名字比较长的作者' : 'An Author With A Long Name',
        'len': 100,
        'lang': i.isEven ? 'zh' : 'en',
        'blocks': <Object?>[],
        'chapters': <Object?>[],
      });
      writeJson(File('${dir.path}/status.json'), <String, Object?>{
        'state': states[i],
        'done': 2,
        'total': 100,
        'people': 123,
      });
    }
    library = Library(root);
    prefs = Prefs(File('${root.path}/app-prefs.json'));
    await library.scan();
    if (progress) {
      library.saveProgress('book-0', 25, 30, 100, timestamp: 123);
      library.setReadingList(<String>['book-1', 'book-2']);
    }
    addTearDown(() {
      library.dispose();
      prefs.dispose();
      root.deleteSync(recursive: true);
    });
  }

  Future<void> viewport(WidgetTester tester, Size size, double scale) async {
    await setTestViewport(tester, size);
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(() async {
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      await setTestViewport(tester, null);
    });
  }

  for (final double scale in <double>[1, 1.6, 2]) {
    testWidgets('phone shelf fits bundled font metrics at ${scale}x', (
      tester,
    ) async {
      await viewport(tester, const Size(360, 780), scale);
      await fixture(single: true, progress: false);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light).copyWith(
            visualDensity: VisualDensity.standard,
            materialTapTargetSize: MaterialTapTargetSize.padded,
          ),
          home: ShelfScreen(
            library: library,
            prefs: prefs,
            imports: const <ImportItem>[],
            onOpen: (_) {},
            onDrawer: (_, {bool focus = false}) {},
            onImport: () {},
            onRestore: () {},
            onModelSettings: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final RenderParagraph title = tester.renderObject<RenderParagraph>(
        find.text(library.books.single.title).last,
      );
      expect(title.size.height, greaterThanOrEqualTo(2 * 16 * 1.28 * scale));
      await tester.pumpWidget(const SizedBox());
    });

    for (final double width in <double>[320, 360, 540]) {
      for (final bool listView in <bool>[false, true]) {
        testWidgets(
          '${listView ? 'list' : 'grid'} ${width}px ${scale}x keeps actions and progress',
          (tester) async {
            await viewport(tester, Size(width, 780), scale);
            await fixture();
            prefs.listView = listView;
            prefs.sort = 1;
            final String progressBefore = File(
              '${root.path}/progress.json',
            ).readAsStringSync();
            final List<String> opened = <String>[];
            final List<(String, bool)> drawers = <(String, bool)>[];
            await tester.pumpWidget(
              MaterialApp(
                theme: buildTheme(Brightness.light).copyWith(
                  visualDensity: VisualDensity.standard,
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                ),
                home: ShelfScreen(
                  library: library,
                  prefs: prefs,
                  imports: const <ImportItem>[],
                  onOpen: (BookEntry book) => opened.add(book.id),
                  onDrawer: (BookEntry book, {bool focus = false}) =>
                      drawers.add((book.id, focus)),
                  onImport: () {},
                  onRestore: () {},
                  onModelSettings: () {},
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tester.tap(find.text('继续'));
            expect(opened, <String>['book-0']);
            await tester.tap(
              find.byTooltip('更多操作：${library.byId('book-0')!.title}'),
            );
            expect(drawers.single, ('book-0', false));
            expect(
              tester
                  .widget<CustomScrollView>(find.byType(CustomScrollView))
                  .semanticChildCount,
              states.length,
            );
            final Finder scrollable = find
                .descendant(
                  of: find.byType(CustomScrollView),
                  matching: find.byType(Scrollable),
                )
                .first;
            for (int i = 0; i < states.length; i++) {
              final BookEntry book = library.byId('book-$i')!;
              final Finder action = listView
                  ? find.ancestor(
                      of: find.byTooltip('${labels[i]}《${book.title}》'),
                      matching: find.byType(IconButton),
                    )
                  : find.byKey(ValueKey<String>('process-${book.id}'));
              await tester.scrollUntilVisible(
                action,
                220,
                scrollable: scrollable,
              );
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              final Rect actionRect = tester.getRect(action);
              expect(actionRect.width, greaterThanOrEqualTo(44 - 0.001));
              expect(actionRect.height, greaterThanOrEqualTo(44 - 0.001));
              expect(actionRect.left, greaterThanOrEqualTo(0));
              expect(actionRect.right, lessThanOrEqualTo(width));
              if (!listView) {
                final RenderParagraph label = tester
                    .renderObject<RenderParagraph>(
                      find.descendant(
                        of: action,
                        matching: find.text(labels[i]),
                      ),
                    );
                expect(label.didExceedMaxLines, isFalse);
                final Rect labelRect =
                    label.localToGlobal(Offset.zero) & label.size;
                expect(actionRect.contains(labelRect.topLeft), isTrue);
                expect(actionRect.contains(labelRect.bottomRight), isTrue);
              }
              final int opensBefore = opened.length;
              await tester.tap(action);
              expect(drawers.last, (book.id, true));
              expect(opened.length, opensBefore);
              final Finder title = find.text(book.title).last;
              await tester.ensureVisible(title);
              await tester.pumpAndSettle();
              await tester.tap(title);
              expect(opened.last, book.id);
              await tester.longPress(title);
              expect(drawers.last, (book.id, false));
              expect(tester.takeException(), isNull);
            }
            expect(
              File('${root.path}/progress.json').readAsStringSync(),
              progressBefore,
            );
            expect(library.readingList, <String>['book-1', 'book-2']);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }

    testWidgets('hinged shelf respects its 320px pane at ${scale}x', (
      tester,
    ) async {
      await viewport(tester, const Size(580, 780), scale);
      tester.view.displayFeatures = const <DisplayFeature>[
        DisplayFeature(
          bounds: Rect.fromLTWH(240, 0, 20, 780),
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.postureHalfOpened,
        ),
      ];
      addTearDown(tester.view.resetDisplayFeatures);
      await fixture(single: true, progress: false);
      final AppModel model = AppModel(root);
      await model.library.scan();
      addTearDown(model.dispose);
      await tester.pumpWidget(ThusfarApp(model: model));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final Rect shelf = tester.getRect(find.byType(ShelfScreen));
      expect(shelf.left, 260);
      expect(shelf.width, 320);
      expect(shelf.bottom, lessThanOrEqualTo(780));
      final Rect cover = tester.getRect(find.byType(BookCover));
      expect(cover.left, greaterThanOrEqualTo(260));
      expect(cover.right, lessThanOrEqualTo(580));
      await tester.pumpWidget(const SizedBox());
    });
  }
}
