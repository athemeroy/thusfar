import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/purification_store.dart';
import 'package:thusfar_app/main.dart';
import 'package:thusfar_app/reader/page_body.dart';
import 'package:thusfar_app/reader/paginator.dart';
import 'package:thusfar_app/reader/reader_controller.dart';
import 'package:thusfar_app/reader/text_purification.dart';
import 'package:thusfar_app/sheets/purification_sheet.dart';
import 'package:thusfar_app/sheets/sheet_host.dart';
import 'package:thusfar_app/ui/theme.dart';
import 'package:thusfar_core/notebook.dart' as notebook;

import 'support/viewport.dart';

PurificationRule rule(
  String find,
  String replacement, {
  String id = 'a',
  String? bookId,
  bool enabled = true,
}) => PurificationRule(
  id: id,
  find: find,
  replacement: replacement,
  bookId: bookId,
  enabled: enabled,
);

const PageSpec spec = PageSpec(
  width: 180,
  height: 100,
  fontSize: 16,
  lineHeight: 1.5,
  fontFamily: null,
  color: Colors.black,
  textScaler: TextScaler.noScaling,
);

void main() {
  test(
    'literal deletion preserves original coordinates and emoji boundaries',
    () {
      const String source = '😀广告甲😀乙广告丙';
      final PurifiedText text = TextPurifier(<PurificationRule>[
        rule('广告', ''),
      ]).apply(source);
      expect(text.text, '😀甲😀乙丙');
      expect(text.source, source);
      expect(text.sourceCharacter(0), (0, 2));
      expect(text.sourceCharacter(1), (0, 2));
      expect(text.sourceCharacter(2), (4, 5));
      expect(text.sourceCharacter(3), (5, 7));
      expect(text.sourceCharacter(4), (5, 7));
      expect(text.sourceStart(2), 4);
      expect(text.sourceEnd(2), 2);
      expect(source.substring(text.sourceStart(2), text.sourceEnd(6)), '甲😀乙');
      expect(text.displayStart(2), 2);
      expect(text.displayEnd(4), 2);
      expect(text.displayStart(8), 6);
      expect(text.displayEnd(10), 6);
      expect(validUtf16(text.text), isTrue);
    },
  );

  test(
    'shorter and longer replacements cite their complete original match',
    () {
      final PurifiedText text = TextPurifier(<PurificationRule>[
        rule('旧名字', '新😀名字'),
        rule('很长的广告', '短', id: 'b'),
      ]).apply('甲旧名字乙很长的广告丙');
      expect(text.text, '甲新😀名字乙短丙');
      for (int i = 1; i < 6; i++) {
        expect(text.sourceCharacter(i), (1, 4));
      }
      expect(text.sourceCharacter(7), (5, 10));
      expect(text.displayStart(2), 1);
      expect(text.displayEnd(3), 6);
      expect(text.sourceStart(6), 4);
      expect(text.sourceEnd(6), 4);
    },
  );

  test('overlap priority is deterministic, literal and never cascades', () {
    final PurifiedText text = TextPurifier(<PurificationRule>[
      rule('a.*', 'b'),
      rule('a', 'c', id: 'b'),
      rule('b', 'd', id: 'c'),
    ]).apply('a.* a b');
    expect(text.text, 'b c d');
    expect(
      TextPurifier(<PurificationRule>[
        rule('a', 'x'),
        rule('ab', 'y'),
      ]).apply('ab').text,
      'xb',
    );
    expect(
      TextPurifier(<PurificationRule>[
        rule('ab', 'y'),
        rule('a', 'x'),
      ]).apply('ab').text,
      'y',
    );
    expect(
      TextPurifier(<PurificationRule>[
        rule('ab', '', enabled: false),
      ]).apply('ab').text,
      'ab',
    );
  });

  test(
    'whole paragraph removal and edge deletions have valid empty mappings',
    () {
      final PurifiedText text = TextPurifier(<PurificationRule>[
        rule('😀广告', ''),
      ]).apply('😀广告');
      expect(text.text, isEmpty);
      expect(text.sourceCharacter(0), isNull);
      expect(text.displayStart(1), 0);
      expect(text.displayEnd(4), 0);
      final PurifiedText edges = TextPurifier(<PurificationRule>[
        rule('广告', ''),
      ]).apply('广告文字广告');
      expect(edges.sourceStart(0), 2);
      expect(edges.sourceEnd(2), 4);
      expect(edges.text, '文字');
    },
  );

  test(
    'invalid empty patterns, surrogate halves, multiline and amplification are rejected',
    () {
      for (final PurificationRule r in <PurificationRule>[
        rule('', ''),
        rule('\ud83d', ''),
        rule('a', '\udc00'),
        rule('a\nb', ''),
        rule('a', 'a' * 9),
        rule('a', '\n'),
      ]) {
        expect(r.error, isNotNull);
        expect(
          () => TextPurifier(<PurificationRule>[r]),
          throwsFormatException,
        );
      }
      expect(
        () => TextPurifier(
          List<PurificationRule>.generate(65, (i) => rule('$i', '')),
        ),
        throwsFormatException,
      );
    },
  );

  group('portable storage', () {
    late Directory root;
    late PurificationStore store;
    setUp(() {
      root = Directory.systemTemp.createTempSync('purification-store-');
      store = PurificationStore(File('${root.path}/rules.json'));
    });
    tearDown(() {
      store.dispose();
      root.deleteSync(recursive: true);
    });

    test('scope, edit, disable, order and deletion survive reopen', () {
      store.put(rule('a', 'x', bookId: 'one'));
      store.put(rule('ab', 'y', id: 'b'));
      store.put(rule('z', '', id: 'other', bookId: 'two'));
      expect(store.forBook('one').length, 2);
      store.move('b', -1, 'one');
      expect(TextPurifier(store.forBook('one')).apply('ab').text, 'y');
      store.put(rule('ab', 'new', id: 'b', enabled: false));
      final PurificationStore reopened = PurificationStore(store.file);
      expect(reopened.forBook('one').map((r) => r.id), <String>['b', 'a']);
      expect(reopened.rules.first.enabled, isFalse);
      expect(reopened.rules.first.replacement, 'new');
      reopened.remove('b');
      expect(reopened.forBook('two').length, 1);
      reopened.dispose();
    });

    test(
      'export rebinds book rules, retains global scope and skips duplicates',
      () {
        store.put(rule('广告', '', bookId: 'old'));
        store.put(rule('错字', '正字', id: 'global'));
        final String exported = store.exportForBook('old');
        expect(exported, isNot(contains('old')));
        final List<PurificationRule> preview = store.previewImport(
          exported,
          'new',
        );
        expect(preview.length, 1); // Existing global rule is not duplicated.
        expect(preview.single.bookId, 'new');
        expect(store.importForBook(exported, 'new'), 1);
        expect(store.importForBook(exported, 'new'), 0);
        expect(store.rules.length, 3);
        final String before = store.file.readAsStringSync();
        expect(
          () => store.importForBook('{broken', 'new'),
          throwsFormatException,
        );
        expect(store.file.readAsStringSync(), before);
      },
    );

    test('corruption is preserved and never silently overwritten', () {
      store.file.writeAsStringSync('{broken');
      final PurificationStore broken = PurificationStore(store.file);
      expect(broken.error, isNotNull);
      expect(() => broken.put(rule('a', '')), throwsStateError);
      expect(store.file.readAsStringSync(), '{broken');
      broken.dispose();
    });
  });

  group('reader integration', () {
    late Directory root;
    late AppModel model;
    late BookData book;
    const String first = '广告开头😀甲旧名字乙广告尾巴。';
    const String long = '甲旧名字乙广告尾巴。甲旧名字乙广告尾巴。甲旧名字乙广告尾巴。甲旧名字乙广告尾巴。';
    const String future = 'UNREAD_SECRET';
    setUp(() async {
      root = Directory.systemTemp.createTempSync('purification-reader-');
      final Directory dir = Directory('${root.path}/books/fixture')
        ..createSync(recursive: true);
      writeJson(File('${dir.path}/book.json'), <String, Object?>{
        'title': '净化测试书',
        'lang': 'zh',
        'len': first.length + long.length + future.length,
        'notes': <String, Object?>{},
        'blocks': <Json>[
          <String, Object?>{'k': 'p', 't': first, 'o': 0},
          <String, Object?>{'k': 'p', 't': long, 'o': first.length},
          <String, Object?>{
            'k': 'p',
            't': future,
            'o': first.length + long.length,
          },
        ],
        'chapters': <Json>[
          <String, Object?>{
            'title': '第一章',
            'kind': 'body',
            'b0': 0,
            'b1': 2,
            'o0': 0,
            'o1': first.length + long.length,
          },
          <String, Object?>{
            'title': '未读章',
            'kind': 'body',
            'b0': 2,
            'b1': 3,
            'o0': first.length + long.length,
            'o1': first.length + long.length + future.length,
          },
        ],
      });
      writeJson(File('${dir.path}/status.json'), <String, Object?>{
        'state': 'idle',
      });
      model = AppModel(root);
      await model.library.scan();
      book = BookData.open(model.library.books.single);
    });
    tearDown(() {
      book.notes.dispose();
      book.dispose();
      model.dispose();
      root.deleteSync(recursive: true);
    });

    testWidgets(
      'pagination, source quotes, notes and rule changes keep source anchors',
      (tester) async {
        final String original = File(
          '${book.entry.dir.path}/book.json',
        ).readAsStringSync();
        final Paginator plain = Paginator(book, spec);
        final List<PurificationRule> rules = <PurificationRule>[
          rule('广告', ''),
          rule('旧名字', '新😀名字', id: 'b'),
        ];
        final Paginator purified = Paginator(book, spec, rules: rules);
        final List<PageData> pages = purified.pages(0);
        final String displayed = pages
            .expand((p) => p.frags)
            .map(
              (f) => purified
                  .textFor(book.blocks[f.block])
                  .text
                  .substring(f.displayStart, f.displayEnd),
            )
            .join();
        expect(
          displayed,
          TextPurifier(rules).apply(first).text +
              TextPurifier(rules).apply(long).text,
        );
        for (final PageData page in pages) {
          expect(page.start, greaterThanOrEqualTo(0));
          expect(page.end, lessThanOrEqualTo(first.length + long.length));
          for (final Frag fragment in page.frags) {
            final PurifiedText mapped = purified.textFor(
              book.blocks[fragment.block],
            );
            expect(
              validUtf16(
                mapped.text.substring(
                  fragment.displayStart,
                  fragment.displayEnd,
                ),
              ),
              isTrue,
            );
          }
        }
        final PurifiedText mapped = purified.textFor(book.blocks.first);
        final (int start, int end) = mapped.sourceCharacter(
          mapped.text.indexOf('新'),
        )!;
        expect(notebook.sourceQuote(book.book, start, end), '旧名字');
        final ReaderController controller = ReaderController(
          library: model.library,
          book: book,
        );
        controller.layout(purified, start);
        controller.select((start, end));
        final Json note = book.notes.save(
          kind: 'note',
          start: start,
          end: end,
          cutoff: controller.cutoff,
        );
        expect(note['quote'], '旧名字');
        final int anchor = pages.last.start;
        model.library.saveProgress(
          book.id,
          anchor,
          pages.last.end,
          book.length,
        );
        final Json saved = model.library.progressOf(book.id)!.toJson();
        controller.layout(purified, anchor);
        controller.layout(plain, anchor);
        expect(controller.start, lessThanOrEqualTo(anchor));
        expect(controller.cutoff, greaterThan(anchor));
        expect(model.library.progressOf(book.id)!.toJson(), saved);
        expect(
          File('${book.entry.dir.path}/book.json').readAsStringSync(),
          original,
        );
        controller.dispose();
      },
    );

    testWidgets(
      'whole chapter deletion remains navigable without revealing next chapter',
      (tester) async {
        final Paginator pager = Paginator(
          book,
          spec,
          rules: <PurificationRule>[
            rule(first, ''),
            rule(long, '', id: 'b'),
          ],
        );
        final PageData empty = pager.pages(0).single;
        expect(empty.frags, isEmpty);
        expect(empty.end, 0);
        expect(pager.totalPages().$1, greaterThan(0));
        final ReaderController controller = ReaderController(
          library: model.library,
          book: book,
        )..layout(pager, 0);
        expect(controller.pageAt(ReaderController.base + 1)?.chapter, 1);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(Brightness.light),
            home: Scaffold(
              body: PageBody(
                page: empty,
                pager: pager,
                layers: const PageLayers(
                  world: null,
                  cutoff: 0,
                  notes: <Json>[],
                ),
                onName: (_) {},
              ),
            ),
          ),
        );
        expect(find.textContaining('本章没有可显示'), findsOneWidget);
        expect(find.textContaining(future), findsNothing);
        controller.dispose();
      },
    );

    testWidgets(
      'editor previews current-page source, saves scope and returns, then toggles and deletes',
      (tester) async {
        final PurificationStore store = PurificationStore(
          File('${root.path}/text-purification.json'),
        );
        final ScrollController scroll = ScrollController();
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(Brightness.light),
            home: Scaffold(
              body: SheetFrame(
                scroll: scroll,
                root: PurificationPage(
                  store: store,
                  bookId: book.id,
                  samples: const <String>[first],
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('添加规则'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey<String>('purification-find')),
          '广告',
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Text>(
                find.byKey(const ValueKey<String>('purification-preview')),
              )
              .data,
          '开头😀甲旧名字乙尾巴。',
        );
        expect(find.textContaining(future), findsNothing);
        await tester.ensureVisible(find.text('保存规则'));
        await tester.tap(find.text('保存规则'));
        await tester.pumpAndSettle();
        expect(store.rules.single.bookId, book.id);
        expect(find.text('编辑与预览'), findsOneWidget);
        await tester.tap(find.byType(Switch).first);
        await tester.pumpAndSettle();
        expect(store.rules.single.enabled, isFalse);
        await tester.tap(find.byTooltip('删除规则'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(store.rules.length, 1);
        await tester.tap(find.byTooltip('删除规则'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除'));
        await tester.pumpAndSettle();
        expect(store.rules, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        scroll.dispose();
        store.dispose();
      },
    );

    testWidgets(
      'mapped long press and handle select source, create a book rule and cancel safely',
      (tester) async {
        await setTestViewport(tester, const Size(430, 900));
        addTearDown(() => setTestViewport(tester, null));
        final PurificationStore store = PurificationStore(
          File('${root.path}/text-purification.json'),
        );
        store.put(rule('广告', '', bookId: book.id));
        store.put(rule('旧名字', '新😀名字', id: 'b', bookId: book.id));
        store.dispose();
        await tester.pumpWidget(ThusfarApp(model: model));
        await tester.pumpAndSettle();
        await tester.tap(find.text('净化测试书').first);
        await tester.pumpAndSettle();
        PageBody body() => tester.widget<PageBody>(find.byType(PageBody).first);
        final PurifiedText mapped = body().pager.textFor(
          body().pager.book.blocks.first,
        );
        final TextPainter painter = body().pager.painterFor(
          body().pager.book.blocks.first,
        );
        Offset point(int display) => painter.getOffsetForCaret(
          TextPosition(offset: display + indentShift),
          Rect.zero,
        );
        final int display = mapped.text.indexOf('新');
        final Offset pageOrigin = tester.getTopLeft(
          find.byType(PageBody).first,
        );
        await tester.longPressAt(
          pageOrigin + point(display) + Offset(1, body().pager.spec.line / 2),
        );
        await tester.pumpAndSettle();
        final (int start, int originalEnd) = body().layers.selection!;
        expect(start, greaterThanOrEqualTo(body().page.start));
        expect(originalEnd, lessThanOrEqualTo(body().page.end));
        expect(book.textBetween(start, originalEnd), contains('旧名字'));
        expect(
          find.byKey(const ValueKey<String>('reader-selection-start')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey<String>('reader-selection-end')),
          findsOneWidget,
        );
        final TestGesture drag = await tester.startGesture(
          tester.getCenter(
            find.byKey(const ValueKey<String>('reader-selection-end')),
          ),
        );
        await drag.moveBy(const Offset(1, 0));
        await drag.moveBy(
          point(display + 1) - point(mapped.displayEnd(originalEnd) - 1),
        );
        await drag.up();
        await tester.pumpAndSettle();
        final int end = body().layers.selection!.$2;
        expect(end, first.indexOf('旧名字') + '旧名字'.length);
        await tester.tap(find.text('净化'));
        await tester.pumpAndSettle();
        final TextField field = tester.widget<TextField>(
          find.byKey(const ValueKey<String>('purification-find')),
        );
        expect(field.controller!.text, book.textBetween(start, end));
        final SwitchListTile scope = tester.widget<SwitchListTile>(
          find.byType(SwitchListTile),
        );
        expect(scope.value, isFalse);
        expect(find.textContaining(future), findsNothing);
        await tester.tap(find.byTooltip('关闭阅读工具'));
        await tester.pumpAndSettle();
        expect(find.byType(PurificationEditor), findsNothing);
        final PurificationStore reopened = PurificationStore(
          File('${root.path}/text-purification.json'),
        );
        expect(reopened.rules.length, 2);
        reopened.dispose();
        expect(tester.takeException(), isNull);
        painter.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'purified semantic text excludes later display fragments and removed source',
      (tester) async {
        final Paginator pager = Paginator(
          book,
          spec,
          rules: <PurificationRule>[
            rule('广告', ''),
            rule('旧名字', '替换😀', id: 'b'),
          ],
        );
        final PageData page = pager.pages(0).first;
        final SemanticsHandle semantics = tester.ensureSemantics();
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(Brightness.light),
            home: Scaffold(
              body: PageBody(
                page: page,
                pager: pager,
                layers: PageLayers(
                  world: null,
                  cutoff: page.end,
                  notes: const <Json>[],
                ),
                onName: (_) {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final List<RichText> texts = tester
            .widgetList<RichText>(
              find.descendant(
                of: find.byType(PageBody),
                matching: find.byType(RichText),
              ),
            )
            .toList();
        final String spoken = texts
            .map((text) => text.text.toPlainText())
            .join();
        expect(spoken, isNot(contains('广告')));
        expect(spoken, isNot(contains('旧名字')));
        expect(spoken, isNot(contains(future)));
        for (int i = 0; i < page.frags.length; i++) {
          final Frag fragment = page.frags[i];
          final String visible = pager
              .textFor(book.blocks[fragment.block])
              .text
              .substring(fragment.displayStart, fragment.displayEnd);
          expect(texts[i].text.toPlainText().replaceAll('\uFFFC', ''), visible);
        }
        expect(tester.takeException(), isNull);
        semantics.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('editor remains usable on small phone at double text scale', (
      tester,
    ) async {
      await setTestViewport(tester, const Size(320, 568));
      addTearDown(() => setTestViewport(tester, null));
      final PurificationStore store = PurificationStore(
        File('${root.path}/text-purification.json'),
      );
      final ScrollController scroll = ScrollController();
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
            body: SheetFrame(
              scroll: scroll,
              root: PurificationEditor(
                store: store,
                bookId: book.id,
                samples: const <String>[first],
                initialFind: '广告',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('保存规则'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('保存规则').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      scroll.dispose();
      store.dispose();
    });

    testWidgets(
      'saving and toggling a rule repaginates live reader without rewriting progress',
      (tester) async {
        model.library.saveProgress(book.id, 0, first.length, book.length);
        final Json saved = model.library.progressOf(book.id)!.toJson();
        await tester.pumpWidget(ThusfarApp(model: model));
        await tester.pumpAndSettle();
        await tester.tap(find.text('净化测试书').first);
        await tester.pumpAndSettle();
        PageBody body() => tester.widget<PageBody>(find.byType(PageBody).first);
        final Rect rect = tester.getRect(
          find.byKey(const ValueKey<String>('reader-page-viewport')),
        );
        await tester.tapAt(rect.center);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('更多操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('文本净化'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('添加规则'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey<String>('purification-find')),
          '广告',
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('保存规则'),
          200,
          scrollable: find
              .descendant(
                of: find.byType(PurificationEditor),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.tap(find.text('保存规则'));
        await tester.pumpAndSettle();
        expect(
          body().pager.textFor(body().pager.book.blocks.first).text,
          isNot(contains('广告')),
        );
        expect(model.library.progressOf(book.id)!.toJson(), saved);
        await tester.tap(find.byType(Switch).first);
        await tester.pumpAndSettle();
        expect(
          body().pager.textFor(body().pager.book.blocks.first).text,
          first,
        );
        expect(model.library.progressOf(book.id)!.toJson(), saved);
        await tester.tap(find.byTooltip('关闭阅读工具'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    for (final double scale in <double>[1, 2]) {
      testWidgets(
        'wrapped selection actions stay clear of the selected text at $scale scale',
        (tester) async {
          await setTestViewport(tester, Size(scale == 1 ? 360 : 320, 740));
          addTearDown(() => setTestViewport(tester, null));
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await tester.pumpWidget(ThusfarApp(model: model));
          await tester.pumpAndSettle();
          await tester.tap(find.text('净化测试书').first);
          await tester.pumpAndSettle();
          final PageBody body = tester.widget<PageBody>(
            find.byType(PageBody).first,
          );
          final TextPainter painter = body.pager.painterFor(
            body.pager.book.blocks[1],
          );
          final Offset caret = painter.getOffsetForCaret(
            const TextPosition(offset: 16 + indentShift),
            Rect.zero,
          );
          final Offset point =
              tester.getTopLeft(find.byType(PageBody).first) +
              caret +
              Offset(
                1,
                body.page.frags.first.lines * body.pager.spec.line +
                    body.pager.spec.line / 2,
              );
          painter.dispose();
          await tester.longPressAt(point);
          await tester.pumpAndSettle();
          final Rect actions = tester.getRect(
            find.byKey(const ValueKey<String>('reader-selection-actions')),
          );
          expect(actions.bottom, lessThan(point.dy));
          expect(actions.contains(point), isFalse);
          expect(actions.left, greaterThanOrEqualTo(16));
          expect(
            actions.right,
            lessThanOrEqualTo((scale == 1 ? 360 : 320) - 16),
          );
          expect(actions.top, greaterThanOrEqualTo(0));
          expect(actions.bottom, lessThanOrEqualTo(740));
          expect(find.text('净化').hitTestable(), findsOneWidget);
          expect(find.text('复制').hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }

    testWidgets('manager is reachable from more menu', (tester) async {
      await tester.pumpWidget(ThusfarApp(model: model));
      await tester.pumpAndSettle();
      await tester.tap(find.text('净化测试书').first);
      await tester.pumpAndSettle();
      final Finder viewport = find.byKey(
        const ValueKey<String>('reader-page-viewport'),
      );
      final Rect rect = tester.getRect(viewport);
      await tester.tapAt(rect.center);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('文本净化'));
      await tester.pumpAndSettle();
      expect(find.text('添加规则'), findsOneWidget);
      expect(find.textContaining(future), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
