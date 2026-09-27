import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/seen.dart';
import 'package:thusfar_app/reader/paginator.dart';
import 'package:thusfar_app/reader/reader_controller.dart';
import 'package:thusfar_app/sheets/common.dart';
import 'package:thusfar_app/sheets/manual_entity_editor.dart';
import 'package:thusfar_app/sheets/people_sheet.dart';
import 'package:thusfar_app/sheets/person_sheet.dart';
import 'package:thusfar_app/sheets/sheet_host.dart';
import 'package:thusfar_app/ui/theme.dart';
import 'package:thusfar_core/manual_entities.dart' as manual;
import 'package:thusfar_core/thusfar_core.dart' show ValueError;

void main() {
  late Directory root;
  late Directory directory;
  late Library library;
  late BookEntry entry;
  late Json source;
  BookData? opened;
  ReaderController? controller;
  ScrollController? scroll;
  const String text = 'Alice saw a fox. Bob follows.';

  setUp(() async {
    root = Directory.systemTemp.createTempSync('thusfar-manual-ui-');
    directory = Directory('${root.path}/books/fixture')
      ..createSync(recursive: true);
    source = <String, Object?>{
      'title': 'Fixture',
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
    writeJson(File('${directory.path}/book.json'), source);
    writeJson(File('${directory.path}/status.json'), <String, Object?>{
      'state': 'idle',
      'frontier': 0,
    });
    library = Library(root);
    await library.scan();
    entry = library.books.single;
    opened = null;
    controller = null;
    scroll = null;
    SeenStore.instance.attach(File('${root.path}/seen.json'));
  });
  tearDown(() {
    scroll?.dispose();
    controller?.dispose();
    opened?.notes.dispose();
    opened?.dispose();
    library.dispose();
    root.deleteSync(recursive: true);
  });

  Json payload({
    String id = 'manual01',
    String name = 'Alice',
    int? cutoff,
    String note = 'visible note',
    int revision = 0,
    String operation = 'operation01',
    bool deleted = false,
  }) => <String, Object?>{
    'id': id,
    'kind': 'person',
    'name': name,
    'note': note,
    'knowledge_cutoff': cutoff ?? text.length,
    'expected_revision': revision,
    'operation': operation,
    'deleted': deleted,
  };

  Json saved({bool history = false}) {
    final Json first = manual.manualApply(
      <Json>[],
      payload(cutoff: 16, note: 'early note'),
      source,
      <String, Object?>{'log': <Object?>[]},
      clock: () => 10,
    ).$2!;
    final Json item = history
        ? manual
              .manualApply(
                <Json>[first],
                payload(
                  revision: 1,
                  operation: 'operation02',
                  note: 'later private note',
                ),
                source,
                <String, Object?>{'log': <Object?>[]},
                clock: () => 20,
              )
              .$2!
        : first;
    writeJson(File('${directory.path}/manual-entities.json'), <Json>[item]);
    return item;
  }

  ReaderLink openData({int? cutoff}) {
    final BookData data = opened = BookData.open(entry);
    final ReaderController c = controller = ReaderController(
      library: library,
      book: data,
    );
    c.layout(
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
    c.page = PageData(
      chapter: 0,
      index: 0,
      frags: <Frag>[],
      start: 0,
      end: cutoff ?? text.length,
    );
    return ReaderLink(
      c: c,
      jump: (int _, {(int, int)? highlight}) {},
      openAsk: ({String? prefill, String? quote}) {},
    );
  }

  Future<void> show(WidgetTester tester, Widget page) async {
    await tester.binding.setSurfaceSize(const Size(430, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    scroll = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: SheetFrame(scroll: scroll!, root: page),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test(
    'existing personal records overlay a book without generated knowledge and honor historical cutoff',
    () {
      saved(history: true);
      openData();
      expect(opened!.hasKnowledge, isTrue);
      expect(opened!.world(15).people, isEmpty);
      expect(opened!.world(16).person('Umanual01')!.bio, 'early note');
      expect(
        opened!.world(text.length).person('Umanual01')!.bio,
        'later private note',
      );
      expect(opened!.mentions(0).single.id, 'Umanual01');
      expect(opened!.mentions(0).single.start, 0);
      expect(controller!.pagePeople(), <String>['Umanual01']);
      expect(File('${directory.path}/kg.json').existsSync(), isFalse);
    },
  );

  test(
    'save, edit and delete update reader caches while generated files remain unchanged',
    () {
      writeJson(File('${directory.path}/kg.json'), <String, Object?>{
        'log': <Json>[
          <String, Object?>{'t': 'person', 'id': 'p1', 'name': 'Bob', 'p': 16},
        ],
      });
      final String graphBefore = File(
        '${directory.path}/kg.json',
      ).readAsStringSync();
      openData();
      int updates = 0;
      controller!.addListener(() => updates++);
      opened!.saveManual(payload(cutoff: 16));
      expect(opened!.world(text.length).people.keys, <String>[
        'p1',
        'Umanual01',
      ]);
      expect(opened!.mentions(0), hasLength(1));
      opened!.saveManual(
        payload(revision: 1, operation: 'operation02', note: 'new note'),
      );
      expect(opened!.world(16).person('Umanual01')!.bio, 'visible note');
      expect(opened!.world(text.length).person('Umanual01')!.bio, 'new note');
      opened!.saveManual(
        payload(revision: 2, operation: 'operation03', deleted: true),
      );
      expect(opened!.world(text.length).people.keys, <String>['p1']);
      expect(opened!.mentions(0), isEmpty);
      expect(opened!.manualItems.single['deleted'], isTrue);
      expect(updates, 3);
      expect(File('${directory.path}/kg.json').readAsStringSync(), graphBefore);
    },
  );

  test(
    'external manual changes invalidate existing world and mention caches',
    () {
      openData();
      expect(opened!.world(text.length).people, isEmpty);
      expect(opened!.mentions(0), isEmpty);
      library.refreshStatus(entry);
      opened!.refreshKnowledge();
      saved();
      expect(library.refreshStatus(entry), isTrue);
      expect(opened!.refreshKnowledge(), isTrue);
      expect(opened!.world(text.length).person('Umanual01')!.bio, 'early note');
      expect(controller!.pagePeople(), <String>['Umanual01']);
      expect(opened!.mentions(0), hasLength(1));
    },
  );

  test(
    'corrupt personal data refuses a save and is never replaced with empty records',
    () {
      saved();
      openData();
      final File file = File('${directory.path}/manual-entities.json')
        ..writeAsStringSync('{broken');
      expect(
        () => opened!.saveManual(payload(id: 'manual02', name: 'fox')),
        throwsA(isA<ValueError>()),
      );
      expect(file.readAsStringSync(), '{broken');
      library.refreshStatus(entry);
      opened!.refreshKnowledge();
      expect(opened!.manualError, isNotNull);
      expect(opened!.world(text.length).person('Umanual01'), isNotNull);
    },
  );

  testWidgets(
    'the empty people page offers a local add workflow and shows the saved person',
    (WidgetTester tester) async {
      final ReaderLink link = openData();
      await show(tester, PeoplePage(link: link));
      await tester.tap(find.text('补充人物或概念'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('manual-name')),
        'Alice',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('manual-note')),
        'my own note',
      );
      await tester.tap(find.text('保存补充'));
      await tester.pumpAndSettle();
      expect(find.byType(PersonPage), findsOneWidget);
      expect(find.text('my own note'), findsOneWidget);
      expect(opened!.manualItems, hasLength(1));
      expect(controller!.pagePeople(), hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('unknown edit IDs cannot turn into accidental creation', (
    WidgetTester tester,
  ) async {
    final ReaderLink link = openData();
    await show(tester, ManualEntityEditor(link: link, id: 'missing01'));
    expect(find.text('这一页还看不到该条目，或它已被删除。'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('保存补充'), findsNothing);
    expect(
      File('${directory.path}/manual-entities.json').existsSync(),
      isFalse,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'editing later history is locked and never exposes the later note',
    (WidgetTester tester) async {
      saved(history: true);
      final ReaderLink link = openData(cutoff: 16);
      await show(tester, ManualEntityEditor(link: link, id: 'manual01'));
      final TextField note = tester.widget<TextField>(
        find.byKey(const ValueKey<String>('manual-note')),
      );
      expect(note.controller!.text, 'early note');
      expect(note.readOnly, isTrue);
      expect(find.textContaining('更后面的阅读位置'), findsOneWidget);
      expect(find.text('later private note'), findsNothing);
      controller!.page = PageData(
        chapter: 0,
        index: 0,
        frags: <Frag>[],
        start: 0,
        end: 8,
      );
      controller!.touch();
      await tester.pump();
      expect(find.byType(TextField), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'manual person editing and confirmed deletion immediately refresh the people page',
    (WidgetTester tester) async {
      saved();
      final ReaderLink link = openData();
      await show(tester, PersonPage(link: link, id: 'Umanual01'));
      await tester.tap(find.text('编辑或删除'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('manual-note')),
        'edited here',
      );
      await tester.tap(find.text('保存修改'));
      await tester.pumpAndSettle();
      expect(find.text('edited here'), findsOneWidget);
      await tester.tap(find.text('编辑或删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除这条补充'));
      await tester.pump();
      await tester.ensureVisible(find.text('确认删除'));
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();
      expect(opened!.manualItems.single['deleted'], isTrue);
      expect(opened!.world(text.length).people, isEmpty);
      expect(opened!.mentions(0), isEmpty);
      expect(find.byType(PeoplePage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
