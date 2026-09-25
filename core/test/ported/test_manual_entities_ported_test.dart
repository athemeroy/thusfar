// Generated from docs/port/inventory.json by core/tool/generate_ported_tests.py.
// Some callbacks contain translated assertions but remain skipped until their Dart owners exist.
import 'package:test/test.dart';

import 'contract_invoker.dart';

final _book = <String, Object?>{
  'len': 30,
  'blocks': [
    {'k': 'p', 'o': 0, 't': '😀尼尔遇见黑月。', 'fn': <Object?>[]},
  ],
};
final _graph = <String, Object?>{'log': <Object?>[]};
final _base = <String, Object?>{
  'id': '12345678-abcd',
  'kind': 'person',
  'name': '尼尔',
  'note': '已出现',
  'knowledge_cutoff': 10,
  'expected_revision': 0,
  'operation': 'aaaaaaaa-bbbb',
};

List<Object?> _apply(
  List<Object?> items,
  Map<String, Object?> payload,
  Map<String, Object?> graph,
) =>
    (callPorted('server.manual_entities.apply', {
              'items': items,
              'payload': payload,
              'book': _book,
              'graph': graph,
            })
            as Map<String, Object?>)['\$tuple']
        as List<Object?>;

List<Map<String, Object?>> _rows(List<Object?> items) =>
    (callPorted('server.manual_entities.rows', {'items': items})
            as List<Object?>)
        .cast<Map<String, Object?>>();

