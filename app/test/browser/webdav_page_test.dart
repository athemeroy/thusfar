@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/ui/theme.dart';
import 'package:thusfar_app/web/web_storage.dart';
import 'package:thusfar_app/web/webdav_sync.dart';

const _name = '20261005T010203004Z-abcdef123456.thusfar.json';
final _snapshot = WebDavSnapshot(
  _name,
  Uri.parse('https://fixture.invalid/$_name'),
);

class _Client extends Fake implements WebDavClient {
  int disposed = 0;
  @override
  Future<List<WebDavSnapshot>> list() async => [_snapshot];
  @override
  Future<Uint8List> download(WebDavSnapshot snapshot) async =>
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'format': 'thusfar-web-backup-v1',
            'meta': {'title': 'Fixture snapshot'},
          }),
        ),
      );
  @override
  void dispose() {
    disposed++;
  }
}

class _Library extends Fake implements WebLibrary {
  int previews = 0;
  int imports = 0;
  bool conflict = false;
  Completer<String>? previewGate;
  @override
  Future<String> importBackup(
    Uint8List bytes, {
    bool previewOnly = false,
  }) async {
    if (previewOnly) {
      previews++;
      if (conflict) throw const WebBackupConflict('Synthetic conflict');
      return previewGate?.future ?? 'fixture';
    }
    imports++;
    return 'fixture';
  }
}

void main() {
  Future<GlobalKey<NavigatorState>> open(
    WidgetTester tester,
    _Library library,
    _Client client,
  ) async {
    tester.view.physicalSize = const Size(700, 1300);
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
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => WebDavSyncPage(
            library: library,
            books: const [],
            clientFactory: (_, _, _) => client,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('列出远端备份'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('2026-10-05 01:02:03 UTC'));
    return navigator;
  }

  testWidgets(
    'web snapshot validates first and cancel/back leave storage unchanged',
    (tester) async {
      final library = _Library();
      final client = _Client();
      final navigator = await open(tester, library, client);
      await tester.tap(find.text('2026-10-05 01:02:03 UTC'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(library.previews, 1);
      expect(library.imports, 0);
      expect(
        find.textContaining('Fixture snapshot\n2026-10-05 01:02:03 UTC\n'),
        findsOneWidget,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(library.imports, 0);
      expect(find.text('已取消导入，本地书籍未改动。'), findsOneWidget);
      await navigator.currentState!.maybePop();
      await tester.pumpAndSettle();
      expect(find.text('Shelf fixture'), findsOneWidget);
      expect(client.disposed, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('web conflict preview cannot publish', (tester) async {
    final library = _Library()..conflict = true;
    await open(tester, library, _Client());
    await tester.tap(find.text('2026-10-05 01:02:03 UTC'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Synthetic conflict'), findsNothing);
    expect(find.textContaining('这份备份与现有内容不同'), findsOneWidget);
    expect(find.text('导入到此浏览器'), findsNothing);
    expect(library.imports, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'stop during web validation prevents late confirmation or import',
    (tester) async {
      final library = _Library()..previewGate = Completer<String>();
      final client = _Client();
      await open(tester, library, client);
      await tester.tap(find.text('2026-10-05 01:02:03 UTC'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.ensureVisible(find.text('停止当前任务'));
      await tester.tap(find.text('停止当前任务'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('停止任务'));
      await tester.pumpAndSettle();
      expect(client.disposed, 1);
      library.previewGate!.complete('fixture');
      await tester.pumpAndSettle();
      expect(find.text('远端书籍备份'), findsNothing);
      expect(library.imports, 0);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
