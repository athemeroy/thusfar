import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/model_settings.dart';
import 'package:thusfar_app/data/processing.dart';
import 'package:thusfar_app/main.dart';
import 'package:thusfar_app/sheets/book_sheet.dart';
import 'package:thusfar_app/ui/theme.dart';
import 'package:thusfar_core/jobs.dart' show AlreadyRunning, RunLease;

class FixtureProcessing extends BookProcessing {
  FixtureProcessing(this.library);

  final Library library;
  int initializations = 0;
  int starts = 0;
  int pauses = 0;
  int removals = 0;
  Completer<void>? pauseGate;
  Completer<void>? removalGate;
  Object? startError;

  void status(BookEntry book, Json state) {
    writeJson(File('${book.dir.path}/status.json'), state);
    library.refreshStatus(book);
    notifyListeners();
  }

  @override
  Future<void> initialize() async => initializations++;

  @override
  Future<void> startBook(BookEntry book) async {
    starts++;
    if (startError != null) throw startError!;
    status(book, <String, Object?>{'state': 'running', 'done': 0, 'total': 2});
  }

  @override
  Future<void> pauseBook(BookEntry book) async {
    pauses++;
    status(book, <String, Object?>{
      'state': 'cancelling',
      'done': 1,
      'total': 2,
    });
    await pauseGate?.future;
    status(book, <String, Object?>{'state': 'paused', 'done': 1, 'total': 2});
  }

  @override
  Future<void> prepareRemoval(BookEntry book) async {
    removals++;
    status(book, <String, Object?>{'state': 'cancelling'});
    await removalGate?.future;
    status(book, <String, Object?>{'state': 'paused'});
  }

  @override
  Future<void> close() async {}
}

Json fixtureBook() => <String, Object?>{
  'title': 'Fixture',
  'author': 'Writer',
  'len': 40,
  'lang': 'en',
  'notes': <String, Object?>{},
  'blocks': <Json>[
    <String, Object?>{
      'k': 'p',
      't': 'Alice came. Bob came. End of the chapter.',
      'o': 0,
    },
  ],
  'chapters': <Json>[
    <String, Object?>{
      'title': 'One',
      'b0': 0,
      'b1': 1,
      'o0': 0,
      'o1': 40,
      'kind': 'body',
    },
  ],
};

Json person(String id, String name, int position) => <String, Object?>{
  't': 'person',
  'id': id,
  'name': name,
  'p': position,
};