void main() {
  test(
    "tests.test_manual_entities.ManualRules.test_utf16_anchor_and_versions_do_not_spoil_earlier_pages",
    () {
      final first = _apply(<Object?>[], _base, _graph);
      expect(first[2], isFalse);
      final firstItems = first[0] as List<Object?>;
      expect((first[1] as Map<String, Object?>)['source_start'], 2);
      expect(_rows(firstItems).first['p'], 10);
      expect(_rows(firstItems).first['s'], 2);
      final newer = <String, Object?>{
        ..._base,
        'note': '后来才知道',
        'knowledge_cutoff': 20,
        'expected_revision': 1,
        'operation': 'cccccccc-dddd',
      };
      final second = _apply(firstItems, newer, _graph);
      final items = second[0] as List<Object?>;
      expect(_rows(items).map((row) => row['p']), [10, 10, 20]);
      expect(
        callPorted('server.manual_entities.restore', {
          'items': items,
          'book': _book,
        }),
        items,
      );
      final replay = _apply(items, newer, _graph);
      expect(identical(replay[0], items), isTrue);
      expect((replay[1] as Map<String, Object?>)['revision'], 2);
      expect(
        () => _apply(items, {...newer, 'note': '不同的重试内容'}, _graph),
        throwsA(
          predicate((Object error) => error.toString().contains('内容已经变化')),
        ),
      );
    },
    skip:
        "Dart implementation of server.manual_entities.apply, server.manual_entities.restore, server.manual_entities.rows is pending (A6); required to check 'utf16 anchor and versions do not spoil earlier pages'.",
  );
  test(
    "tests.test_manual_entities.ManualRules.test_existing_visible_name_is_not_duplicated",
    () => expect(
      () => _apply(<Object?>[], _base, {
        'log': [
          {'t': 'person', 'p': 8, 'id': 'P1', 'name': '尼尔'},
        ],
      }),
      throwsA(predicate((Object error) => error.toString().contains('已有这个名称'))),
    ),
    skip:
        "Dart implementation of server.manual_entities.apply is pending (A6); required to check 'existing visible name is not duplicated'.",
  );
  test(
    "tests.test_manual_entities.ManualRules.test_name_must_be_in_already_read_source",
    () => expect(
      () => _apply(<Object?>[], {
        ..._base,
        'name': '黑月',
        'knowledge_cutoff': 4,
      }, _graph),
      throwsA(predicate((Object error) => error.toString().contains('当前已读原文'))),
    ),
    skip:
        "Dart implementation of server.manual_entities.apply is pending (A6); required to check 'name must be in already read source'.",
  );
  test(
    "tests.test_manual_entities.ManualRules.test_inline_mentions_preserve_generated_names_and_utf16_positions",
    () {
      final blocks = [
        {'k': 'p', 'o': 0, 't': '😀尼尔遇见黑月。', 'fn': <Object?>[]},
      ];
      final items = [
        {
          'id': '12345678-abcd',
          'kind': 'person',
          'name': '尼尔',
          'deleted': false,
        },
        {
          'id': 'abcdefgh-1234',
          'kind': 'concept',
          'name': '黑月',
          'deleted': false,
        },
        {'id': 'deleted-1234', 'kind': 'person', 'name': '遇见', 'deleted': true},
      ];
      expect(
        callPorted('server.manual_entities.mentions', {
          'blocks': blocks,
          'items': items,
          'existing': [
            [2, 4, 'P1'],
          ],
        }),
        [
          [2, 4, 'P1'],
          [6, 8, 'Uabcdefgh-1234'],
        ],
      );
      expect(
        callPorted('server.manual_entities.mentions', {
          'blocks': blocks,
          'items': items,
          'existing': <Object?>[],
        }),
        [
          [2, 4, 'U12345678-abcd'],
          [6, 8, 'Uabcdefgh-1234'],
        ],
      );
    },
    skip:
        "Dart implementation of server.manual_entities.mentions is pending (A6); required to check 'inline mentions preserve generated names and utf16 positions'.",
  );
  test(
    "tests.test_manual_entities.ManualHTTP.test_manual_endpoint_cutoff_retry_export_and_delete",
    () {
      // A6's scripted HTTP adapter creates HTTPRepair.make_book once, runs
      // these requests against one service, imports response 6, then reads
      // the imported manual-entities.json into importedManualEntities.
      final payload = <String, Object?>{
        'id': '12345678-abcd',
        'kind': 'concept',
        'name': 'came',
        'note': '一个概念',
        'knowledge_cutoff': 10,
        'expected_revision': 0,
        'operation': 'aaaaaaaa-bbbb',
      };
      final deleted = <String, Object?>{
        ...payload,
        'deleted': true,
        'knowledge_cutoff': 12,
        'expected_revision': 1,
        'operation': 'cccccccc-dddd',
      };
      final result =
          callPorted('server.app.Handler.route', {
                'fixture': 'HTTPRepair.make_book',
                'steps': [
                  {
                    'method': 'PUT',
                    'path': '/api/books/fixture/manual-entities',
                    'body': payload,
                  },
                  {
                    'method': 'PUT',
                    'path': '/api/books/fixture/manual-entities',
                    'body': payload,
                  },
                  {
                    'method': 'GET',
                    'path': '/api/books/fixture/manual-entities?to=9',
                  },
                  {
                    'method': 'GET',
                    'path': '/api/books/fixture/kg?from=-1&to=9',
                  },
                  {
                    'method': 'GET',
                    'path': '/api/books/fixture/kg?from=-1&to=10',
                  },
                  {'method': 'GET', 'path': '/api/books/fixture/chapters/0'},
                  {'method': 'GET', 'path': '/api/books/fixture/export'},
                  {
                    'method': 'POST',
                    'path': '/api/books/import',
                    'bodyFromResponse': 6,
                  },
                  {
                    'method': 'PUT',
                    'path': '/api/books/fixture/manual-entities',
                    'body': deleted,
                  },
                  {
                    'method': 'GET',
                    'path': '/api/books/fixture/kg?from=-1&to=12',
                  },
                  {'method': 'GET', 'path': '/api/books/fixture/chapters/0'},
                ],
              })
              as Map<String, Object?>;
      final responses =
          (result['responses'] as List<Object?>).cast<Map<String, Object?>>();
      Map<String, Object?> body(int index) =>
          responses[index]['body'] as Map<String, Object?>;
      expect(responses[0]['status'], 200);
      expect((body(0)['item'] as Map<String, Object?>)['source_start'], 6);
      expect(responses[1]['status'], 200);
      expect(body(2)['items'], isEmpty);
      expect(body(3)['records'], hasLength(1));
      expect(
        (body(4)['records'] as List<Object?>).cast<Map<String, Object?>>().map(
          (row) => row['t'],
        ),
        ['person', 'person', 'profile'],
      );
      expect(body(5)['mentions'], [
        [0, 5, 'p1'],
        [6, 10, 'U12345678-abcd'],
      ]);
      final exported = body(6)['manual_entities'] as List<Object?>;
      expect((exported.first as Map<String, Object?>)['name'], 'came');
      expect(result['importedManualEntities'], exported);
      expect(responses[8]['status'], 200);
      expect(body(9)['records'], hasLength(1));
      expect(body(10)['mentions'], [
        [0, 5, 'p1'],
      ]);
    },
    skip:
        "Dart implementation of server.manual_entities is pending (A6); required to check 'manual endpoint cutoff retry export and delete'.",
  );
}
