import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/webdav.dart';
import 'package:thusfar_app/screens/webdav_screen.dart';
import 'package:thusfar_app/ui/theme.dart';

import 'backup_test.dart' as fixture;

const String _name = '20261005T010203004Z-abcdef123456.thusfar.json';
final WebDavSnapshot _snapshot = WebDavSnapshot(
  Uri.parse('https://fixture.invalid/$_name'),
  _name,
);

class _Client extends Fake implements WebDavClient {
  Completer<List<WebDavSnapshot>>? listing;
  int downloads = 0;
  int disposed = 0;
  Uint8List bytes = fixture.bytes(fixture.sample());
  @override
  Future<List<WebDavSnapshot>> list() =>
      listing?.future ?? Future.value([_snapshot]);
  @override
  Future<Uint8List> download(WebDavSnapshot snapshot) async {
    downloads++;
    return bytes;
  }

  @override
  void dispose() {
    disposed++;
  }
}

void main() {
  late Directory root;
  late Library library;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('webdav-ui-fixture-');
    library = Library(root);
    await library.scan();
  });
  tearDown(() {
    library.dispose();
    root.deleteSync(recursive: true);
  });

  Future<GlobalKey<NavigatorState>> open(
    WidgetTester tester,
    List<_Client> clients,
  ) async {
    tester.view.physicalSize = const Size(700, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: buildTheme(Brightness.light),
        home: const Scaffold(body: Text('Shelf fixture')),
      ),
    );
    int index = 0;
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => WebDavScreen(
            library: library,
            clientFactory: (_, _, _) => clients[index++],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return navigator;
  }

  Future<void> list(WidgetTester tester) async {
    await tester.tap(find.text('查看云端快照'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('2026-10-05 01:02 UTC'));
  }

  testWidgets(
    'snapshot preview shows title date size before mutation; cancel is read-only',
    (tester) async {
      final _Client listing = _Client();
      final _Client download = _Client();
      await open(tester, [listing, download]);
      await list(tester);
      await tester.tap(find.text('2026-10-05 01:02 UTC'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('WebDAV 快照预览'), findsOneWidget);
      expect(
        find.textContaining('Backup fixture\n2026-10-05 01:02 UTC\n'),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('KB'),
        ),
        findsOneWidget,
      );
      expect(library.booksDir.listSync(), isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(library.booksDir.listSync(), isEmpty);
      expect(find.text('已取消导入，本地书籍未改动。'), findsOneWidget);
      expect(download.disposed, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'invalid preview cannot import and leaves local storage unchanged',
    (tester) async {
      final _Client download = _Client()..bytes = Uint8List.fromList([1, 2, 3]);
      await open(tester, [_Client(), download]);
      await list(tester);
      await tester.tap(find.text('2026-10-05 01:02 UTC'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('未能通过校验'), findsOneWidget);
      expect(find.text('确认导入'), findsNothing);
      expect(library.booksDir.listSync(), isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'back offers continue or stop and cancelled late result cannot affect new task',
    (tester) async {
      final _Client first = _Client()
        ..listing = Completer<List<WebDavSnapshot>>();
      final _Client second = _Client()
        ..listing = Completer<List<WebDavSnapshot>>();
      final navigator = await open(tester, [first, second]);
      await tester.tap(find.text('查看云端快照'));
      await tester.pump(const Duration(milliseconds: 100));
      await navigator.currentState!.maybePop();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('停止当前任务并离开？'), findsOneWidget);
      await tester.tap(find.text('继续任务'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(first.disposed, 0);
      await tester.tap(find.text('停止当前任务'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('停止任务'));
      await tester.pumpAndSettle();
      expect(first.disposed, 1);
      await tester.tap(find.text('查看云端快照'));
      await tester.pump();
      first.listing!.complete([_snapshot]);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('2026-10-05 01:02 UTC'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      second.listing!.complete([]);
      await tester.pumpAndSettle();
      expect(find.text('这个文件夹还没有页读快照。'), findsOneWidget);
      await navigator.currentState!.maybePop();
      await tester.pumpAndSettle();
      expect(find.text('Shelf fixture'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
