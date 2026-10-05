@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/ui/theme.dart';
import 'package:thusfar_app/web/web_ai_engine.dart';
import 'package:thusfar_app/web/web_ask_panel.dart';
import 'package:thusfar_app/web/web_model_provider.dart';
import 'package:thusfar_app/web/web_model_session.dart';
import 'package:thusfar_app/web/web_storage.dart';

const String first = 'Alice came home.';
const String selected = 'Bob sat down.';
const String second = '${selected}UNREAD_SECRET';

WebBook fixture() => WebBook(
  meta: const WebBookMeta(
    id: 'ask-fixture',
    title: 'Ask fixture',
    author: '',
    length: 100,
    chapters: 2,
    added: 0,
  ),
  data: <String, Object?>{
    'blocks': <Json>[
      <String, Object?>{'k': 'p', 'o': 0, 't': first},
      <String, Object?>{'k': 'p', 'o': first.length, 't': second},
      <String, Object?>{'k': 'p', 'o': 80, 't': 'LATER_CHAPTER_SECRET'},
    ],
    'chapters': <Json>[
      <String, Object?>{
        'title': 'One',
        'kind': 'body',
        'b0': 0,
        'b1': 2,
        'o0': 0,
        'o1': 80,
      },
      <String, Object?>{
        'title': 'Two',
        'kind': 'body',
        'b0': 2,
        'b1': 3,
        'o0': 80,
        'o1': 100,
      },
    ],
  },
  images: <String, String>{},
);

String reply({String answer = 'Bob sat down. [2]'}) =>
    jsonEncode(<String, Object?>{
      'choices': <Json>[
        <String, Object?>{
          'finish_reason': 'stop',
          'message': <String, Object?>{
            'content': jsonEncode(<String, Object?>{
              'answer': answer,
              'citations': <Json>[
                <String, Object?>{'id': 2, 'quote': selected},
              ],
            }),
          },
        },
      ],
    });

void main() {
  late WebBook book;
  late List<WebModelRequest> requests;
  late List<Completer<String>> pending;
  int? citation;
  setUp(() {
    book = fixture();
    requests = <WebModelRequest>[];
    pending = <Completer<String>>[];
    citation = null;
    WebModelSession.current.set(
      const WebAiConfig(
        endpoint: 'http://localhost:11434/v1',
        model: 'fixture',
        apiKey: '',
      ),
    );
  });
  tearDown(() {
    WebModelSession.current.clear();
    html.window.localStorage.remove('thusfar-web-model-profile-v1');
  });

  Future<void> open(
    WidgetTester tester, {
    int cutoff = 1,
    bool selection = true,
    bool restoreDraft = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: WebAskPanel(
          book: book,
          chapterIndex: 0,
          cutoffBlockExclusive: cutoff,
          restoreDraft: restoreDraft,
          selectedText: selection ? selected : null,
          selectedStart: selection ? first.length : null,
          selectedEnd: selection ? first.length + selected.length : null,
          request: (WebModelRequest request) {
            requests.add(request);
            final Completer<String> result = Completer<String>();
            pending.add(result);
            return result.future;
          },
          onCitationTap: (int block) => citation = block,
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> send(WidgetTester tester, String question) async {
    await tester.enterText(
      find.byKey(const ValueKey<String>('web-ask-input')),
      question,
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('web-ask-send')));
    await tester.pump();
  }

  testWidgets(
    'verified selected evidence excludes same-block suffix and later chapter; full question survives',
    (tester) async {
      await open(tester);
      expect(requests, isEmpty);
      final String question = '${'问' * 490}最后只比较甲和乙。';
      await send(tester, question);
      final String body = jsonEncode(requests.single.body);
      expect(body, contains(question));
      expect(body, contains(selected));
      expect(body, isNot(contains('UNREAD_SECRET')));
      expect(body, isNot(contains('LATER_CHAPTER_SECRET')));
      pending.single.complete(reply());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('web-ask-cite-2')));
      await tester.pumpAndSettle();
      expect(citation, isNull);
      expect(find.text(selected), findsOneWidget);
      await tester.tap(find.text('返回这条回答'));
      await tester.pumpAndSettle();
      expect(find.text('Bob sat down. [2]'), findsOneWidget);
      expect(requests.length, 1);
    },
  );

  testWidgets(
    'retry preserves original question selection and context without duplicate clicks',
    (tester) async {
      await open(tester);
      await send(tester, 'What happened?');
      pending.single.completeError(StateError('offline failure'));
      await tester.pumpAndSettle();
      final Finder retry = find.text('重试原题（可能再次收费）');
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.tap(retry);
      await tester.pump();
      expect(requests.last.body, requests.first.body);
      expect(requests.length, 2);
      pending.last.complete(reply());
      await tester.pumpAndSettle();
      await send(tester, 'And he?');
      expect(jsonEncode(requests.last.body), contains('What happened?'));
      expect(jsonEncode(requests.last.body), contains('Bob sat down. [2]'));
      pending.last.complete(reply());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'stop and reopen fence late response and keep next draft until connection settles',
    (tester) async {
      await open(tester);
      await send(tester, 'First?');
      await tester.enterText(
        find.byKey(const ValueKey<String>('web-ask-input')),
        'Next draft',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('web-ask-send')));
      await tester.pump();
      expect(requests.length, 1);
      await tester.pumpWidget(const SizedBox());
      await open(tester, restoreDraft: true);
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey<String>('web-ask-send')),
            )
            .onPressed,
        isNull,
      );
      pending.single.complete(reply(answer: 'STALE ANSWER [2]'));
      await tester.pumpAndSettle();
      expect(find.text('STALE ANSWER [2]'), findsNothing);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey<String>('web-ask-input')),
            )
            .controller!
            .text,
        'Next draft',
      );
      await tester.tap(find.byKey(const ValueKey<String>('web-ask-send')));
      await tester.pump();
      expect(requests.length, 2);
      pending.last.complete(reply());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'source navigation snapshot restores only exact original evidence scope',
    (tester) async {
      await open(tester);
      await send(tester, 'Who?');
      pending.single.complete(reply());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('web-ask-cite-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('定位原文（可返回回答）'));
      await tester.pumpAndSettle();
      expect(citation, 1);
      await tester.pumpWidget(const SizedBox());
      await open(tester, cutoff: 0, selection: false);
      expect(find.text('Bob sat down. [2]'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await open(tester);
      await tester.pumpAndSettle();
      expect(find.text('Bob sat down. [2]'), findsOneWidget);
      expect(requests.length, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'narrow keyboard viewport follows new question and keeps old-answer reading position',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 200);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await open(tester);
      await send(tester, 'First?');
      pending.single.complete(reply(answer: '${'Bob sat down. ' * 60}[2]'));
      await tester.pumpAndSettle();
      final ScrollController scroll = tester
          .widget<ListView>(find.byType(ListView))
          .controller!;
      expect(scroll.position.extentAfter, lessThan(1));
      await send(tester, 'Second?');
      await tester.pump(const Duration(milliseconds: 300));
      // Lazy slivers reveal the new row during the first 220 ms scroll, then
      // _showLatest corrects to the measured bottom with a second animation.
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byType(LinearProgressIndicator).hitTestable(),
        findsOneWidget,
      );
      scroll.jumpTo(0);
      await tester.pump();
      pending.last.complete(reply());
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
