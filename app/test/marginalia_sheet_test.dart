import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/reader/paginator.dart';
import 'package:thusfar_app/reader/reader_controller.dart';
import 'package:thusfar_app/sheets/common.dart';
import 'package:thusfar_app/sheets/marginalia_sheet.dart';
import 'package:thusfar_app/sheets/sheet_host.dart';
import 'package:thusfar_app/ui/theme.dart';
import 'package:thusfar_core/marginalia.dart';
import 'package:thusfar_core/thusfar_core.dart' show ValueError;

class PendingComments extends MarginaliaService {
  final List<Json> requests = [];
  final List<Completer<Json>> replies = [];
  final List<MarginaliaCancellation?> tokens = [];
  @override
  Future<Json> respond(
    Directory root,
    Object? data, {
    MarginaliaCancellation? cancellation,
    MarginaliaEvent? onEvent,
    void Function()? onSettled,
  }) {
    requests.add(data! as Json);
    tokens.add(cancellation);
    onEvent?.call('核对已读原文');
    final Completer<Json> reply = Completer<Json>();
    replies.add(reply);
    return reply.future.whenComplete(() => onSettled?.call());
  }
}

Json comment({String text = '这一声关门，比开口说话还让人在意。'}) => {
  'start': 0,
  'end': 24,
  'position': 48,
  'knowledge_cutoff': 24,
  'quote': '测试句子',
  'comment': text,
  'persona': 'empathy',
  'guard': {'verdict': 'ok', 'p': .9},
};
void main() {
  late Directory root;
  late ReaderController controller;
  late ScrollController scroll;
  late PendingComments service;
  late ReaderLink link;
  int? jump;
  setUp(() {
    root = Directory.systemTemp.createTempSync('thusfar-comment-ui-');
    final Directory dir = Directory('${root.path}/books/fixture')
      ..createSync(recursive: true);
    final Json book = {
      'title': 'Fixture',
      'len': 100,
      'lang': 'zh',
      'notes': <String, Object?>{},
      'blocks': [
        {'k': 'p', 't': '小林走进院子，轻轻地把门关上。他站在那里，一直没有说话。树影落在桌面上，他终于慢慢坐下。', 'o': 0},
      ],
      'chapters': [
        {'title': 'One', 'b0': 0, 'b1': 1, 'o0': 0, 'o1': 100, 'kind': 'body'},
      ],
    };
    File('${dir.path}/book.json').writeAsStringSync(jsonEncode(book));
    final BookEntry entry = BookEntry(
      id: 'fixture',
      dir: dir,
      meta: book,
      status: const ProcessStatus({}),
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
      frags: [],
      start: 0,
      end: 48,
    );
    scroll = ScrollController();
    service = PendingComments();
    jump = null;
    link = ReaderLink(
      c: controller,
      jump: (offset, {highlight}) {
        jump = offset;
      },
      openAsk: ({prefill, quote}) {},
    );
  });
  tearDown(() {
    scroll.dispose();
    controller.dispose();
    root.deleteSync(recursive: true);
  });
  Future<void> open(WidgetTester tester, {bool pageMode = false}) =>
      tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: SheetFrame(
              scroll: scroll,
              root: MarginaliaPage(
                link: link,
                start: 0,
                end: pageMode ? 48 : 24,
                pageMode: pageMode,
                service: service,
              ),
            ),
          ),
        ),
      );
  Future<void> generate(WidgetTester tester) async {
    final Finder button = find.byKey(
      const ValueKey<String>('marginalia-generate'),
    );
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
  }

  testWidgets(
    'selection, persona and cutoff are captured; only verified result appears',
    (tester) async {
      await open(tester);
      expect(service.requests, isEmpty);
      await tester.tap(find.text('冷眼'));
      await tester.pump();
      await generate(tester);
      expect(service.requests.single, {
        'mode': 'manual',
        'pos': 48,
        'persona': 'cold',
        'start': 0,
        'end': 24,
      });
      expect(find.text('核对已读原文'), findsOneWidget);
      expect(find.text('这一声关门，比开口说话还让人在意。'), findsNothing);
      service.replies.single.complete(comment());
      await tester.pumpAndSettle();
      expect(find.text('这一声关门，比开口说话还让人在意。'), findsOneWidget);
      await tester.ensureVisible(find.text('回到原句'));
      await tester.tap(find.text('回到原句'));
      expect(jump, 0);
    },
  );
  testWidgets('failed verification exposes error with retry, never a draft', (
    tester,
  ) async {
    await open(tester);
    await generate(tester);
    service.replies.single.completeError(
      const ValueError('这条批注没有通过已读内容核对，已替你隐藏'),
    );
    await tester.pumpAndSettle();
    expect(find.text('这条批注没有通过已读内容核对，已替你隐藏'), findsOneWidget);
    await tester.ensureVisible(find.text('重试'));
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(service.requests.length, 2);
    service.replies.last.complete(comment());
    await tester.pumpAndSettle();
    expect(find.text('这一声关门，比开口说话还让人在意。'), findsOneWidget);
  });
  testWidgets('rewind cancels pending request and late result stays hidden', (
    tester,
  ) async {
    await open(tester);
    await generate(tester);
    controller.page = PageData(
      chapter: 0,
      index: 0,
      frags: [],
      start: 0,
      end: 12,
    );
    controller.notifyListeners();
    await tester.pump();
    expect(service.tokens.single!.isCancelled, true);
    service.replies.single.complete(comment(text: '后来的结局必须隐藏'));
    await tester.pumpAndSettle();
    expect(find.text('后来的结局必须隐藏'), findsNothing);
    expect(find.text('阅读位置已改变，请回到原文重新选择。'), findsOneWidget);
  });
  testWidgets(
    'page cue selects exact source for multi-angle generation and restores full page cue range',
    (tester) async {
      await open(tester, pageMode: true);
      await generate(tester);
      expect(service.requests.single['mode'], 'cues');
      service.replies.single.complete({
        'reason': 'cues',
        'items': [
          {
            'start': 0,
            'end': 24,
            'quote': '小林走进院子，轻轻地把门关上。',
            'persona': 'detective',
          },
        ],
      });
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('侦探视角'));
      await tester.tap(find.text('侦探视角'));
      await tester.pump();
      expect(service.requests.last, {
        'mode': 'auto',
        'pos': 48,
        'persona': 'detective',
        'page_start': 0,
        'page_end': 24,
      });
      service.replies.last.complete({
        ...comment(),
        'items': [comment()],
      });
      await tester.pumpAndSettle();
      await generate(tester);
      expect(service.requests.last['page_end'], 48);
      service.replies.last.complete({'reason': 'cues', 'items': []});
      await tester.pumpAndSettle();
      expect(find.text('这一页暂时没有特别适合评论的句子，继续读也很好。'), findsOneWidget);
    },
  );
  testWidgets('closing sheet cancels request and ignores late failure', (
    tester,
  ) async {
    await open(tester);
    await generate(tester);
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    expect(service.tokens.single!.isCancelled, true);
    service.replies.single.completeError(StateError('late failure'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
