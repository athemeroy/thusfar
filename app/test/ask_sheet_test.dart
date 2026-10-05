import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/reader/paginator.dart';
import 'package:thusfar_app/reader/reader_controller.dart';
import 'package:thusfar_app/sheets/ask_sheet.dart';
import 'package:thusfar_app/sheets/common.dart';
import 'package:thusfar_app/sheets/sheet_host.dart';
import 'package:thusfar_app/ui/theme.dart';
import 'package:thusfar_core/ask.dart';
import 'package:thusfar_core/llm.dart' as llm;

class PendingAsk extends AskService {
  final List<(String, int)> requests = <(String, int)>[];
  final List<Completer<Json>> replies = <Completer<Json>>[];
  final List<List<AskTurn>> contexts = <List<AskTurn>>[];
  final List<String?> selections = <String?>[];
  final List<AskCancellation?> tokens = <AskCancellation?>[];
  @override
  Future<Json> answer(
    Directory directory,
    String question,
    int pos, {
    AskEvent? onEvent,
    AskCancellation? cancellation,
    void Function()? onSettled,
    List<AskTurn> history = const <AskTurn>[],
    String? selectedText,
  }) {
    requests.add((question, pos));
    contexts.add(history);
    selections.add(selectedText);
    tokens.add(cancellation);
    onEvent?.call('stage', <String, Object?>{'text': '检查有没有剧透'});
    final Completer<Json> reply = Completer<Json>();
    replies.add(reply);
    return reply.future.whenComplete(() => onSettled?.call());
  }
}

Json response(int pos, {String text = 'Alice came. [1]'}) => <String, Object?>{
  'text': text,
  'position': pos,
  'guard': <String, Object?>{'verdict': 'ok', 'p': .95},
  'cites': <Json>[
    <String, Object?>{'n': 1, 'o': 0, 'text': 'Alice came.'},
  ],
};

