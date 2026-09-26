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
  final List<AskCancellation?> tokens = <AskCancellation?>[];
  @override
  Future<Json> answer(
    Directory directory,
    String question,
    int pos, {
    AskEvent? onEvent,
    AskCancellation? cancellation,
  }) {
    requests.add((question, pos));
    tokens.add(cancellation);
    onEvent?.call('stage', <String, Object?>{'text': '检查有没有剧透'});
    final Completer<Json> reply = Completer<Json>();
    replies.add(reply);
    return reply.future;
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
            body: SheetFrame(
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
    'explicit submit captures prefix, disables repeats, stages, and jumps to citation',
    (WidgetTester tester) async {
      await open(tester);
      expect(service.requests, isEmpty);
      await send(tester, 'Who is Alice?');
      expect(service.requests, <(String, int)>[('Who is Alice?', 24)]);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey<String>('ask-send')))
            .onPressed,
        isNull,
      );
      expect(find.text('检查有没有剧透'), findsOneWidget);
      service.replies.single.complete(response(24));
      await tester.pumpAndSettle();
      expect(find.text('Alice came. [1]'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('ask-cite-1')));
      expect(jump, 0);
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
      await tester.tap(find.text('重试'));
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
      expect(service.requests.single.$1, contains('Alice came.'));
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
}
