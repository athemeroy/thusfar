import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/prefs.dart';
import 'package:thusfar_app/screens/shelf_screen.dart';
import 'package:thusfar_app/ui/cover.dart';
import 'package:thusfar_app/ui/theme.dart';

void main() {
  testWidgets('fixture shelf offers one-tap processing beside reading', (
    WidgetTester tester,
  ) async {
    final Directory root = Directory.systemTemp.createTempSync(
      'thusfar-shelf-processing-',
    );
    final Directory bookDir = Directory('${root.path}/books/fixture')
      ..createSync(recursive: true);
    writeJson(File('${bookDir.path}/book.json'), <String, Object?>{
      'title': 'Fixture Book',
      'author': 'Fixture Writer',
      'len': 40,
      'lang': 'en',
      'blocks': <Object?>[],
      'chapters': <Object?>[],
    });
    writeJson(File('${bookDir.path}/status.json'), <String, Object?>{
      'state': 'idle',
    });
    final Library library = Library(root);
    final Prefs prefs = Prefs(File('${root.path}/app-prefs.json'));
    addTearDown(() {
      library.dispose();
      prefs.dispose();
      root.deleteSync(recursive: true);
    });
    await library.scan();
    final BookEntry book = library.books.single;
    int opens = 0;
    int drawers = 0;
    bool focused = false;
    Future<void> render() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: ShelfScreen(
            library: library,
            prefs: prefs,
            imports: const <ImportItem>[],
            onOpen: (_) => opens++,
            onDrawer: (_, {bool focus = false}) {
              drawers++;
              focused = focus;
            },
            onImport: () {},
            onRestore: () {},
            onModelSettings: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await render();

    await tester.tap(find.byKey(ValueKey<String>('process-${book.id}')));
    expect(drawers, 1);
    expect(focused, isTrue);
    expect(opens, 0);

    await tester.tap(find.byType(BookCover).first);
    expect(opens, 1);

    writeJson(File('${bookDir.path}/status.json'), <String, Object?>{
      'state': 'running',
      'done': 0,
      'total': 0,
    });
    library.refreshStatus(book);
    await render();
    expect(find.text('整理任务'), findsOneWidget);
    expect(find.textContaining('1 本待处理或进行中'), findsOneWidget);

    await tester.tap(find.text('整理任务'));
    await tester.pumpAndSettle();
    expect(find.text('正在准备整理'), findsOneWidget);
    expect(find.text('整理中 0%'), findsNothing);

    await tester.tap(find.text('Fixture Book').last);
    await tester.pumpAndSettle();
    expect(drawers, 2);
    expect(focused, isTrue);
  });
}