void main() {
  late Directory root;
  late Directory bookRoot;
  late Library library;
  late BookEntry entry;
  late FixtureProcessing processing;
  late ModelSettings settings;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('thusfar-processing-ui-');
    bookRoot = Directory('${root.path}/books/fixture')
      ..createSync(recursive: true);
    writeJson(File('${bookRoot.path}/book.json'), fixtureBook());
    writeJson(File('${bookRoot.path}/meta.json'), <String, Object?>{
      'auto': false,
    });
    writeJson(File('${bookRoot.path}/status.json'), <String, Object?>{
      'state': 'idle',
    });
    library = Library(root);
    await library.scan();
    entry = library.books.single;
    processing = FixtureProcessing(library);
    settings = ModelSettings(File('${root.path}/.model.env'));
  });

  tearDown(() {
    processing.dispose();
    library.dispose();
    root.deleteSync(recursive: true);
  });

  void configure() {
    expect(
      settings.save(
        url: 'https://example.invalid/v1',
        model: 'fixture',
        key: 'test-only-placeholder',
      ),
      isNull,
    );
  }

  Future<void> open(WidgetTester tester, {VoidCallback? onRemoved}) async {
    await tester.binding.setSurfaceSize(const Size(430, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => BookSheet.open(
                context,
                BookSheet(
                  library: library,
                  entry: entry,
                  settings: settings,
                  processing: processing,
                  onRead: () {},
                  onNotes: () {},
                  onModelSettings: () async {},
                  onExport: () async {},
                  onRemoved: onRemoved,
                  focusProcessing: true,
                ),
              ),
              child: const Text('Open fixture'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open fixture'));
    await tester.pumpAndSettle();
  }

  test('AppModel defers worker startup until explicit initialize', () async {
    late FixtureProcessing fake;
    final AppModel model = AppModel(
      root,
      createProcessing: (Library value) => fake = FixtureProcessing(value),
    );
    expect(fake.initializations, 0);
    expect(fake.starts, 0);
    await model.initialize();
    expect(fake.initializations, 1);
    expect(fake.starts, 0);
    expect(model.library.books, hasLength(1));
    model.dispose();
  });

  test(
    'real worker isolate reconciles interrupted work without starting models',
    () async {
      writeJson(File('${bookRoot.path}/meta.json'), <String, Object?>{
        'auto': true,
      });
      writeJson(File('${bookRoot.path}/status.json'), <String, Object?>{
        'state': 'running',
        'done': 1,
        'total': 2,
      });
      final ProcessingController actual = ProcessingController(library);
      try {
        await actual.initialize().timeout(const Duration(seconds: 10));
        expect(entry.status.state, 'paused');
        await expectLater(actual.startBook(entry), throwsA(isA<Exception>()));
        expect(entry.status.state, 'paused');
        expect(
          File('${bookRoot.path}/work/worker-receipt.json').existsSync(),
          isTrue,
        );
      } finally {
        await actual.close().timeout(const Duration(seconds: 10));
        actual.dispose();
      }
    },
  );

  testWidgets(
    'start is explicit, progress updates, pause settles, and resume works',
    (WidgetTester tester) async {
      configure();
      await open(tester);
      expect(processing.starts, 0);
      await tester.tap(find.text('开始整理'));
      await tester.pump();
      expect(processing.starts, 0);
      expect(find.textContaining('会调用你的模型接口'), findsOneWidget);
      await tester.tap(find.text('开始'));
      await tester.pump();
      expect(processing.starts, 1);
      expect(find.text('已整理 0 / 2 段'), findsOneWidget);
      processing.status(entry, <String, Object?>{
        'state': 'running',
        'done': 1,
        'total': 2,
      });
      await tester.pump();
      expect(find.text('已整理 1 / 2 段'), findsOneWidget);
      processing.pauseGate = Completer<void>();
      await tester.tap(find.text('暂停整理'));
      await tester.pump();
      expect(processing.pauses, 1);
      expect(find.textContaining('已经整理好的内容会保留'), findsOneWidget);
      expect(find.text('继续整理'), findsNothing);
      processing.pauseGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('继续整理'), findsOneWidget);
      await tester.tap(find.text('继续整理'));
      await tester.pump();
      expect(processing.starts, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('missing key and start failures remain visible and retryable', (
    WidgetTester tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('开始整理'));
    await tester.pump();
    expect(find.text('还没有填写模型 API 密钥'), findsOneWidget);
    expect(processing.starts, 0);
    configure();
    await tester.tap(find.text('去填写'));
    await tester.pump();
    processing.startError = StateError('正在暂停，请稍后继续');
    await tester.tap(find.text('开始整理'));
    await tester.pump();
    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();
    expect(find.text('正在暂停，请稍后继续'), findsOneWidget);
    expect(find.text('开始整理'), findsOneWidget);
  });

  testWidgets('quality retry is exposed only when requested by durable state', (
    WidgetTester tester,
  ) async {
    configure();
    processing.status(entry, <String, Object?>{
      'state': 'done',
      'people': 2,
      'quality': <String, Object?>{'pending': true},
    });
    await open(tester);
    expect(processing.starts, 0);
    await tester.tap(find.text('重试待核对部分'));
    await tester.pump();
    expect(processing.starts, 1);
    expect(find.text('已整理 0 / 2 段'), findsOneWidget);
  });

  testWidgets('removal waits for actual settlement even if the drawer closes', (
    WidgetTester tester,
  ) async {
    int removed = 0;
    processing.removalGate = Completer<void>();
    await open(tester, onRemoved: () => removed++);
    await tester.ensureVisible(find.text('从这台手机移除'));
    await tester.tap(find.text('从这台手机移除'));
    await tester.pump();
    await tester.ensureVisible(find.text('移除'));
    await tester.tap(find.text('移除'));
    await tester.pump();
    expect(processing.removals, 1);
    expect(bookRoot.existsSync(), isTrue);
    expect(removed, 0);
    Navigator.of(tester.element(find.text('Fixture').last)).pop();
    await tester.pumpAndSettle();
    processing.removalGate!.complete();
    await tester.pumpAndSettle();
    expect(removed, 1);
    expect(bookRoot.existsSync(), isFalse);
    expect(Directory('${root.path}/trash').listSync(), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  test(
    'remove refuses an active lease or cancelling status and retains the book',
    () async {
      final RunLease lease = await RunLease.acquire(bookRoot);
      try {
        await expectLater(
          library.remove(entry),
          throwsA(isA<AlreadyRunning>()),
        );
        expect(bookRoot.existsSync(), isTrue);
      } finally {
        lease.release();
      }
      writeJson(File('${bookRoot.path}/status.json'), <String, Object?>{
        'state': 'cancelling',
      });
      await expectLater(library.remove(entry), throwsStateError);
      expect(bookRoot.existsSync(), isTrue);
      expect(library.books, hasLength(1));
    },
  );

  test(
    'processing refresh invalidates worlds and mentions while keeping text and notes',
    () {
      writeJson(File('${bookRoot.path}/kg.json'), <String, Object?>{
        'log': <Json>[person('p1', 'Alice', 0)],
      });
      Directory('${bookRoot.path}/mentions').createSync();
      writeJson(File('${bookRoot.path}/mentions/0000.json'), <Object?>[
        <Object?>[0, 5, 'p1', 0],
      ]);
      processing.status(entry, <String, Object?>{
        'state': 'running',
        'frontier': 12,
      });
      final BookData data = BookData.open(entry);
      final Object text = data.blocks;
      final Object notes = data.notes;
      expect(data.world(40).people.keys, <String>['p1']);
      expect(data.mentions(0), hasLength(1));
      writeJson(File('${bookRoot.path}/kg.json'), <String, Object?>{
        'log': <Json>[person('p1', 'Alice', 0), person('p2', 'Bob', 12)],
      });
      writeJson(File('${bookRoot.path}/mentions/0000.json'), <Object?>[
        <Object?>[0, 5, 'p1', 0],
        <Object?>[12, 15, 'p2', 0],
      ]);
      processing.status(entry, <String, Object?>{
        'state': 'running',
        'frontier': 20,
      });
      expect(data.refreshKnowledge(), isTrue);
      expect(data.world(40).people.keys, <String>['p1', 'p2']);
      expect(data.mentions(0), hasLength(2));
      expect(identical(data.blocks, text), isTrue);
      expect(identical(data.notes, notes), isTrue);
      expect(data.refreshKnowledge(), isFalse);
      // A replacement with unchanged frontier must still invalidate the world.
      writeJson(File('${bookRoot.path}/kg.json'), <String, Object?>{
        'log': <Json>[person('p1', 'Alice Smith', 0)],
      });
      expect(library.refreshStatus(entry), isTrue);
      data.refreshKnowledge();
      expect(data.world(40).person('p1')!.name, 'Alice Smith');
      File('${bookRoot.path}/kg.json').writeAsStringSync('{invalid');
      library.refreshStatus(entry);
      data.refreshKnowledge();
      expect(data.knowledgeError, isNotNull);
      expect(data.world(40).person('p1')!.name, 'Alice Smith');
      data.notes.dispose();
      data.dispose();
    },
  );
}
