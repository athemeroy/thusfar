import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/screens/notes_screen.dart';
import 'package:thusfar_app/sheets/note_editor.dart';
import 'package:thusfar_app/sheets/sheet_host.dart';
import 'package:thusfar_app/sheets/toc_sheet.dart';
import 'package:thusfar_app/ui/theme.dart';
import 'package:thusfar_core/thusfar_core.dart' show ValueError;

import 'support/graph_fixture.dart';

void main() {
  late GraphFixture fixture;
  late NoteStore notes;
  setUp(() {
    fixture = GraphFixture();
    notes = fixture.data.notes;
  });
  tearDown(() => fixture.dispose());

  Json add({
    int start = 0,
    int end = 5,
    int cutoff = 20,
    String text = '旧想法',
  }) => notes.save(
    kind: 'note',
    start: start,
    end: end,
    cutoff: cutoff,
    text: text,
  );

  test(
    'independent stores preserve unrelated writes and reject stale edits',
    () {
      final Json original = add();
      final NoteStore other = NoteStore(notes.file, fixture.data);
      addTearDown(other.dispose);
      final Json separate = other.save(
        kind: 'note',
        start: 10,
        end: 15,
        cutoff: 20,
        text: '独立笔记',
      );
      final Json edited = notes.save(
        id: original['id']! as String,
        kind: 'note',
        start: 0,
        end: 5,
        cutoff: 20,
        text: '新想法',
      );
      expect(edited['revision'], 2);
      expect(
        notes.items.map((Json item) => item['id']),
        contains(separate['id']),
      );
      final String before = notes.file.readAsStringSync();
      expect(
        () => other.save(
          id: original['id']! as String,
          kind: 'note',
          start: 0,
          end: 5,
          cutoff: 20,
          text: '过期修改',
        ),
        throwsA(isA<ValueError>()),
      );
      expect(notes.file.readAsStringSync(), before);
    },
  );

  test('editor expected revision survives a background refresh', () {
    final Json original = add();
    final NoteStore other = NoteStore(notes.file, fixture.data);
    addTearDown(other.dispose);
    other.save(
      id: original['id']! as String,
      kind: 'note',
      start: 0,
      end: 5,
      cutoff: 20,
      text: '另一处修改',
    );
    notes.refresh();
    expect(
      () => notes.save(
        id: original['id']! as String,
        expectedRevision: original['revision']! as int,
        kind: 'note',
        start: 0,
        end: 5,
        cutoff: 20,
        text: '旧编辑窗口',
      ),
      throwsA(isA<ValueError>()),
    );
    expect(notes.notes.single['text'], '另一处修改');
  });

  test(
    'delete and undo create revisions and stale undo cannot replace newer data',
    () {
      final Json original = add();
      final Json deleted = notes.delete(original);
      expect(deleted['revision'], 2);
      expect(notes.notes, isEmpty);
      final Json restored = notes.restore(deleted);
      expect(restored['revision'], 3);
      expect(restored['created'], original['created']);
      expect(restored['operation'], isNot(original['operation']));
      notes.save(
        id: original['id']! as String,
        kind: 'note',
        start: 0,
        end: 5,
        cutoff: 20,
        text: '撤销后的修改',
      );
      final String before = notes.file.readAsStringSync();
      expect(() => notes.restore(deleted), throwsA(isA<ValueError>()));
      expect(notes.file.readAsStringSync(), before);
    },
  );

  test('invalid source and unknown IDs do not create or rewrite a file', () {
    expect(
      () => notes.save(kind: 'note', start: 0, end: 1001, cutoff: 1001),
      throwsA(isA<ValueError>()),
    );
    expect(
      () => notes.save(
        id: 'unknown-note',
        kind: 'note',
        start: 0,
        end: 5,
        cutoff: 10,
      ),
      throwsA(isA<ValueError>()),
    );
    expect(notes.file.existsSync(), isFalse);
  });

  test(
    'malformed replacements retain loaded notes and refuse every mutation',
    () {
      final Json original = add();
      notes.file.writeAsStringSync('{broken');
      notes.refresh();
      expect(notes.error, contains('摘记文件损坏'));
      expect(notes.notes.single['id'], original['id']);
      expect(() => add(), throwsA(isA<ValueError>()));
      expect(() => notes.delete(original), throwsA(isA<ValueError>()));
      expect(notes.file.readAsStringSync(), '{broken');
      final NoteStore reopened = NoteStore(notes.file, fixture.data);
      expect(reopened.error, isNotNull);
      reopened.dispose();
    },
  );

  Future<void> openToc(WidgetTester tester) async {
    final ScrollController scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.binding.setSurfaceSize(const Size(430, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: SheetFrame(
            scroll: scroll,
            root: TocPage(link: fixture.link, tab: 2),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Toc hides crossing excerpts and later knowledge until explicitly enabled',
    (WidgetTester tester) async {
      add(end: 5, cutoff: 20, text: '可以看见');
      add(start: 25, end: 35, cutoff: 35, text: '跨过当前页');
      add(start: 10, end: 15, cutoff: 100, text: '后来写下的想法');
      fixture.setCutoff(30);
      await openToc(tester);
      expect(find.text('可以看见'), findsOneWidget);
      expect(find.text('跨过当前页'), findsNothing);
      expect(find.text('后来写下的想法'), findsNothing);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('跨过当前页'), findsOneWidget);
      expect(find.text('后来写下的想法'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      fixture.setCutoff(110);
      await tester.pumpAndSettle();
      expect(find.text('后来写下的想法'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Toc edits notes and deletion requires confirmation', (
    WidgetTester tester,
  ) async {
    final Json original = add();
    await openToc(tester);
    await tester.tap(find.byTooltip('编辑笔记'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '修改后的想法');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('修改后的想法'), findsOneWidget);
    expect(notes.notes.single['revision'], 2);
    expect(notes.notes.single['id'], original['id']);
    await tester.tap(find.byTooltip('编辑笔记'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除这条笔记？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(notes.notes, hasLength(1));
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '删除').last);
    await tester.pumpAndSettle();
    expect(notes.notes, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('editor reports stale-save conflict and retains typed text', (
    WidgetTester tester,
  ) async {
    final Json original = add();
    await openToc(tester);
    await tester.tap(find.byTooltip('编辑笔记'));
    await tester.pumpAndSettle();
    final NoteStore other = NoteStore(notes.file, fixture.data);
    other.save(
      id: original['id']! as String,
      kind: 'note',
      start: 0,
      end: 5,
      cutoff: 20,
      text: '外部修改',
    );
    other.dispose();
    await tester.enterText(find.byType(TextField), '我的未保存输入');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.byType(NoteEditor), findsOneWidget);
    expect(find.textContaining('摘记已在别处修改'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '我的未保存输入',
    );
    final List<Object?> disk =
        jsonDecode(notes.file.readAsStringSync()) as List<Object?>;
    expect((disk.single! as Json)['text'], '外部修改');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('global notes exposes edit and refreshes durable edited text', (
    WidgetTester tester,
  ) async {
    add();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: NotesScreen(
          library: fixture.library,
          onOpenAt: (BookEntry _, int _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('编辑笔记'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '全局编辑');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('全局编辑'), findsOneWidget);
    expect(find.text('旧想法'), findsNothing);
    notes.refresh();
    expect(notes.notes.single['text'], '全局编辑');
    expect(notes.notes.single['revision'], 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'global notes visibly reports corrupt notebook without overwriting it',
    (WidgetTester tester) async {
      final File file = notes.file..writeAsStringSync('{broken');
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: NotesScreen(
            library: fixture.library,
            onOpenAt: (BookEntry _, int _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('摘记读取失败'), findsOneWidget);
      expect(file.readAsStringSync(), '{broken');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
