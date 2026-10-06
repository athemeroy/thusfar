import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/purification_store.dart';
import 'package:thusfar_app/main.dart';
import 'package:thusfar_app/reader/page_body.dart';
import 'package:thusfar_app/reader/paginator.dart';
import 'package:thusfar_app/reader/reader_controller.dart';
import 'package:thusfar_app/reader/text_purification.dart';
import 'package:thusfar_app/ui/theme.dart';

import 'support/viewport.dart';

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

  late Directory root;
  late AppModel model;
  late BookData book;
  final List<String> source = <String>[
    '第一段。清风吹过小院。',
    '  第二段有 广告 和名字。读者留下😀原文摘录。\n换行仍是同一段。',
    '整段删除',
    '正文带有空格与\t制表符。' * 30,
    '末段。',
  ];
  final List<PurificationRule> rules = <PurificationRule>[
    const PurificationRule(id: 'remove', find: '广告', replacement: ''),
    const PurificationRule(id: 'replace', find: '名字', replacement: '张三李四'),
    const PurificationRule(id: 'paragraph', find: '整段删除', replacement: ''),
  ];
  setUp(() async {
    root = Directory.systemTemp.createTempSync('paragraph-layout-');
    final Directory directory = Directory('${root.path}/books/paragraph')
      ..createSync(recursive: true);
    int offset = 0;
    final List<Json> blocks = <Json>[];
    for (final String text in source) {
      blocks.add(<String, Object?>{'k': 'p', 't': text, 'o': offset});
      offset += text.length;
    }
    writeJson(File('${directory.path}/book.json'), <String, Object?>{
      'title': '段落排版测试',
      'lang': 'zh',
      'len': offset,
      'notes': <String, Object?>{},
      'blocks': blocks,
      'chapters': <Json>[
        <String, Object?>{
          'title': '第一章',
          'kind': 'body',
          'b0': 0,
          'b1': blocks.length,
          'o0': 0,
          'o1': offset,
        },
      ],
    });
    writeJson(File('${directory.path}/status.json'), <String, Object?>{
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

  PageSpec spec({
    double gap = 0,
    double indent = 2,
    double width = 320,
    double height = 500,
    double fontSize = 19,
    double leading = 1.85,
    String family = 'NotoSerifSC',
    double scale = 1,
  }) => PageSpec(
    width: width,
    height: height,
    fontSize: fontSize,
    lineHeight: leading,
    paragraphSpacing: gap,
    firstLineIndent: indent,
    fontFamily: family,
    color: Colors.black,
    textScaler: TextScaler.linear(scale),
  );

  test('paragraph metrics are independent and part of layout identity', () {
    final PageSpec plain = spec();
    expect(plain, spec());
    expect(plain, isNot(spec(gap: 0.5)));
    expect(plain, isNot(spec(indent: 0)));
    expect(
      spec(gap: 0.75, leading: 1.2).paragraphGap,
      spec(gap: 0.75, leading: 2.4).paragraphGap,
    );
    expect(indentWidth(plain), 38);
    expect(indentWidth(spec(indent: 0)), 0);
    expect(indentWidth(spec(indent: 4, width: 80, fontSize: 32, scale: 2)), 16);
  });

  testWidgets('old default page geometry remains unchanged', (tester) async {
    final PageSpec legacy = PageSpec(
      width: 320,
      height: 500,
      fontSize: 19,
      lineHeight: 1.85,
      fontFamily: 'NotoSerifSC',
      color: Colors.black,
      textScaler: TextScaler.linear(1),
    );
    List<Object> geometry(Paginator pager) => <Object>[
      for (final PageData page in pager.pages(0))
        <Object>[
          page.start,
          page.end,
          for (final Frag fragment in page.frags)
            <Object>[
              fragment.block,
              fragment.start,
              fragment.end,
              fragment.top,
              fragment.lines,
              fragment.leading,
            ],
        ],
    ];
    expect(
      geometry(Paginator(book, legacy)),
      geometry(Paginator(book, spec())),
    );
  });

  for (final String family in <String>[
    'NotoSerifSC',
    'LXGWWenKaiScreen',
    'NotoSansSC',
  ]) {
    for (final double indent in <double>[0, 2, 4]) {
      testWidgets(
        'bounded spacing preserves every purified character: $family indent $indent',
        (tester) async {
          final PageSpec layout = spec(
            gap: 2,
            indent: indent,
            width: 170,
            height: 320,
            fontSize: 32,
            scale: 1.6,
            family: family,
          );
          final Paginator pager = Paginator(book, layout, rules: rules);
          final List<PageData> pages = pager.pages(0);
          expect(pages.length, greaterThan(2));
          for (final PageData page in pages) {
            expect(page.frags.first.leading, 0);
            expect(
              page.frags.fold<double>(
                0,
                (sum, frag) => sum + frag.height(layout),
              ),
              lessThanOrEqualTo(layout.height + 0.000001),
            );
            for (final Frag frag in page.frags) {
              expect(frag.displayEnd, greaterThan(frag.displayStart));
              if (frag.displayStart > 0) expect(frag.leading, 0);
            }
          }
          for (int block = 0; block < book.blocks.length; block++) {
            final String displayed = pages
                .expand((page) => page.frags)
                .where((frag) => frag.block == block)
                .map(
                  (frag) => pager
                      .textFor(book.blocks[block])
                      .text
                      .substring(frag.displayStart, frag.displayEnd),
                )
                .join();
            expect(displayed, pager.textFor(book.blocks[block]).text);
            expect(book.blocks[block].text, source[block]);
          }
        },
      );
    }
  }

  testWidgets(
    'citation jumps stay at first source occurrence after expansion and spacing',
    (tester) async {
      final String original = source.first;
      final Paginator pager = Paginator(
        book,
        spec(gap: 2, indent: 4, width: 170, height: 180, fontSize: 32),
        rules: <PurificationRule>[
          PurificationRule(
            id: 'expanded',
            find: original,
            replacement: '扩展显示文字。' * 12,
          ),
          ...rules,
        ],
      );
      final ReaderController controller = ReaderController(
        library: model.library,
        book: book,
      )..layout(pager, 0);
      addTearDown(controller.dispose);
      expect(pager.pages(0).length, greaterThan(3));
      expect(controller.page!.index, 0);
      controller.onPage(ReaderController.base + 2);
      expect(controller.page!.index, 2);
      controller.jump(0, remember: false);
      expect(controller.page!.index, 0);
      controller.jump(book.blocks[2].o, remember: false);
      expect(controller.page!.frags.any((frag) => frag.block == 3), isTrue);
      expect(pager.textFor(book.blocks.first).sourceCharacter(12), (
        0,
        original.length,
      ));
    },
  );

  testWidgets('body uses the paginator gap and matching first-line painter', (
    tester,
  ) async {
    final Paginator pager = Paginator(
      book,
      spec(gap: 1, indent: 0),
      rules: rules,
    );
    final PageData page = pager.pages(0).first;
    expect(page.frags[1].leading, 19);
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
    final List<RenderParagraph> paragraphs = tester
        .renderObjectList<RenderParagraph>(
          find.descendant(
            of: find.byType(PageBody),
            matching: find.byType(RichText),
          ),
        )
        .toList();
    double y = 0;
    for (int i = 0; i < page.frags.length; i++) {
      final Frag frag = page.frags[i];
      final RenderParagraph rendered = paragraphs[i];
      final TextPainter measured = pager.painterFor(book.blocks[frag.block]);
      expect(
        rendered.localToGlobal(Offset.zero).dy,
        closeTo(y + frag.leading - frag.top, 0.000001),
      );
      expect(
        rendered.getOffsetForCaret(
          const TextPosition(offset: indentShift),
          Rect.zero,
        ),
        measured.getOffsetForCaret(
          const TextPosition(offset: indentShift),
          Rect.zero,
        ),
      );
      measured.dispose();
      y += frag.height(pager.spec);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final bool folded in <bool>[false, true]) {
    testWidgets(
      'gap hit-testing and selection handles retain source quotes; folded=$folded',
      (tester) async {
        await setTestViewport(
          tester,
          folded ? const Size(840, 900) : const Size(360, 780),
        );
        addTearDown(() => setTestViewport(tester, null));
        if (folded) {
          tester.view.displayFeatures = const <ui.DisplayFeature>[
            ui.DisplayFeature(
              bounds: Rect.fromLTWH(80, 0, 20, 900),
              type: ui.DisplayFeatureType.hinge,
              state: ui.DisplayFeatureState.postureHalfOpened,
            ),
          ];
          addTearDown(tester.view.resetDisplayFeatures);
        }
        model.prefs.update((p) {
          p.paragraphSpacing = 2;
          p.firstLineIndent = 0;
        });
        final PurificationStore store = PurificationStore(
          File('${root.path}/text-purification.json'),
        );
        for (final PurificationRule rule in rules) {
          store.put(rule);
        }
        store.dispose();
        await tester.pumpWidget(ThusfarApp(model: model));
        await tester.pumpAndSettle();
        await tester.tap(find.text('段落排版测试').first);
        await tester.pumpAndSettle();
        PageBody body() => tester.widget<PageBody>(find.byType(PageBody).first);
        final PageBody initial = body();
        final Frag second = initial.page.frags[1];
        final double preceding = initial.page.frags.first.height(
          initial.pager.spec,
        );
        final Offset origin = tester.getTopLeft(find.byType(PageBody).first);
        // Blank paragraph space has no source character and must not select one.
        await tester.longPressAt(
          origin + Offset(40, preceding + second.leading / 2),
        );
        await tester.pumpAndSettle();
        expect(body().layers.selection, isNull);
        final Block block = initial.pager.book.blocks[second.block];
        final TextPainter painter = initial.pager.painterFor(block);
        Offset point(int display) =>
            origin +
            painter.getOffsetForCaret(
              TextPosition(offset: display + indentShift),
              Rect.zero,
            ) +
            Offset(
              2,
              preceding +
                  second.leading -
                  second.top +
                  initial.pager.spec.line / 2,
            );
        final int name = initial.pager.textFor(block).text.indexOf('张三李四');
        await tester.longPressAt(point(name + 1));
        await tester.pumpAndSettle();
        final (int, int) selected = body().layers.selection!;
        expect(
          selected.$1,
          lessThanOrEqualTo(block.o + source[1].indexOf('名字')),
        );
        expect(
          selected.$2,
          greaterThanOrEqualTo(block.o + source[1].indexOf('名字') + 2),
        );
        final Finder handle = find.byKey(
          const ValueKey<String>('reader-selection-end'),
        );
        expect(handle, findsOneWidget);
        final TestGesture drag = await tester.startGesture(
          tester.getCenter(handle),
        );
        await drag.moveBy(const Offset(12, 0));
        await drag.up();
        await tester.pumpAndSettle();
        final (int, int) adjusted = body().layers.selection!;
        final String quote = initial.pager.book.textBetween(
          adjusted.$1,
          adjusted.$2,
        );
        await tester.tap(find.text('摘录'));
        await tester.pumpAndSettle();
        expect(initial.pager.book.notes.notes.single['quote'], quote);
        expect(quote, isNot(contains('张三李四')));
        painter.dispose();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'repeated typography changes keep a source anchor and persisted progress',
    (tester) async {
      await setTestViewport(tester, const Size(320, 740));
      addTearDown(() => setTestViewport(tester, null));
      final int anchor = book.blocks[3].o + 100;
      model.library.saveProgress(book.id, anchor, anchor + 15, book.length);
      final Json saved = model.library.progressOf(book.id)!.toJson();
      await tester.pumpWidget(ThusfarApp(model: model));
      await tester.pumpAndSettle();
      await tester.tap(find.text('段落排版测试').first);
      await tester.pumpAndSettle();
      PageBody body() => tester.widget<PageBody>(find.byType(PageBody).first);
      final int initialStart = body().page.start;
      for (int round = 0; round < 3; round++) {
        model.prefs.update((p) {
          p.paragraphSpacing = 2;
          p.firstLineIndent = round.toDouble() * 2;
          p.fontSize = 32;
          p.font = round;
        });
        await tester.pumpAndSettle();
        expect(body().page.start, lessThanOrEqualTo(anchor));
        expect(body().page.end, greaterThan(anchor));
        expect(model.library.progressOf(book.id)!.toJson(), saved);
        model.prefs.update((p) {
          p.paragraphSpacing = 0;
          p.firstLineIndent = 2;
          p.fontSize = 19;
          p.font = 0;
        });
        await tester.pumpAndSettle();
        expect(body().page.start, initialStart);
        expect(model.library.progressOf(book.id)!.toJson(), saved);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
