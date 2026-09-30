import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/model_settings.dart';
import 'package:thusfar_app/data/prefs.dart';
import 'package:thusfar_app/screens/settings_screen.dart';
import 'package:thusfar_app/screens/shelf_screen.dart';
import 'package:thusfar_app/ui/theme.dart';

import 'support/graph_fixture.dart';

import 'support/viewport.dart';

void main() {
  late GraphFixture fixture;
  late Prefs prefs;
  setUp(() {
    fixture = GraphFixture();
    prefs = Prefs(File('${fixture.root.path}/test-prefs.json'));
  });
  tearDown(() {
    prefs.dispose();
    fixture.dispose();
  });

  Widget app(Widget child) => MaterialApp(
    theme: buildTheme(Brightness.light),
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(1.8)),
      child: child!,
    ),
    home: child,
  );

  ShelfScreen shelf(List<ImportItem> imports, {VoidCallback? onImport}) =>
      ShelfScreen(
        library: fixture.library,
        prefs: prefs,
        imports: imports,
        onOpen: (BookEntry _) {},
        onDrawer: (BookEntry _, {bool focus = false}) {},
        onImport: onImport ?? () {},
        onRestore: () {},
        onModelSettings: () {},
      );

  testWidgets(
    'completed import receipts can be dismissed and new batches remain visible',
    (WidgetTester tester) async {
      await setTestViewport(tester, const Size(320, 740));
      addTearDown(() => setTestViewport(tester, null));
      final List<ImportItem> imports = <ImportItem>[
        ImportItem('invalid.epub')..error = '文件内容损坏，请重新选择',
      ];
      await tester.pumpWidget(app(shelf(imports)));
      await tester.pumpAndSettle();
      expect(find.textContaining('文件内容损坏'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭导入结果'));
      await tester.pumpAndSettle();
      expect(find.textContaining('文件内容损坏'), findsNothing);
      expect(find.byTooltip('关闭导入结果'), findsNothing);
      imports.add(ImportItem('next.txt')..progress = 1);
      await tester.pumpWidget(app(shelf(imports)));
      await tester.pumpAndSettle();
      expect(find.byTooltip('关闭导入结果'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'first import and model actions remain reachable on a short screen with large text',
    (WidgetTester tester) async {
      await setTestViewport(tester, const Size(320, 440));
      addTearDown(() => setTestViewport(tester, null));
      fixture.library
        ..books.clear()
        ..loaded = true;
      int imported = 0;
      await tester.pumpWidget(
        app(shelf(<ImportItem>[], onImport: () => imported++)),
      );
      await tester.pumpAndSettle();
      final Finder importAction = find.textContaining('选择书');
      await tester.ensureVisible(importAction);
      await tester.tap(importAction);
      expect(imported, 1);
      final Finder modelAction = find.text('去填写');
      await tester.ensureVisible(modelAction);
      expect(modelAction.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'storage size loads away from build and settings fit a narrow large-text screen',
    (WidgetTester tester) async {
      await setTestViewport(tester, const Size(320, 740));
      addTearDown(() => setTestViewport(tester, null));
      await tester.pumpWidget(
        app(
          SettingsScreen(
            library: fixture.library,
            prefs: prefs,
            settings: ModelSettings(File('${fixture.root.path}/model.env')),
            onModel: () {},
            onExportAll: () {},
            onRestore: () {},
            onWebDav: () {},
            onCheckUpdate: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('占用空间'), 180);
      for (int i = 0; i < 200; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (find.textContaining('MB · 1 本书').evaluate().isNotEmpty) break;
      }
      expect(find.textContaining('MB · 1 本书'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