void main() {
  late Directory root;
  late ReaderController controller;
  late ScrollController scroll;
  late PendingAsk service;
  late ReaderLink link;
  int? jump;

  setUp(() {
    root = Directory.systemTemp.createTempSync('thusfar-ask-ui-');
    final Directory dir = Directory('${root.path}/books/fixture')
      ..createSync(recursive: true);
    final Json book = <String, Object?>{
      'title': 'Fixture',
      'len': 100,
      'lang': 'en',
      'notes': <String, Object?>{},
      'blocks': <Json>[
        <String, Object?>{
          'k': 'p',
          't': 'Alice came. Bob sat down. Later chapters follow.',
          'o': 0,
        },
      ],
      'chapters': <Json>[
        <String, Object?>{
          'title': 'One',
          'b0': 0,
          'b1': 1,
          'o0': 0,
          'o1': 100,
          'kind': 'body',
        },
      ],
    };
    File('${dir.path}/book.json').writeAsStringSync(jsonEncode(book));
    final BookEntry entry = BookEntry(
      id: 'fixture',
      dir: dir,
      meta: book,
      status: const ProcessStatus(<String, Object?>{}),
      added: 0,
    );
    final BookData data = BookData.open(entry);
    controller = ReaderController(library: Library(root), book: data);
    controller.layout(
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
    controller.page = PageData(
      chapter: 0,
      index: 0,
      frags: <Frag>[],
      start: 0,
      end: 24,
    );
    scroll = ScrollController();
    service = PendingAsk();
    jump = null;
    link = ReaderLink(
      c: controller,
      jump: (int offset, {(int, int)? highlight}) {
        jump = offset;
      },
      openAsk: ({String? prefill, String? quote}) {},
    );
  });
  tearDown(() {
    scroll.dispose();
    controller.dispose();
    root.deleteSync(recursive: true);
  });

  Future<void> open(WidgetTester tester, {String? prefill, String? quote}) =>
      tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => MediaQuery.removeViewInsets(
                context: context,
                removeBottom: true,
                child: SheetFrame(
                  scroll: scroll,
                  root: AskPage(
                    link: link,
                    service: service,
                    prefill: prefill,
                    quote: quote,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(
      find.byKey(const ValueKey<String>('ask-input')),
      text,
    );
    // enterText schedules onChanged's rebuild; wait for the disabled button
    // to receive its enabled callback before tapping it.
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('ask-send')));
    await tester.pump();
  }

  testWidgets(
    'explicit submit captures prefix, offers stop, stages, and previews citation',
    (WidgetTester tester) async {
      await open(tester);
      expect(service.requests, isEmpty);
      await send(tester, 'Who is Alice?');
      expect(service.requests, <(String, int)>[('Who is Alice?', 24)]);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey<String>('ask-send')))
            .onPressed,
        isNotNull,
      );
      expect(find.text('检查有没有剧透'), findsOneWidget);
      service.replies.single.complete(response(24));
      await tester.pumpAndSettle();
      expect(find.text('Alice came. [1]'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('ask-cite-1')));
      await tester.pumpAndSettle();
      expect(jump, isNull);
      expect(find.text('返回这条回答'), findsOneWidget);
      await tester.tap(find.text('返回这条回答'));
      await tester.pumpAndSettle();
      expect(find.text('Alice came. [1]'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failure is visible and retry keeps the original question and cutoff',
    (WidgetTester tester) async {
      await open(tester);
      await send(tester, 'Who is Alice?');
      service.replies.single.completeError(const llm.LLMError('缺少模型访问密钥'));
      await tester.pumpAndSettle();
      expect(find.textContaining('还没有填写模型 API 密钥'), findsOneWidget);
      expect(find.text('模型设置'), findsOneWidget);
      await tester.tap(find.text('重试原题（可能再次收费）'));
      await tester.pump();
      expect(service.requests, <(String, int)>[
        ('Who is Alice?', 24),
        ('Who is Alice?', 24),
      ]);
      service.replies.last.complete(response(24));
      await tester.pumpAndSettle();
      expect(find.text('Alice came. [1]'), findsOneWidget);
    },
  );

  testWidgets('rewind clears old answers and cancels late publications', (
    WidgetTester tester,
  ) async {
    await open(tester, quote: 'Previously read quote');
    await send(tester, 'Who?');
    controller.page = PageData(
      chapter: 0,
      index: 0,
      frags: <Frag>[],
      start: 0,
      end: 10,
    );
    controller.touch();
    await tester.pump();
    expect(() => service.tokens.single!.check(), throwsA(isA<llm.LLMError>()));
    service.replies.single.complete(response(24, text: 'LATE PRIVATE ANSWER'));
    await tester.pumpAndSettle();
    expect(find.text('LATE PRIVATE ANSWER'), findsNothing);
    expect(find.text('Previously read quote'), findsNothing);
    await send(tester, 'Again?');
    expect(service.requests.last, ('Again?', 10));
    service.replies.last.complete(response(10));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'prefill and quoted text wait for an explicit submit; disposal cancels',
    (WidgetTester tester) async {
      await open(tester, prefill: '这是什么意思？', quote: 'Alice came.');
      expect(service.requests, isEmpty);
      await tester.tap(find.byKey(const ValueKey<String>('ask-send')));
      await tester.pump();
      expect(service.selections.single, 'Alice came.');
      expect(service.requests.single.$1, contains('这是什么意思？'));
      await tester.pumpWidget(const SizedBox());
      expect(
        () => service.tokens.single!.check(),
        throwsA(isA<llm.LLMError>()),
      );
      service.replies.single.complete(response(24));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'stop retains next draft and fences late answer until transport settles',
    (tester) async {
      await open(tester);
      await send(tester, 'First?');
      await tester.enterText(
        find.byKey(const ValueKey<String>('ask-input')),
        'My next draft',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('ask-send')));
      await tester.pump();
      expect(service.requests.length, 1);
      expect(
        () => service.tokens.single!.check(),
        throwsA(isA<llm.LLMError>()),
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey<String>('ask-send')))
            .onPressed,
        isNull,
      );
      service.replies.single.complete(response(24, text: 'STALE ANSWER'));
      await tester.pumpAndSettle();
      expect(find.text('STALE ANSWER'), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey<String>('ask-input')))
            .controller!
            .text,
        'My next draft',
      );
      await tester.tap(find.byKey(const ValueKey<String>('ask-send')));
      await tester.pump();
      expect(service.requests.last.$1, 'My next draft');
      service.replies.last.complete(response(24));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'question and selected text have independent Unicode limits and follow-ups',
    (tester) async {
      const String emoji = '👩‍👩‍👧‍👦';
      final String longQuestion =
          '${List<String>.filled(490, emoji).join()}只比较甲和乙';
      await open(tester, quote: List<String>.filled(180, '选').join());
      await send(tester, longQuestion);
      expect(service.requests.single.$1, longQuestion);
      expect(service.selections.single!.length, 180);
      service.replies.single.complete(response(24));
      await tester.pumpAndSettle();
      await send(tester, '那他呢？');
      expect(service.contexts.last.single.question, longQuestion);
      expect(service.contexts.last.single.cutoff, 24);
      service.replies.last.complete(response(24));
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'same-prefix reopen restores answer, draft and scroll without a request',
    (tester) async {
      await open(tester);
      await send(tester, 'Who is Alice?');
      service.replies.single.complete(response(24, text: 'Alice came. ' * 180));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('ask-input')),
        'Next draft',
      );
      await tester.pump();
      scroll.jumpTo(80);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await open(tester);
      await tester.pumpAndSettle();
      expect(service.requests.length, 1);
      expect(find.text('Alice came. ' * 180), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey<String>('ask-input')))
            .controller!
            .text,
        'Next draft',
      );
      expect(scroll.offset, closeTo(80, 1));
    },
  );

  testWidgets(
    'source navigation marks return intent; earlier cutoff cannot restore answer',
    (tester) async {
      await open(tester);
      await send(tester, 'Who?');
      service.replies.single.complete(response(24));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('ask-cite-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('定位原文（可返回回答）'));
      await tester.pumpAndSettle();
      expect(jump, 0);
      expect(controller.returnToAsk, isTrue);
      await tester.pumpWidget(const SizedBox());
      controller.page = PageData(
        chapter: 0,
        index: 0,
        frags: <Frag>[],
        start: 0,
        end: 10,
      );
      await open(tester);
      await tester.pumpAndSettle();
      expect(find.text('Alice came. [1]'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      controller.page = PageData(
        chapter: 0,
        index: 0,
        frags: <Frag>[],
        start: 0,
        end: 24,
      );
      await open(tester);
      await tester.pumpAndSettle();
      expect(find.text('Alice came. [1]'), findsOneWidget);
      expect(service.requests.length, 1);
    },
  );

  testWidgets(
    'reopening during cancellation keeps transport gate until settlement',
    (tester) async {
      await open(tester);
      await send(tester, 'First?');
      await tester.pumpWidget(const SizedBox());
      await open(tester);
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey<String>('ask-input')),
        'Second?',
      );
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey<String>('ask-send')))
            .onPressed,
        isNull,
      );
      expect(service.requests.length, 1);
      service.replies.single.complete(response(24, text: 'CANCELLED ANSWER'));
      await tester.pumpAndSettle();
      expect(find.text('CANCELLED ANSWER'), findsNothing);
      await tester.tap(find.byKey(const ValueKey<String>('ask-send')));
      await tester.pump();
      expect(service.requests.last.$1, 'Second?');
      service.replies.last.complete(response(24));
      await tester.pumpAndSettle();
    },
  );

  for (final Size viewport in <Size>[
    const Size(390, 844),
    const Size(360, 640),
  ]) {
    testWidgets(
      'new answer follows bottom or offers pinned shortcut at $viewport with keyboard',
      (tester) async {
        tester.view.physicalSize = viewport;
        tester.view.devicePixelRatio = 1;
        tester.view.viewInsets = const FakeViewPadding(bottom: 200);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        await open(tester);
        await send(tester, 'First?');
        service.replies.single.complete(
          response(24, text: 'Alice came. ' * 160),
        );
        await tester.pumpAndSettle();
        expect(scroll.position.extentAfter, lessThan(1));
        await send(tester, 'Second?');
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('检查有没有剧透').hitTestable(), findsOneWidget);
        service.replies.last.complete(response(24, text: 'Second answer. [1]'));
        await tester.pumpAndSettle();
        expect(scroll.position.extentAfter, lessThan(1));
        await send(tester, 'Third?');
        await tester.pump(const Duration(milliseconds: 300));
        scroll.jumpTo(0);
        await tester.pump();
        service.replies.last.complete(response(24, text: 'New answer. [1]'));
        await tester.pumpAndSettle();
        expect(scroll.offset, 0);
        expect(find.text('查看新回答').hitTestable(), findsOneWidget);
        await tester.tap(find.text('查看新回答'));
        await tester.pumpAndSettle();
        expect(scroll.position.extentAfter, lessThan(1));
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'new selected excerpt at the same cutoff overrides saved quote state and draft',
    (tester) async {
      await open(tester, quote: 'Alice came.');
      await send(tester, 'First?');
      service.replies.single.complete(response(24));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('ask-input')),
        'Old draft',
      );
      await tester.pumpWidget(const SizedBox());
      await open(tester, quote: 'Bob sat down.', prefill: 'Why did Bob sit?');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey<String>('ask-input')))
            .controller!
            .text,
        'Why did Bob sit?',
      );
      await tester.tap(find.byKey(const ValueKey<String>('ask-send')));
      await tester.pump();
      expect(service.requests.last.$1, 'Why did Bob sit?');
      expect(service.selections.last, 'Bob sat down.');
      expect(service.contexts.last.single.question, 'First?');
      service.replies.last.complete(response(24));
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'open citation preview hides its source immediately after rewind',
    (tester) async {
      await open(tester);
      await send(tester, 'Who?');
      service.replies.single.complete(response(24));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('ask-cite-1')));
      await tester.pumpAndSettle();
      expect(find.text(controller.book.textBetween(0, 24)), findsOneWidget);
      controller.page = PageData(
        chapter: 0,
        index: 0,
        frags: <Frag>[],
        start: 0,
        end: 10,
      );
      controller.touch();
      await tester.pump();
      expect(find.text(controller.book.textBetween(0, 24)), findsNothing);
      expect(find.text('已隐藏之前位置的原文和回答。'), findsOneWidget);
      expect(find.text('定位原文（可返回回答）'), findsNothing);
      await tester.tap(find.text('返回问书'));
      await tester.pumpAndSettle();
    },
  );
}
