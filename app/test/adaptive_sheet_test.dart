import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/prefs.dart';
import 'package:thusfar_app/reader/paginator.dart';
import 'package:thusfar_app/reader/reader_controller.dart';
import 'package:thusfar_app/sheets/common.dart';
import 'package:thusfar_app/sheets/search_sheet.dart';
import 'package:thusfar_app/sheets/sheet_host.dart';
import 'package:thusfar_app/sheets/typography_sheet.dart';
import 'package:thusfar_app/ui/theme.dart';

import 'support/viewport.dart';

class _ToolPage extends StatelessWidget {
  const _ToolPage({this.nested = false});
  final bool nested;

  @override
  Widget build(BuildContext context) => SheetPage(
    title: nested ? 'Detail' : 'Tools',
    slivers: <Widget>[
      SliverToBoxAdapter(
        child: Column(
          children: <Widget>[
            if (!nested)
              TextButton(
                onPressed: () => SheetScope.of(
                  context,
                ).state.push(const _ToolPage(nested: true)),
                child: const Text('More'),
              ),
            TextField(
              key: const ValueKey<String>('tool-input'),
              decoration: const InputDecoration(hintText: 'Type here'),
            ),
          ],
        ),
      ),
    ],
  );
}

void main() {
  test('secondary labels remain readable on every themed surface', () {
    for (final Tokens palette in <Tokens>[Tokens.light, Tokens.night]) {
      for (final Color background in <Color>[
        palette.paper,
        palette.sheet,
        palette.raised,
      ]) {
        final double foreground = palette.ink3.computeLuminance();
        final double surface = background.computeLuminance();
        final double contrast = foreground > surface
            ? (foreground + .05) / (surface + .05)
            : (surface + .05) / (foreground + .05);
        expect(contrast, greaterThanOrEqualTo(4.5));
      }
    }
  });

  Future<void> launch(
    WidgetTester tester,
    Widget page, {
    double textScale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => openSheet<void>(context, page),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'wide reader tools are bounded and nested back precedes closing',
    (WidgetTester tester) async {
      await setTestViewport(tester, const Size(1440, 900));
      addTearDown(() => setTestViewport(tester, null));
      await launch(tester, const _ToolPage());
      expect(find.byType(Dialog), findsOneWidget);
      expect(tester.getSize(find.byType(SheetFrame)).width, 600);
      expect(
        tester.getSize(find.byType(SheetFrame)).height,
        lessThanOrEqualTo(820),
      );
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      expect(find.text('Detail'), findsOneWidget);
      await tester.tap(find.byTooltip('返回上一层'));
      await tester.pumpAndSettle();
      expect(find.text('Tools'), findsOneWidget);
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Tools'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭阅读工具'));
      await tester.pumpAndSettle();
      expect(find.byType(SheetFrame), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow large text keeps the full knowledge boundary in the header',
    (WidgetTester tester) async {
      await setTestViewport(tester, const Size(320, 740));
      addTearDown(() => setTestViewport(tester, null));
      await launch(
        tester,
        const SheetPage(
          title: '问问这本书',
          tag: '只用前 123456 页回答',
          slivers: <Widget>[],
        ),
        textScale: 1.8,
      );
      expect(find.text('只用前 123456 页回答'), findsOneWidget);
      expect(
        tester.getRect(find.text('只用前 123456 页回答')).right,
        lessThanOrEqualTo(300),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭阅读工具'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('phone tools move above keyboard and consume its inset once', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    await setTestViewport(tester, const Size(390, 740));
    addTearDown(() async {
      tester.view.resetDevicePixelRatio();
      tester.view.resetViewInsets();
      await setTestViewport(tester, null);
    });
    await launch(tester, const _ToolPage());
    expect(find.byType(Dialog), findsNothing);
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    final Rect frame = tester.getRect(find.byType(SheetFrame));
    expect(frame.bottom, lessThanOrEqualTo(460));
    expect(frame.height, greaterThan(300));
    expect(
      MediaQuery.viewInsetsOf(tester.element(find.byType(SheetPage))).bottom,
      0,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('关闭阅读工具'));
    await tester.pumpAndSettle();
  });

  testWidgets('segmented controls support large text and keyboard navigation', (
    WidgetTester tester,
  ) async {
    await setTestViewport(tester, const Size(320, 440));
    addTearDown(() => setTestViewport(tester, null));
    int selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 440),
            textScaler: TextScaler.linear(1.8),
          ),
          child: Scaffold(
            body: StatefulBuilder(
              builder: (BuildContext context, StateSetter update) => Center(
                child: Segmented(
                  labels: const <String>['Already read', 'Whole book'],
                  index: selected,
                  onChanged: (int value) => update(() => selected = value),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final Finder first = find
        .ancestor(of: find.text('Already read'), matching: find.byType(InkWell))
        .first;
    expect(tester.getSize(first).height, greaterThanOrEqualTo(44));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(selected, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(selected, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search clear cancels pending work and keeps the read boundary', (
    WidgetTester tester,
  ) async {
    final Directory root = Directory.systemTemp.createTempSync(
      'adaptive-search-',
    );
    final Directory dir = Directory('${root.path}/books/fixture')
      ..createSync(recursive: true);
    const String text = 'Alice came. Bob follows later.';
    final Json meta = <String, Object?>{
      'title': 'Search fixture',
      'len': text.length,
      'lang': 'en',
      'notes': <String, Object?>{},
      'blocks': <Json>[
        <String, Object?>{'k': 'p', 't': text, 'o': 0},
      ],
      'chapters': <Json>[
        <String, Object?>{
          'title': 'One',
          'b0': 0,
          'b1': 1,
          'o0': 0,
          'o1': text.length,
          'kind': 'body',
        },
      ],
    };
    File('${dir.path}/book.json').writeAsStringSync(jsonEncode(meta));
    final Library library = Library(root);
    final BookData data = BookData.open(
      BookEntry(
        id: 'fixture',
        dir: dir,
        meta: meta,
        status: const ProcessStatus(<String, Object?>{}),
        added: 0,
      ),
    );
    final ReaderController reader = ReaderController(
      library: library,
      book: data,
    );
    reader.layout(
      Paginator(
        data,
        const PageSpec(
          width: 350,
          height: 500,
          fontSize: 16,
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
      end: 11,
    );
    final ReaderLink link = ReaderLink(
      c: reader,
      jump: (int _, {(int, int)? highlight}) {},
      openAsk: ({String? prefill, String? quote}) {},
    );
    addTearDown(() {
      reader.dispose();
      library.dispose();
      root.deleteSync(recursive: true);
    });
    await setTestViewport(tester, const Size(390, 740));
    addTearDown(() => setTestViewport(tester, null));
    await launch(tester, SearchPage(link: link));
    final Finder input = find.byKey(
      const ValueKey<String>('reader-search-input'),
    );
    await tester.enterText(input, 'Alice');
    await tester.pump();
    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
    expect(find.text('输入关键词搜索正文内容'), findsOneWidget);
    await tester.enterText(input, 'Bob');
    await tester.pump(const Duration(milliseconds: 180));
    await tester.pumpAndSettle();
    expect(find.text('读到这里的部分没有找到。要搜全书吗？'), findsOneWidget);
    await tester.tap(find.text('全书'));
    await tester.pump(const Duration(milliseconds: 180));
    await tester.pumpAndSettle();
    expect(find.text('会搜到还没读的内容'), findsOneWidget);
    expect(find.text('找到 1 处'), findsOneWidget);
    await tester.tap(input);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(SheetFrame), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'typography fits narrow large text and offers an explicit close',
    (WidgetTester tester) async {
      await setTestViewport(tester, const Size(320, 568));
      addTearDown(() => setTestViewport(tester, null));
      final Directory temp = Directory.systemTemp.createTempSync(
        'adaptive-type-',
      );
      final Prefs prefs = Prefs(File('${temp.path}/prefs.json'));
      addTearDown(() {
        prefs.dispose();
        temp.deleteSync(recursive: true);
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => openTypography(context, prefs),
                child: const Text('Typography'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Typography'));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byTooltip('左右边距增加')).height,
        greaterThanOrEqualTo(44),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭排版'));
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsNothing);
    },
  );
}
