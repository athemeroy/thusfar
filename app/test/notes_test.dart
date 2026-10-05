import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/note_drafts.dart';
import 'package:thusfar_app/screens/notes_screen.dart';
import 'package:thusfar_app/sheets/note_editor.dart';
import 'package:thusfar_app/sheets/sheet_host.dart';
import 'package:thusfar_app/sheets/toc_sheet.dart';
import 'package:thusfar_app/ui/theme.dart';
import 'package:thusfar_core/thusfar_core.dart' show ValueError;

import 'support/graph_fixture.dart';

import 'support/viewport.dart';

void main() {
  late GraphFixture fixture;
  late NoteStore notes;
  setUp(() {
    fixture = GraphFixture();
    notes = fixture.data.notes;
  });
  tearDown(() => fixture.dispose());

  Future<void> settleNotes(WidgetTester tester, {Finder? until}) async {
    for (int i = 0; i < 200; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      if (find
              .byKey(const ValueKey<String>('notes-loading'))
              .evaluate()
              .isEmpty &&
          (until == null || until.evaluate().isNotEmpty)) {
        return;
      }
    }
    fail('Notebook projection did not finish loading');
  }

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
    await setTestViewport(tester, const Size(430, 1000));
    addTearDown(() => setTestViewport(tester, null));
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
    await settleNotes(tester);
    await tester.tap(find.byTooltip('编辑笔记'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '全局编辑');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await settleNotes(tester, until: find.text('全局编辑'));
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
      await settleNotes(tester);
      expect(find.textContaining('摘记读取失败'), findsOneWidget);
      expect(file.readAsStringSync(), '{broken');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'notes search clears its field and cached records refresh on library change',
    (WidgetTester tester) async {
      add(text: 'Find MY Thought');
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: NotesScreen(library: fixture.library, onOpenAt: (_, _) {}),
        ),
      );
      await settleNotes(tester);
      await tester.tap(find.byTooltip('搜索摘记'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'my thought');
      await tester.pumpAndSettle();
      expect(find.text('Find MY Thought'), findsOneWidget);
      await tester.tap(find.byTooltip('清空搜索'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );

      // Searching must use the loaded projection rather than reread large files
      // on the UI thread. A library refresh then checks the changed file stamp.
      notes.file.writeAsStringSync('{broken');
      await tester.enterText(find.byType(TextField), 'thought');
      await tester.pumpAndSettle();
      expect(find.text('Find MY Thought'), findsOneWidget);
      expect(find.textContaining('摘记读取失败'), findsNothing);
      await tester.runAsync(fixture.library.scan);
      await settleNotes(tester, until: find.textContaining('摘记读取失败'));
      expect(notes.file.readAsStringSync(), '{broken');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.byTooltip('搜索摘记'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  Future<void> openEditor(
    WidgetTester tester, {
    Json? existing,
    int cutoff = 30,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: NoteEditor(
            book: fixture.data,
            start: 0,
            end: 5,
            cutoff: cutoff,
            draftDir: fixture.directory,
            existing: existing,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'direct draft reopening after rewind hides later knowledge and preserves bytes',
    (tester) async {
      final NoteDraft draft = NoteDraft(
        start: 0,
        end: 5,
        cutoff: 100,
        text: 'LATER DRAFT SPOILER',
        source: NoteDraft.sourceFor(fixture.data, 0, 5),
      );
      draft.write(fixture.directory);
      final File file = NoteDraft.fileFor(fixture.directory, 0, 5, null);
      final String before = file.readAsStringSync();
      await openEditor(tester);
      expect(find.text('LATER DRAFT SPOILER'), findsNothing);
      expect(find.textContaining('较后的阅读位置'), findsOneWidget);
      final TextField field = tester.widget(find.byType(TextField));
      expect(field.enabled, isFalse);
      field.controller!.text = 'Must not overwrite';
      await tester.pump();
      expect(file.readAsStringSync(), before);
      expect(find.text('保存'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await openEditor(tester, cutoff: 100);
      expect(find.text('LATER DRAFT SPOILER'), findsOneWidget);
      expect(file.readAsStringSync(), before);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final bool malformed in [false, true]) {
    testWidgets(
      'unavailable ${malformed ? 'unreadable' : 'source-mismatched'} draft is never overwritten or deleted',
      (tester) async {
        final Json original = add();
        final File file = NoteDraft.fileFor(
          fixture.directory,
          0,
          5,
          original['id'] as String,
        );
        file.writeAsStringSync(
          malformed
              ? '{original broken bytes'
              : jsonEncode(
                  NoteDraft(
                    start: 0,
                    end: 5,
                    cutoff: 20,
                    text: 'DO NOT EXPOSE',
                    source: 'changed source',
                    noteId: original['id'] as String,
                    revision: original['revision'] as int,
                  ).toJson(),
                ),
        );
        final String before = file.readAsStringSync();
        await openEditor(tester, existing: original);
        expect(find.text('DO NOT EXPOSE'), findsNothing);
        final TextField field = tester.widget(find.byType(TextField));
        expect(field.enabled, isFalse);
        field.controller!.text = 'replacement';
        await tester.pump();
        field.controller!.text = original['text'] as String;
        await tester.pump();
        expect(file.readAsStringSync(), before);
        expect(find.text('保存'), findsNothing);
        expect(find.text('删除'), findsNothing);
        expect(find.text('放弃草稿'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(file.readAsStringSync(), before);
      },
    );
  }

  testWidgets('editing an existing note keeps its draft across dismissal', (
    tester,
  ) async {
    final Json original = add();
    await openEditor(tester, existing: original);
    await tester.enterText(find.byType(TextField), 'saved only as draft');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(notes.notes.single['text'], '旧想法');
    final List<NoteDraft> drafts = NoteDraft.list(fixture.directory);
    expect(drafts.single.noteId, original['id']);
    expect(drafts.single.cutoff, 30);
    await openEditor(tester, existing: original);
    expect(find.text('saved only as draft'), findsOneWidget);
    expect(find.text('已恢复未保存的草稿'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'legacy draft with unknown reading boundary remains hidden and intact',
    (tester) async {
      final File legacy = File('${fixture.directory.path}/.note-draft-0-5.txt')
        ..writeAsStringSync('UNKNOWN SPOILER');
      await openEditor(tester);
      expect(find.text('UNKNOWN SPOILER'), findsNothing);
      expect(find.textContaining('旧版草稿缺少原文'), findsOneWidget);
      final TextField field = tester.widget(find.byType(TextField));
      expect(field.enabled, isFalse);
      field.controller!.text = 'must not replace';
      expect(legacy.readAsStringSync(), 'UNKNOWN SPOILER');
      expect(
        NoteDraft.fileFor(fixture.directory, 0, 5, null).existsSync(),
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('later existing note is hidden even when earlier draft exists', (
    tester,
  ) async {
    final Json note = add(cutoff: 100, text: 'LATER SAVED SPOILER');
    NoteDraft(
      start: 0,
      end: 5,
      cutoff: 20,
      text: 'early draft',
      source: NoteDraft.sourceFor(fixture.data, 0, 5),
      noteId: note['id'] as String,
      revision: note['revision'] as int,
    ).write(fixture.directory);
    await openEditor(tester, existing: note);
    expect(find.text('LATER SAVED SPOILER'), findsNothing);
    expect(find.text('early draft'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(find.text('保存'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
