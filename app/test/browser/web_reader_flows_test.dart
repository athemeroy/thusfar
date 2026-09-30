// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

@TestOn('browser')
library;

import 'dart:async';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/ui/theme.dart';
import 'package:thusfar_app/web/web_ai_panel.dart';
import 'package:thusfar_app/web/web_app.dart';
import 'package:thusfar_app/web/web_ask_panel.dart';
import 'package:thusfar_app/web/web_storage.dart';

class _Library extends Fake implements WebLibrary {
  Completer<void>? pendingSave;
  int saves = 0;
  WebReadingState? reading;

  @override
  Future<void> saveState(String id, WebReadingState state) {
    saves++;
    reading = state;
    return pendingSave?.future ?? Future<void>.value();
  }

  @override
  Future<Json?> loadPreparation(String id) async => null;

  @override
  Future<bool> otherPreparationLeaseActive(String id, String owner) async =>
      false;
}

WebBook _book() {
  final List<Json> blocks = <Json>[];
  final List<Json> chapters = <Json>[];
  int offset = 0;
  for (int chapter = 0; chapter < 2; chapter++) {
    final int first = blocks.length;
    final int start = offset;
    for (int paragraph = 0; paragraph < 40; paragraph++) {
      final String text =
          'Passage $chapter-$paragraph. '
          'The reader follows the trail beside the river. '
          'Every source character should remain on screen after reflow. ';
      blocks.add(<String, Object?>{'k': 'p', 't': text, 'o': offset});
      offset += text.length;
    }
    chapters.add(<String, Object?>{
      'title': 'Chapter $chapter',
      'b0': first,
      'b1': blocks.length,
      'o0': start,
      'o1': offset,
    });
  }
  return WebBook(
    meta: WebBookMeta(
      id: '0123456789abcdef01234567',
      title: 'Reader flow fixture',
      author: '',
      length: offset,
      chapters: chapters.length,
      added: 0,
    ),
    data: <String, Object?>{'blocks': blocks, 'chapters': chapters},
    images: <String, String>{},
  );
}

String _visibleText(WidgetTester tester) => tester
    .widgetList<RichText>(
      find.descendant(
        of: find.byType(SelectionArea),
        matching: find.byType(RichText),
      ),
    )
    .map((RichText widget) => widget.text.toPlainText())
    .join('\n');

List<({int block, int start, int end})> _visibleRanges(WidgetTester tester) =>
    tester
        .widgetList<SizedBox>(
          find.byWidgetPredicate((Widget widget) {
            final Key? key = widget.key;
            return widget is SizedBox &&
                key is ValueKey<String> &&
                key.value.startsWith('web-page-fragment:');
          }),
        )
        .map((SizedBox widget) {
          final List<String> parts = (widget.key! as ValueKey<String>).value
              .split(':');
          return (
            block: int.parse(parts[1]),
            start: int.parse(parts[2]),
            end: int.parse(parts[3]),
          );
        })
        .where((range) => range.block >= 0 && range.start < range.end)
        .toList();

