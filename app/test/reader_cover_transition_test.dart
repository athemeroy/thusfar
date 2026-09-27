import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/prefs.dart';
import 'package:thusfar_app/main.dart';
import 'package:thusfar_app/reader/page_body.dart';
import 'package:thusfar_app/reader/reader_screen.dart';

void main() {
  const Key canvasKey = ValueKey<String>('cover-test-canvas');
  const Key frontKey = ValueKey<String>('cover-current-page');
  const Color firstColor = Color(0xffd52f28);
  const Color secondColor = Color(0xff185aab);

  testWidgets(
    'cover turn reveals the target continuously at 0/25/50/75/100 percent '
    'in both directions and commits only at the end',
    (WidgetTester tester) async {
      int current = 0;
      int generation = 0;
      final List<int> committed = <int>[];
      late StateSetter updateHost;
      final GlobalKey<CoverPageTurnState> turnKey =
          GlobalKey<CoverPageTurnState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) {
                  updateHost = setState;
                  return SizedBox(
                    width: 400,
                    height: 300,
                    child: RepaintBoundary(
                      key: canvasKey,
                      child: CoverPageTurn(
                        key: turnKey,
                        currentIndex: current,
                        generation: generation,
                        canShow: (int index) => index >= 0 && index <= 1,
                        pageBuilder: (BuildContext _, int index) => ColoredBox(
                          color: index == 0 ? firstColor : secondColor,
                        ),
                        onPageChanged: (int index) {
                          committed.add(index);
                          updateHost(() => current = index);
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );

      final Finder canvas = find.byKey(canvasKey);
      final Offset origin = tester.getTopLeft(canvas);

      Future<Color> pixel(int x, int y) async {
        final RenderRepaintBoundary boundary = tester
            .renderObject<RenderRepaintBoundary>(canvas);
        return (await tester.runAsync(() async {
          final ui.Image image = await boundary.toImage(pixelRatio: 1);
          try {
            final ByteData data = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            final int at = (y * image.width + x) * 4;
            return Color.fromARGB(
              data.getUint8(at + 3),
              data.getUint8(at),
              data.getUint8(at + 1),
              data.getUint8(at + 2),
            );
          } finally {
            image.dispose();
          }
        }))!;
      }

      Future<void> expectFrame({
        required double progress,
        required bool forward,
      }) async {
        final Rect front = tester.getRect(find.byKey(frontKey));
        final double expectedLeft =
            origin.dx + (forward ? -progress : progress) * 400;
        expect(front.left, closeTo(expectedLeft, 1));
        final int boundary = (400 * (forward ? 1 - progress : progress))
            .round();
        if (progress == 0) {
          expect(await pixel(200, 20), forward ? firstColor : secondColor);
        } else if (progress == 1) {
          expect(await pixel(200, 20), forward ? secondColor : firstColor);
        } else {
          expect(await pixel(boundary - 25, 20), firstColor);
          expect(await pixel(boundary + 25, 20), secondColor);
        }
      }

      await expectFrame(progress: 0, forward: true);
      final TestGesture next = await tester.startGesture(
        origin + const Offset(200, 150),
      );
      for (final int quarter in <int>[1, 2, 3, 4]) {
        await next.moveBy(const Offset(-100, 0));
        await tester.pump();
        await expectFrame(progress: quarter / 4, forward: true);
        expect(committed, isEmpty);
      }
      await next.up();
      await tester.pumpAndSettle();
      expect(committed, <int>[1]);
      expect(current, 1);
      await expectFrame(progress: 0, forward: false);

      final TestGesture previous = await tester.startGesture(
        origin + const Offset(200, 150),
      );
      for (final int quarter in <int>[1, 2, 3, 4]) {
        await previous.moveBy(const Offset(100, 0));
        await tester.pump();
        await expectFrame(progress: quarter / 4, forward: false);
        expect(committed, <int>[1]);
      }
      await previous.up();
      await tester.pumpAndSettle();
      expect(committed, <int>[1, 0]);
      expect(current, 0);

      // Reversing a partial swipe must restore the same page without a save.
      final TestGesture cancelled = await tester.startGesture(
        origin + const Offset(200, 150),
      );
      await cancelled.moveBy(const Offset(-100, 0));
      await tester.pump(const Duration(milliseconds: 50));
      await cancelled.moveBy(const Offset(80, 0));
      await tester.pump(const Duration(milliseconds: 50));
      await cancelled.up();
      await tester.pumpAndSettle();
      expect(committed, <int>[1, 0]);
      expect(current, 0);
      expect(await pixel(200, 20), firstColor);

      // Buttons and keyboard use the same transition entry point.
      turnKey.currentState!.turn(1);
      await tester.pump();
      expect(committed, <int>[1, 0]);
      await tester.pumpAndSettle();
      expect(committed, <int>[1, 0, 1]);
      expect(await pixel(200, 20), secondColor);

      // A re-pagination interrupts an in-flight turn without a late commit.
      turnKey.currentState!.turn(-1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      updateHost(() => generation++);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(committed, <int>[1, 0, 1]);
      expect(current, 1);
      expect(await pixel(200, 20), secondColor);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reader tap uses cover motion and saves only after completion', (
    WidgetTester tester,
  ) async {
    final Directory root = Directory.systemTemp.createTempSync(
      'thusfar-cover-reader-',
    );
    final Directory bookDir = Directory('${root.path}/books/coverbook')
      ..createSync(recursive: true);
    final String first = 'First chapter passage for the cover turn. ' * 80;
    final String second = 'Second chapter passage after the cover turn. ' * 80;
    writeJson(File('${bookDir.path}/book.json'), <String, Object?>{
      'title': 'Cover turn fixture',
      'author': '',
      'lang': 'en',
      'len': first.length + second.length,
      'notes': <String, Object?>{},
      'blocks': <Json>[
        <String, Object?>{'k': 'p', 't': first, 'o': 0},
        <String, Object?>{'k': 'p', 't': second, 'o': first.length},
      ],
      'chapters': <Json>[
        <String, Object?>{
          'title': 'First chapter',
          'b0': 0,
          'b1': 1,
          'o0': 0,
          'o1': first.length,
          'kind': 'body',
        },
        <String, Object?>{
          'title': 'Second chapter',
          'b0': 1,
          'b1': 2,
          'o0': first.length,
          'o1': first.length + second.length,
          'kind': 'body',
        },
      ],
    });
    writeJson(File('${bookDir.path}/status.json'), <String, Object?>{
      'state': 'idle',
    });
    final AppModel model = AppModel(root);
    await model.library.scan();
    model.prefs.update((Prefs prefs) => prefs.anim = PageAnim.cover);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
      root.deleteSync(recursive: true);
    });

    await tester.pumpWidget(ThusfarApp(model: model));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cover turn fixture').first);
    await tester.pumpAndSettle();
    expect(find.byType(CoverPageTurn), findsOneWidget);
    final BookEntry entry = model.library.books.single;
    final Progress? savedBefore = model.library.progressOf(entry.id);
    final PageBody currentBefore = tester.widget<PageBody>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('cover-current-page')),
        matching: find.byType(PageBody),
      ),
    );
    final Rect viewport = tester.getRect(
      find.byKey(const ValueKey<String>('reader-page-viewport')),
    );

    await tester.tapAt(Offset(viewport.right - 20, viewport.center.dy));
    await tester.pump();
    final PageBody target = tester.widget<PageBody>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('cover-target-page')),
        matching: find.byType(PageBody),
      ),
    );
    expect(target.page.start, greaterThan(currentBefore.page.start));
    expect(model.library.progressOf(entry.id)?.pos, savedBefore?.pos);
    await tester.pump(const Duration(milliseconds: 100));
    expect(model.library.progressOf(entry.id)?.pos, savedBefore?.pos);
    await tester.pumpAndSettle();
    expect(model.library.progressOf(entry.id)?.pos, target.page.start);
    expect(tester.takeException(), isNull);
  });
}
