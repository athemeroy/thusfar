import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/backup.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/main.dart';

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
