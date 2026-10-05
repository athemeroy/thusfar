import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/reader/image_viewer.dart';
import 'package:thusfar_app/reader/paginator.dart';
import 'package:thusfar_app/reader/reader_controller.dart';
import 'package:thusfar_app/sheets/common.dart';
import 'package:thusfar_app/sheets/search_sheet.dart';
import 'package:thusfar_app/reader/source_search.dart';
import 'package:thusfar_app/reader/source_selection.dart';
import 'package:thusfar_app/sheets/sheet_host.dart';
import 'package:thusfar_app/ui/theme.dart';

void main() {
  test(
    'source search enumerates over 500 occurrences with original Unicode offsets',
    () async {
      final String text =
          'İ ${List<String>.filled(1200, 'needle 😀 ').join()}UNREAD needle';
      final int cutoff = text.indexOf('UNREAD');
      final List<SourceSearchHit> hits = await searchSourceText(
        <SourceSearchBlock>[
          SourceSearchBlock(chapter: 0, block: 0, start: 0, text: text),
        ],
        'NEEDLE',
        cutoff,
      );
      expect(hits, hasLength(1200));
      expect(hits.first.start, 2);
      expect(hits.last.start, text.lastIndexOf('needle', cutoff));
      for (final SourceSearchHit hit in hits) {
        expect(
          text.substring(hit.start, hit.start + hit.match.length),
          'needle',
        );
        expect(hit.after, isNot(contains('UNREAD')));
      }
      expect(
        await searchSourceText(
          <SourceSearchBlock>[
            SourceSearchBlock(chapter: 0, block: 0, start: 0, text: text),
          ],
          'needle',
          text.length,
          cancelled: () => true,
        ),
        isEmpty,
      );
    },
  );

  test(
    'source selection spans visible paragraphs and rejects ambiguity or hidden gaps',
    () {
      final SourceSelection? selection = resolveSourceSelection(
        'first  paragraph\nsecond 😀',
        const <SourceSlice>[
          SourceSlice(text: 'first paragraph', start: 10),
          SourceSlice(text: 'second 😀 sentence', start: 25),
        ],
      );
      expect(selection?.start, 10);
      expect(selection?.end, 34);
      expect(selection?.text, 'first paragraph\nsecond 😀');
      expect(
        resolveSourceSelection('same', const <SourceSlice>[
          SourceSlice(text: 'same same', start: 0),
        ]),
        isNull,
      );
      expect(
        resolveSourceSelection('first second', const <SourceSlice>[
          SourceSlice(text: 'first', start: 0),
          SourceSlice(text: 'second', start: 40),
        ]),
        isNull,
      );
      expect(
        resolveSourceSelection('hidden', const <SourceSlice>[
          SourceSlice(text: 'visible', start: 0),
        ]),
        isNull,
      );
      expect(
        resolveSourceSelection('\ude00', const <SourceSlice>[
          SourceSlice(text: '😀', start: 0),
        ]),
        isNull,
      );
    },
  );

  test('theme color is part of the pagination paint cache identity', () {
    PageSpec spec(Color color) => PageSpec(
      width: 300,
      height: 400,
      fontSize: 18,
      lineHeight: 1.7,
      fontFamily: null,
      color: color,
      textScaler: TextScaler.noScaling,
    );
    expect(spec(Colors.black), isNot(spec(Colors.white)));
    expect(spec(Colors.black), spec(Colors.black));
    expect(<PageSpec>{spec(Colors.black), spec(Colors.white)}, hasLength(2));
  });

  testWidgets(
    'short pages split long headings and fit illustrations without missing source',
    (tester) async {
      final Directory root = Directory.systemTemp.createTempSync(
        'reading-layout-',
      );
      final String title = List<String>.filled(
        40,
        'Very long heading',
      ).join(' ');
      final Json raw = <String, Object?>{
        'title': title,
        'lang': 'en',
        'len': title.length + 4,
        'notes': <String, Object?>{},
        'blocks': <Json>[
          <String, Object?>{'k': 'h', 'o': 0, 't': title},
          <String, Object?>{
            'k': 'img',
            'o': title.length,
            't': '',
            'src': 'image.png',
          },
          <String, Object?>{'k': 'p', 'o': title.length, 't': 'Body'},
        ],
        'chapters': <Json>[
          <String, Object?>{
            'title': title,
            'kind': 'body',
            'b0': 0,
            'b1': 3,
            'o0': 0,
            'o1': title.length + 4,
          },
        ],
      };
      File('${root.path}/book.json').writeAsStringSync(jsonEncode(raw));
      final BookData book = BookData.open(
        BookEntry(
          id: 'layout',
          dir: root,
          meta: raw,
          status: const ProcessStatus(<String, Object?>{}),
          added: 0,
        ),
      );
      addTearDown(() {
        book.notes.dispose();
        book.dispose();
        root.deleteSync(recursive: true);
      });
      final Paginator pager = Paginator(
        book,
        const PageSpec(
          width: 180,
          height: 80,
          fontSize: 20,
          lineHeight: 1.7,
          fontFamily: null,
          color: Colors.black,
          textScaler: TextScaler.noScaling,
        ),
      );
      final List<PageData> pages = pager.pages(0);
      final List<Frag> titles = pages
          .expand((page) => page.frags)
          .where((frag) => frag.block == 0)
          .toList();
      expect(titles.length, greaterThan(2));
      expect(
        titles.map((frag) => title.substring(frag.start, frag.end)).join(),
        title,
      );
      for (final PageData page in pages) {
        expect(
          page.frags.fold(0, (int sum, Frag frag) => sum + frag.lines),
          lessThanOrEqualTo(pager.spec.linesPerPage),
        );
      }
      expect(
        pages
            .expand((page) => page.frags)
            .singleWhere((frag) => frag.image)
            .lines,
        lessThanOrEqualTo(2),
      );
    },
  );

  testWidgets(
    'image zoom resets and Escape closes without a reading side effect',
    (tester) async {
      // Transparent 1x1 fixture, no file or network dependency.
      final MemoryImage image = MemoryImage(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => openReaderImage(
                  context,
                  image,
                  label: 'Local illustration',
                ),
                child: const Text('Open image'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open image'));
      await tester.pumpAndSettle();
      expect(find.text('Local illustration'), findsOneWidget);
      final InteractiveViewer viewer = tester.widget<InteractiveViewer>(
        find.byKey(const ValueKey<String>('reader-image-zoom')),
      );
      viewer.transformationController!.value = Matrix4.diagonal3Values(3, 3, 1);
      await tester.tap(find.byTooltip('还原图片大小'));
      expect(viewer.transformationController!.value, Matrix4.identity());
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ReaderImageViewer), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final Size size in <Size>[const Size(390, 844), const Size(1440, 900)]) {
    testWidgets(
      'drawer preserves input and scroll across repeated nested visits at $size',
      (tester) async {
        tester.view
          ..physicalSize = size
          ..devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(Brightness.light),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => openSheet<void>(
                    context,
                    SheetPage(
                      title: 'Root',
                      slivers: <Widget>[
                        const SliverToBoxAdapter(
                          child: TextField(
                            key: ValueKey<String>('retained-input'),
                          ),
                        ),
                        SliverList.builder(
                          itemCount: 60,
                          itemBuilder: (_, index) =>
                              SizedBox(height: 40, child: Text('Row $index')),
                        ),
                      ],
                    ),
                    full: true,
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey<String>('retained-input')),
          'Keep this query',
        );
        FocusManager.instance.primaryFocus?.unfocus();
        final SheetFrame frame = tester.widget<SheetFrame>(
          find.byType(SheetFrame),
        );
        frame.scroll.jumpTo(350);
        await tester.pumpAndSettle();
        final double original = frame.scroll.offset;
        final SheetFrameState state = tester.state<SheetFrameState>(
          find.byType(SheetFrame),
        );
        for (int visit = 0; visit < 3; visit++) {
          state.push(const SheetPage(title: 'Details', slivers: <Widget>[]));
          await tester.pumpAndSettle();
          expect(find.text('Details'), findsOneWidget);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.text('Root'), findsOneWidget);
          expect(frame.scroll.offset, closeTo(original, 1));
          frame.scroll.jumpTo(0);
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<TextField>(
                  find.byKey(const ValueKey<String>('retained-input')),
                )
                .controller,
            isNull,
          );
          expect(find.text('Keep this query'), findsOneWidget);
          frame.scroll.jumpTo(original);
          await tester.pumpAndSettle();
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(SheetFrame), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'search waits for IME commit, reaches result 650, and clips after rewind',
    (tester) async {
      final Directory root = Directory.systemTemp.createTempSync(
        'reading-search-',
      );
      final String text = List<String>.filled(650, 'needle ').join();
      final Json raw = <String, Object?>{
        'title': 'Search fixture',
        'lang': 'en',
        'len': text.length,
        'notes': <String, Object?>{},
        'blocks': <Json>[
          <String, Object?>{'k': 'p', 'o': 0, 't': text},
        ],
        'chapters': <Json>[
          <String, Object?>{
            'title': 'First',
            'kind': 'body',
            'b0': 0,
            'b1': 1,
            'o0': 0,
            'o1': text.length,
          },
        ],
      };
      File('${root.path}/book.json').writeAsStringSync(jsonEncode(raw));
      final BookData book = BookData.open(
        BookEntry(
          id: 'search',
          dir: root,
          meta: raw,
          status: const ProcessStatus(<String, Object?>{}),
          added: 0,
        ),
      );
      final Library library = Library(root);
      final ReaderController reader = ReaderController(
        library: library,
        book: book,
      );
      final ScrollController scroll = ScrollController();
      reader.layout(
        Paginator(
          book,
          const PageSpec(
            width: 350,
            height: 600,
            fontSize: 18,
            lineHeight: 1.7,
            fontFamily: null,
            color: Colors.black,
            textScaler: TextScaler.noScaling,
          ),
        ),
        0,
      );
      reader.page = PageData(
        chapter: 0,
        index: 0,
        frags: <Frag>[],
        start: 0,
        end: text.length,
      );
      addTearDown(() {
        reader.dispose();
        library.dispose();
        book.notes.dispose();
        book.dispose();
        scroll.dispose();
        root.deleteSync(recursive: true);
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: SheetFrame(
              scroll: scroll,
              root: SearchPage(
                link: ReaderLink(
                  c: reader,
                  jump: (int _, {(int, int)? highlight}) {},
                  openAsk: ({String? prefill, String? quote}) {},
                ),
              ),
            ),
          ),
        ),
      );
      final Finder input = find.byKey(
        const ValueKey<String>('reader-search-input'),
      );
      await tester.tap(input);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'needle',
          selection: TextSelection.collapsed(offset: 6),
          composing: TextRange(start: 0, end: 6),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('找到 650 处'), findsNothing);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'needle',
          selection: TextSelection.collapsed(offset: 6),
        ),
      );
      await tester.pump(const Duration(milliseconds: 180));
      await tester.pumpAndSettle();
      expect(find.text('找到 650 处'), findsOneWidget);
      FocusManager.instance.primaryFocus?.unfocus();
      final Finder more = find.byKey(
        const ValueKey<String>('reader-search-more'),
      );
      for (int batch = 1; batch < 7; batch++) {
        await tester.scrollUntilVisible(
          more,
          500,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 150,
        );
        await tester.tap(more);
        await tester.pumpAndSettle();
      }
      expect(more, findsNothing);
      reader.page = PageData(
        chapter: 0,
        index: 0,
        frags: <Frag>[],
        start: 0,
        end: 7,
      );
      reader.touch();
      await tester.pump(const Duration(milliseconds: 180));
      await tester.pumpAndSettle();
      expect(find.text('找到 1 处'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'saved return anchor survives library reload and can be cleared',
    () async {
      final Directory root = Directory.systemTemp.createTempSync(
        'reading-return-',
      );
      final Library library = Library(root);
      library.saveProgress('book', 700, 800, 1000, returnTo: 42);
      final Library restored = Library(root);
      await restored.scan();
      expect(restored.progressOf('book')?.returnTo, 42);
      restored.saveProgress('book', 42, 100, 1000);
      final Library cleared = Library(root);
      await cleared.scan();
      expect(cleared.progressOf('book')?.returnTo, isNull);
      library.dispose();
      restored.dispose();
      cleared.dispose();
      root.deleteSync(recursive: true);
    },
  );
}
