import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/src/fold/fold.dart';

/// JSON.stringify drops undefined; round-tripping through JSON matches it.
Object? _json(Object? v) => jsonDecode(jsonEncode(v));

void main() {
  const Map<String, String> sources = <String, String>{
    'aq_annotated': '../oracle/corpus/snapshots/aq_annotated',
    'aq_complete': '../oracle/corpus/snapshots/aq_complete',
    'aq_paused_annotated': '../oracle/corpus/snapshots/aq_paused_annotated',
  };
  for (final File golden
      in Directory('../oracle/goldens/fold').listSync().whereType<File>()) {
    final String name = golden.uri.pathSegments.last.replaceAll('.jsonl', '');
    final String? dir = sources[name] ?? _findBookDir(name);
    if (dir == null) continue;
    final List<Json> records = <Json>[
      for (final Object? r
          in (jsonDecode(File('$dir/kg.json').readAsStringSync())
                  as Json)['log']!
              as List<Object?>)
        r! as Json,
    ];
    final Json status =
        jsonDecode(File('$dir/status.json').readAsStringSync()) as Json;
    int index = 0;
    for (final String line in golden.readAsLinesSync()) {
      final Json want = jsonDecode(line) as Json;
      test('fold $name #${index++} cutoff ${want['cutoff']}', () {
        final World w =
            fold(records, want['cutoff']! as int)
              ..frontier = (status['frontier'] as int?) ?? 0
              ..state = (status['state'] as String?) ?? '';
        final Set<String> ids = <String>{
          for (final Json r in records)
            for (final Object? v in <Object?>[
              r['id'],
              r['from'],
              r['into'],
              r['a'],
              r['b'],
              ...(r['who'] as List<Object?>? ?? const []),
            ])
              if (v is String && v.isNotEmpty) v,
        };
        final List<String> sortedIds = ids.toList()..sort();
        final List<String> people = w.people.keys.toList()..sort();
        expect(_json(w.people), want['people']);
        expect(_json(w.rels), want['rels']);
        expect(_json(w.events), want['events']);
        expect(_json(w.recaps), want['recaps']);
        expect(_json(w.saga), want['saga']);
        expect(<String, String>{
          for (final String id in sortedIds) id: w.canon(id),
        }, want['canon']);
        expect(
          _json(<String, Object?>{
            for (final String id in people) id: w.relsOf(id),
          }),
          want['relsOf'],
        );
        expect(w.ranked().map((Json p) => p['id']).toList(), want['ranked']);
        expect(w.frontier, want['frontier']);
      });
    }
  }
}

String? _findBookDir(String name) {
  final Directory dir = Directory('../oracle/goldens/books/$name');
  return dir.existsSync() ? dir.path : null;
}