void main() {
  setUp(() => html.window.localStorage.remove('thusfar-web-prefs'));

  Future<GlobalKey<NavigatorState>> open(
    WidgetTester tester,
    _Library library, {
    int chapter = 0,
    double fraction = 0.5,
  }) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: buildTheme(Brightness.light),
        home: const Scaffold(body: Text('Shelf fixture')),
      ),
    );
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => WebReader(
            book: _book(),
            state: WebReadingState(chapter: chapter, fraction: fraction),
            library: library,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return navigator;
  }

  Future<VoidCallback> panelAction(WidgetTester tester, String label) async {
    await tester.tap(find.byTooltip('打开阅读工具'));
    await tester.pumpAndSettle();
    return tester
        .widget<TextButton>(find.widgetWithText(TextButton, label))
        .onPressed!;
  }

  testWidgets(
    'reflow keeps the same source through repeated resize and type changes',
    (WidgetTester tester) async {
      await open(tester, _Library());
      final String before = _visibleText(tester);
      expect(before, isNotEmpty);
      final anchor = _visibleRanges(tester).first;
      void expectAnchor(String stage) {
        final ranges = _visibleRanges(tester);
        expect(
          ranges.any(
            (range) =>
                range.block == anchor.block &&
                range.start <= anchor.start &&
                anchor.start < range.end,
          ),
          isTrue,
          reason: '$stage must retain source $anchor; visible ranges: $ranges',
        );
      }

      for (final Size size in <Size>[
        const Size(768, 1024),
        const Size(320, 568),
        const Size(640, 360),
        const Size(390, 844),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expectAnchor('resize to $size');
      }
      expect(_visibleText(tester), before);
      await tester.tap(find.byTooltip('打开阅读工具'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '排版'));
      await tester.pumpAndSettle();
      final Slider fontSize = tester.widget<Slider>(
        find.descendant(
          of: find
              .ancestor(of: find.text('字号'), matching: find.byType(Row))
              .first,
          matching: find.byType(Slider),
        ),
      );
      fontSize.onChanged!(30);
      await tester.pumpAndSettle();
      expectAnchor('font size 30');
      fontSize.onChanged!(21);
      await tester.pumpAndSettle();
      expect(_visibleText(tester), before);
      final WebBook book = _book();
      final int expectedCutoff = _visibleRanges(tester)
          .map((range) => (book.blocks[range.block]['o']! as int) + range.end)
          .fold(0, (int largest, int end) => end > largest ? end : largest);
      await tester.tap(find.byTooltip('关闭阅读排版'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '人物'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<WebAiPanel>(find.byType(WebAiPanel)).cutoffOffset,
        expectedCutoff,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'adding bookmarks keeps adjacent pages and never toggles deletion',
    (WidgetTester tester) async {
      final _Library library = _Library();
      await open(tester, library);
      await tester.tap(find.byTooltip('打开阅读工具'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('添加书签'));
      await tester.pumpAndSettle();
      final WebReadingState reading = library.reading!;
      expect(reading.bookmarks, hasLength(1));
      final WebPersonalItem first = reading.bookmarks.single;
      await tester.tap(find.byTooltip('添加书签'));
      await tester.pumpAndSettle();
      expect(reading.bookmarks, hasLength(1));
      expect(find.text('这里已有书签'), findsOneWidget);
      await tester.tap(find.byTooltip('收起工具'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(380, 400));
      await tester.pumpAndSettle();
      expect(reading.fraction - first.fraction, greaterThan(0));
      expect(reading.fraction - first.fraction, lessThan(0.07));
      await tester.tap(find.byTooltip('打开阅读工具'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('添加书签'));
      await tester.pumpAndSettle();
      expect(reading.bookmarks, hasLength(2));
      expect(reading.bookmarks.first.id, first.id);
      expect(reading.bookmarks.every((mark) => !mark.deleted), isTrue);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '书签'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('删除书签'), findsNWidgets(2));
      await tester.tap(find.byTooltip('删除书签').first);
      await tester.pumpAndSettle();
      expect(reading.bookmarks, hasLength(1));
      expect(reading.bookmarks.single.id, isNot(first.id));
    },
  );

  for (final String label in <String>['人物', '问书']) {
    testWidgets('$label ignores repeated taps during a slow save', (
      tester,
    ) async {
      final _Library library = _Library();
      final navigator = await open(tester, library);
      final VoidCallback action = await panelAction(tester, label);
      final int before = library.saves;
      library.pendingSave = Completer<void>();
      action();
      action();
      expect(library.saves, before + 1);
      library.pendingSave!.complete();
      await tester.pumpAndSettle();
      expect(
        find.byType(label == '人物' ? WebAiPanel : WebAskPanel),
        findsOneWidget,
      );
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byType(WebAiPanel), findsNothing);
      expect(find.byType(WebAskPanel), findsNothing);
      expect(find.byType(WebReader), findsOneWidget);
    });

    testWidgets('$label does not reopen a reader dismissed during save', (
      tester,
    ) async {
      final _Library library = _Library();
      final navigator = await open(tester, library);
      final VoidCallback action = await panelAction(tester, label);
      library.pendingSave = Completer<void>();
      action();
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      library.pendingSave!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Shelf fixture'), findsOneWidget);
      expect(find.byType(WebAiPanel), findsNothing);
      expect(find.byType(WebAskPanel), findsNothing);
    });

    testWidgets('$label cancels stale cutoff after rewind during save', (
      tester,
    ) async {
      final _Library library = _Library();
      await open(tester, library, chapter: 1);
      final VoidCallback action = await panelAction(tester, label);
      library.pendingSave = Completer<void>();
      action();
      await tester.tap(find.widgetWithText(TextButton, '上一章'));
      await tester.pumpAndSettle();
      library.pendingSave!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(WebAiPanel), findsNothing);
      expect(find.byType(WebAskPanel), findsNothing);
      expect(find.text('Chapter 0'), findsWidgets);
    });
  }

  testWidgets('failed save is visible and panel can be retried', (
    tester,
  ) async {
    final _Library library = _Library();
    await open(tester, library);
    final VoidCallback action = await panelAction(tester, '问书');
    library.pendingSave = Completer<void>();
    action();
    library.pendingSave!.completeError(StateError('storage unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('当前阅读位置暂未保存，请检查浏览器存储空间后重试。'), findsOneWidget);
    expect(find.byType(WebAskPanel), findsNothing);
    library.pendingSave = null;
    action();
    await tester.pumpAndSettle();
    expect(find.byType(WebAskPanel), findsOneWidget);
  });
}
