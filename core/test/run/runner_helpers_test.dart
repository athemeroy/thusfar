import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/run.dart';
import 'package:thusfar_core/src/pipeline/kg.dart';

import '../golden/codec.dart';

typedef Json = Map<String, Object?>;
Json object(Object? value) => value as Json? ?? {};
List<Json> rows(Object? value) => (value as List<Object?>? ?? []).cast<Json>();
KG restoreGraph(Json fields) {
  final KG graph = KG(object(fields['book']));
  graph.people = {
    for (final e in object(fields['people']).entries)
      e.key: {
        ...object(e.value),
        'aliases':
            (object(e.value)['aliases']! as Iterable<Object?>)
                .cast<String>()
                .toSet(),
        'weak':
            (object(e.value)['weak'] as Iterable<Object?>? ?? [])
                .cast<String>()
                .toSet(),
      },
  };
  graph.rels = {
    for (final e in object(fields['rels']).entries) e.key: object(e.value),
  };
  graph.log = rows(fields['log']);
  graph.seg = fields['seg'] as int? ?? 0;
  graph.recent = (fields['recent'] as List<Object?>? ?? []).cast<String>();
  graph.saga = fields['saga'] as String? ?? '';
  return graph;
}

void restoreRunner(Runner runner, Json fields) {
  final Json graph = object(object(fields['kg'])['fields']);
  runner.book = object(fields['book'] ?? graph['book']);
  runner.kg = restoreGraph(graph);
  runner.segs = rows(fields['segs']);
  runner.works = [
    for (final Object? row in fields['works'] as List<Object?>? ?? [])
      ((row! as List<Object?>)[0]! as int, (row as List<Object?>)[1]! as int),
  ];
}

void main() {
  late Directory temp;
  late Runner runner;
  setUpAll(() async {
    temp = Directory.systemTemp.createTempSync('thusfar-run-helpers-');
    File(
      '../oracle/corpus/snapshots/aq_complete/book.json',
    ).copySync('${temp.path}/book.json');
    runner = await Runner.create(temp);
  });
  tearDownAll(() async {
    await runner.close();
    temp.deleteSync(recursive: true);
  });
  final Map<String, Object? Function(Json)> calls = {
    'cast_hint': (i) => runner.castHint(i['limit']! as int),
    'relation_memory': (i) => runner.relationMemory(i['limit']! as int),
    '_dossiers':
        (i) => runner.dossiers(i['end_pos']! as int, i['start_pos']! as int),
    'relation_context':
        (i) => runner.relationContext(
          i['i']! as int,
          object(i['data']),
          i['memory'] as Json?,
        ),
    '_text_around':
        (i) => runner.textAround(i['pos']! as int, i['width']! as int),
    'scope_start': (i) => runner.scopeStart(i['pos']! as int),
    'chapter_name': (i) => runner.chapterName(i['ci']! as int),
    'verified_summary':
        (i) => Runner.verifiedSummary(
          object(i['record']),
          (i['fields']! as List<Object?>).cast<String>(),
        ),
    '_valid_support': (i) => RunnerSupport.validSupport(i['answer']),
  };
  for (final entry in calls.entries) {
    final List<String> captures =
        File(
          '../oracle/goldens/pipeline/run/Runner/${entry.key}.jsonl',
        ).readAsLinesSync();
    test('${entry.key}: ${captures.length} historical Python captures', () {
      for (final (int index, String line) in captures.indexed) {
        final Json capture = jsonDecode(line) as Json,
            input = decodeInput(capture['input'])! as Json;
        restoreRunner(runner, object(object(input['self'])['fields']));
        expect(
          guard(() => entry.value(input)),
          capture['output'],
          reason: '${entry.key} capture $index',
        );
      }
    });
  }
}
