import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/backup.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/library_zip.dart';
import 'package:thusfar_app/data/purification_store.dart';
import 'package:thusfar_app/data/reader_customizations.dart';
import 'package:thusfar_app/reader/text_purification.dart';
import 'package:thusfar_app/data/reader_directory.dart';
import 'package:thusfar_app/reader/page_body.dart';
import 'package:thusfar_app/reader/tap_layout.dart';
import 'package:thusfar_app/screens/settings_screen.dart';
import 'package:thusfar_app/main.dart';

class _RecordingFilePicker extends FilePicker {
  Uint8List? saved;
  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    saved = bytes;
    return '/fixture.zip';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel paths = MethodChannel('thusfar/paths');
  const StandardMethodCodec codec = StandardMethodCodec();
  late Directory root;
  late AppModel model;
  late List<Object?> pending;
  int reads = 0;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('thusfar-share-test-');
    model = AppModel(root);
    await model.library.scan();
    pending = <Object?>[];
    reads = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (MethodCall call) async {
          if (call.method == 'takeImports') {
            reads++;
            final List<Object?> result = List<Object?>.of(pending);
            pending.clear();
            return result;
          }
          throw MissingPluginException();
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, null);
    model.dispose();
    root.deleteSync(recursive: true);
  });

  File incoming(String title) {
    final File cached = File('${root.path}/$title.import');
    cached.writeAsStringSync(
      jsonEncode(<String, Object?>{
        'format': 'yedu-book/2',
        'book': <String, Object?>{
          'title': title,
          'len': 5,
          'lang': 'en',
          'blocks': <Object?>[
            <String, Object?>{'k': 'p', 't': 'Alice', 'o': 0},
          ],
          'chapters': <Object?>[
            <String, Object?>{
              'title': 'One',
              'b0': 0,
              'b1': 1,
              'o0': 0,
              'o1': 5,
              'kind': 'body',
            },
          ],
          'notes': <String, Object?>{},
        },
        'kg': <String, Object?>{'log': <Object?>[]},
        'status': <String, Object?>{'state': 'paused'},
      }),
    );
    pending.add(<String, String>{
      'name': '$title.yedu.json',
      'path': cached.path,
    });
    return cached;
  }

  Future<void> signal(WidgetTester tester) async {
    final Future<ByteData?> reply = tester.binding.defaultBinaryMessenger
        .handlePlatformMessage(
          paths.name,
          codec.encodeMethodCall(const MethodCall('importsAvailable')),
          null,
        );
    await tester.pumpAndSettle();
    await reply;
  }

  testWidgets(
    'cold start consumes native imports using the original filename and removes cache',
    (WidgetTester tester) async {
      final File cached = incoming('Cold start');
      await tester.pumpWidget(ThusfarApp(model: model));
      await tester.pumpAndSettle();
      expect(reads, 1);
      expect(model.library.books.single.title, 'Cold start');
      expect(cached.existsSync(), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'warm notifications accept another batch and duplicate imports retain one book',
    (WidgetTester tester) async {
      await tester.pumpWidget(ThusfarApp(model: model));
      await tester.pumpAndSettle();
      incoming('First');
      incoming('Second');
      await signal(tester);
      expect(model.library.books.map((book) => book.title).toSet(), <String>{
        'First',
        'Second',
      });
      final File duplicate = incoming('First');
      await signal(tester);
      expect(model.library.books, hasLength(2));
      expect(duplicate.existsSync(), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'resume reloads a book published outside the old activity without starting work',
    (WidgetTester tester) async {
      await tester.pumpWidget(ThusfarApp(model: model));
      await tester.pumpAndSettle();
      expect(model.library.books, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final File cached = incoming('Imported elsewhere');
      pending
          .clear(); // Another activity, rather than this channel, consumes it.
      final Library otherActivity = Library(root);
      final ImportResult result = restoreBackup(
        otherActivity,
        'external.yedu.json',
        cached.readAsBytesSync(),
      );
      expect(result.error, isNull);
      otherActivity.dispose();
      final File status = File('${root.path}/books/${result.id}/status.json');
      writeJson(status, <String, Object?>{
        'state': 'running',
        'done': 1,
        'total': 2,
        'frontier': 5,
      });
      final String before = status.readAsStringSync();
      expect(model.library.books, isEmpty);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      // Running books deliberately keep ProcessDot's breathing animation alive.
      // Flush the resume scan, then render its scheduled shelf frame.
      await tester.pump();
      await tester.pump();
      expect(model.library.books.single.title, 'Imported elsewhere');
      expect(find.text('Imported elsewhere'), findsWidgets);
      expect(model.library.books.single.status.state, 'running');
      expect(status.readAsStringSync(), before);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'open reader refreshes restored rules and directory without changing progress',
    (tester) async {
      final File cached = incoming('Live reader');
      final Json raw = jsonDecode(cached.readAsStringSync()) as Json;
      raw['meta'] = <String, Object?>{'filename': 'original.txt'};
      cached.writeAsStringSync(jsonEncode(raw));
      await tester.pumpWidget(ThusfarApp(model: model));
      await tester.pumpAndSettle();
      final BookEntry entry = model.library.books.single;
      await tester.tap(find.text('Live reader').first);
      await tester.pumpAndSettle();
      PageBody page = tester.widgetList<PageBody>(find.byType(PageBody)).first;
      expect(page.pager.textFor(page.pager.book.blocks.first).text, 'Alice');
      expect(page.pager.book.directory.enabled, isFalse);
      final File progress = File('${root.path}/progress.json');
      final Object? before = readJson(progress);
      final Json data =
          jsonDecode(utf8.decode(exportBookBytes(model.library, entry)))
              as Json;
      data['reader_customizations'] = exportReaderCustomizations(
        book: data['book']! as Json,
        bookId: entry.id,
        meta: data['meta']! as Json,
        rules: <PurificationRule>[
          PurificationRule(
            id: 'restored-rule',
            find: 'Alice',
            replacement: 'Reader',
            bookId: entry.id,
          ),
        ],
        directory: <String, Object?>{
          'version': 1,
          'bookId': entry.id,
          'length': 5,
          'enabled': true,
          'rule': 'prefix',
          'prefix': 'Alice',
          'rows': <Json>[
            <String, Object?>{'title': 'Alice', 'offset': 0},
          ],
        },
      );
      expect(
        restoreBackup(
          model.library,
          'incoming.json',
          utf8.encode(jsonEncode(data)),
        ).error,
        isNull,
      );
      await model.library.scan();
      await tester.pumpAndSettle();
      page = tester.widgetList<PageBody>(find.byType(PageBody)).first;
      expect(page.pager.textFor(page.pager.book.blocks.first).text, 'Reader');
      expect(page.pager.book.directory.enabled, isTrue);
      expect(readJson(progress), before);
      final Object pager = page.pager;
      await model.library.scan();
      await tester.pumpAndSettle();
      expect(
        tester.widgetList<PageBody>(find.byType(PageBody)).first.pager,
        same(pager),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('whole-library UI exports typed paragraph and tap preferences', (
    tester,
  ) async {
    final _RecordingFilePicker picker = _RecordingFilePicker();
    FilePicker? prior;
    try {
      prior = FilePicker.platform;
    } on Object {
      /* Platform not registered in this unit-test isolate. */
    }
    FilePicker.platform = picker;
    addTearDown(() {
      if (prior != null) FilePicker.platform = prior;
    });
    model.prefs.update((p) {
      p.paragraphSpacing = 1.25;
      p.firstLineIndent = 0;
      p.tapLayout = ReaderTapLayout.preset(ReaderTapPreset.leftHanded);
    });
    await tester.pumpWidget(ThusfarApp(model: model));
    await tester.pumpAndSettle();
    tester
        .widget<SettingsScreen>(
          find.byType(SettingsScreen, skipOffstage: false),
        )
        .onExportAll();
    await tester.pumpAndSettle();
    expect(picker.saved, isNotNull);
    final Json native =
        LibraryZipCodec.decode(picker.saved!).settings['native']! as Json;
    expect(native['paragraphSpacing'], 1.25);
    expect(native['firstLineIndent'], 0);
    expect(native['tapLayout'], model.prefs.tapLayout.toJson());
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final bool applySettings in <bool>[false, true]) {
    testWidgets(
      'typed spacing/indent/taps restore only with settings consent=$applySettings',
      (tester) async {
        model.prefs.update((p) {
          p.paragraphSpacing = .75;
          p.firstLineIndent = 3;
          p.tapLayout = ReaderTapLayout.preset(ReaderTapPreset.rightHanded);
        });
        final File cached = incoming('Typed prefs');
        final Uint8List book = cached.readAsBytesSync();
        pending.clear();
        cached.deleteSync();
        final File zip = File('${root.path}/typed.zip')
          ..writeAsBytesSync(
            LibraryZipCodec.encode(
              books: <Uint8List>[book],
              settings: <String, Object?>{
                'native': <String, Object?>{
                  'paragraphSpacing': 1.25,
                  'firstLineIndent': 0,
                  'tapLayout': ReaderTapLayout.preset(
                    ReaderTapPreset.leftHanded,
                  ).toJson(),
                },
              },
            ),
          );
        pending.add(<String, String>{'name': 'typed.zip', 'path': zip.path});
        await tester.pumpWidget(ThusfarApp(model: model));
        for (int i = 0; i < 30 && find.text('恢复整个书库').evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text(applySettings ? '使用备份设置' : '保留当前设置'));
        await tester.pumpAndSettle();
        expect(model.prefs.paragraphSpacing, applySettings ? 1.25 : .75);
        expect(model.prefs.firstLineIndent, applySettings ? 0 : 3);
        expect(
          model.prefs.tapLayout.matchingPreset,
          applySettings
              ? ReaderTapPreset.leftHanded
              : ReaderTapPreset.rightHanded,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final bool cancel in <bool>[true, false]) {
    testWidgets(
      'single-book customization preview cancel=$cancel is safe and repeatable',
      (tester) async {
        File customizedIncoming() {
          final File cached = incoming('Custom reader');
          final Json data = jsonDecode(cached.readAsStringSync()) as Json;
          const String id = '1234567890abcdef';
          data['id'] = id;
          data['reader_customizations'] = exportReaderCustomizations(
            book: data['book']! as Json,
            bookId: id,
            rules: <PurificationRule>[
              const PurificationRule(
                id: 'literal',
                find: 'Alice',
                replacement: 'A',
                bookId: id,
              ),
              const PurificationRule(id: 'global', find: 'global'),
            ],
            meta: <String, Object?>{},
          );
          cached.writeAsStringSync(jsonEncode(data));
          return cached;
        }

        final File cached = customizedIncoming();
        await tester.pumpWidget(ThusfarApp(model: model));
        for (int i = 0; i < 30 && find.text('恢复单书备份').evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('恢复单书备份'), findsOneWidget);
        expect(find.textContaining('单书备份不含全局净化规则'), findsOneWidget);
        expect(model.library.books, isEmpty);
        expect(
          File('${root.path}/text-purification.json').existsSync(),
          isFalse,
        );
        await tester.tap(find.text(cancel ? '取消' : '确认恢复'));
        await tester.pumpAndSettle();
        expect(model.library.books.length, cancel ? 0 : 1);
        expect(cached.existsSync(), isFalse);
        if (!cancel) {
          final File rules = File('${root.path}/text-purification.json');
          expect(PurificationStore.readSnapshot(rules).single.id, 'literal');
          customizedIncoming();
          final Future<ByteData?> pendingImport = tester
              .binding
              .defaultBinaryMessenger
              .handlePlatformMessage(
                paths.name,
                codec.encodeMethodCall(const MethodCall('importsAvailable')),
                null,
              );
          for (
            int i = 0;
            i < 30 && find.text('恢复单书备份').evaluate().isEmpty;
            i++
          ) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('恢复单书备份'), findsOneWidget);
          await tester.tap(find.text('确认恢复'));
          await tester.pumpAndSettle();
          await pendingImport;
          expect(PurificationStore.readSnapshot(rules).length, 1);
          expect(model.library.books.length, 1);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final bool failReportSave in <bool>[false, true]) {
    testWidgets(
      'all-failed ZIP exposes every result from the native import UI, report save failure=$failReportSave',
      (WidgetTester tester) async {
        final List<Uint8List> books = <Uint8List>[
          for (final String title in <String>[
            'Broken first',
            'Broken second',
            'Broken third',
          ])
            Uint8List.fromList(
              utf8.encode(
                jsonEncode(<String, Object?>{
                  'format': 'yedu-book/2',
                  'book': <String, Object?>{'title': title, 'len': -1},
                }),
              ),
            ),
        ];
        final File zip = File('${root.path}/failed.zip')
          ..writeAsBytesSync(
            LibraryZipCodec.encode(books: books, settings: <String, Object?>{}),
          );
        if (failReportSave) {
          Directory('${root.path}/restore-report.json').createSync();
        }
        pending.add(<String, String>{'name': 'failed.zip', 'path': zip.path});
        await tester.pumpWidget(ThusfarApp(model: model));
        for (int i = 0; i < 30 && find.text('恢复整个书库').evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('恢复整个书库'), findsOneWidget);
        expect(find.textContaining('Broken first'), findsOneWidget);
        await tester.tap(find.text('保留当前设置'));
        await tester.pumpAndSettle();
        expect(model.library.books, isEmpty);
        if (failReportSave) {
          expect(find.textContaining('报告未能保存'), findsWidgets);
          expect(model.library.lastRestoreReport, isNull);
        } else {
          expect(model.library.lastRestoreReport?.entries, hasLength(3));
          expect(model.library.lastRestoreReport?.failed, 3);
        }
        await tester.tap(find.text('查看报告'));
        await tester.pumpAndSettle();
        expect(find.text('上次恢复报告'), findsOneWidget);
        for (final String title in <String>[
          'Broken first',
          'Broken second',
          'Broken third',
        ]) {
          expect(find.text(title), findsOneWidget);
        }
        expect(find.textContaining('0 本已恢复，3 本未导入'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'native copy errors and corrupt files remain visible while later files import',
    (WidgetTester tester) async {
      pending.add(<String, String>{
        'name': 'Unavailable.txt',
        'error': '无法读取分享文件',
      });
      final File bad = File('${root.path}/broken.import')
        ..writeAsStringSync('{broken');
      pending.add(<String, String>{
        'name': 'broken.yedu.json',
        'path': bad.path,
      });
      incoming('Healthy');
      await tester.pumpWidget(ThusfarApp(model: model));
      await tester.pumpAndSettle();
      expect(model.library.books.single.title, 'Healthy');
      expect(bad.existsSync(), isFalse);
      expect(find.textContaining('无法读取分享文件'), findsOneWidget);
      expect(find.textContaining('这个文件不是导出的书'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
