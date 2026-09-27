// Translated Python 1.7.5 notebook HTTP contracts; enabled with the A6 service.
import 'package:test/test.dart';

import 'contract_invoker.dart';

Map<String, Object?> _note([Map<String, Object?> overrides = const {}]) => {
  'id': 'note-test-0001',
  'kind': 'note',
  'start': 0,
  'end': 5,
  'quote': 'Alice',
  'text': 'An early thought',
  'knowledge_cutoff': 8,
  'operation': 'operation-0001',
  'expected_revision': 0,
  ...overrides,
};

Map<String, Object?> _put(Map<String, Object?> note) => {
  'method': 'PUT',
  'path': '/api/books/fixture/notebook',
  'body': note,
};

Map<String, Object?> _get(String path) => {'method': 'GET', 'path': path};

Map<String, Object?> _run(List<Map<String, Object?>> steps) =>
    callPorted('server.app.Handler.route', {
          // The A6 test adapter creates HTTPRepair.make_book and executes every
          // step on one service instance. Directives can mutate the fixture,
          // import an earlier response, or inspect the resulting data files;
          // only HTTP requests occupy slots in the responses list.
          'fixture': 'HTTPRepair.make_book',
          'steps': steps,
        })
        as Map<String, Object?>;

List<Map<String, Object?>> _responses(Map<String, Object?> trace) =>
    (trace['responses'] as List<Object?>).cast<Map<String, Object?>>();

Map<String, Object?> _body(List<Map<String, Object?>> responses, int index) =>
    responses[index]['body'] as Map<String, Object?>;

void main() {
  test(
    "tests.test_notebook.NotebookHTTP.test_idempotency_conflict_and_independent_notes",
    () {
      final responses = _responses(
        _run([
          _put(_note()),
          _put(_note()),
          _put(_note({'operation': 'operation-0002'})),
          _put(_note({'id': 'note-test-0002', 'operation': 'operation-0003'})),
          _put(
            _note({
              'operation': 'operation-0004',
              'expected_revision': 1,
              'text': 'Later thought',
              'knowledge_cutoff': 12,
            }),
          ),
          _put(
            _note({
              'operation': 'operation-0005',
              'expected_revision': 1,
              'deleted': true,
            }),
          ),
          _get('/api/books/fixture/notebook'),
        ]),
      );
      expect(responses[0]['status'], 200);
      expect(
        (_body(responses, 0)['item'] as Map<String, Object?>)['revision'],
        1,
      );
      expect(responses[1]['status'], 200);
      expect(_body(responses, 1), _body(responses, 0));
      expect(responses[2]['status'], 409);
      expect(responses[3]['status'], 200);
      expect(
        (_body(responses, 4)['item'] as Map<String, Object?>)['revision'],
        2,
      );
      expect(
        (_body(responses, 4)['item']
            as Map<String, Object?>)['knowledge_cutoff'],
        12,
      );
      expect(responses[5]['status'], 409);
      expect(_body(responses, 6)['items'], hasLength(2));
    },
    skip: 'A6 notebook service and stateful HTTP test adapter are pending.',
  );
  test(
    "tests.test_notebook.NotebookHTTP.test_anchors_reject_fabricated_quote_surrogate_split_and_future_bounds",
    () {
      final invalid = [
        {'quote': 'Wrong'},
        {'start': -1},
        {'end': 500},
        {'knowledge_cutoff': 3},
        {'text': List.filled(10001, 'x').join()},
        {'kind': 'unknown'},
      ];
      final trace = _run([
        for (final change in invalid) _put(_note(change)),
        {
          'directive': 'inspectFile',
          'path': 'fixture/notebook.json',
          'resultKey': 'notebookBeforeUnicode',
        },
        {'directive': 'replaceBookBlockText', 'block': 0, 'text': '😀Alice'},
        _put(_note({'start': 2, 'end': 7})),
        _put(_note({'id': 'note-test-0002', 'start': 1, 'end': 7})),
      ]);
      final responses = _responses(trace);
      for (var i = 0; i < invalid.length; i++) {
        expect(responses[i]['status'], 400, reason: invalid[i].keys.join(','));
      }
      expect(trace['notebookBeforeUnicode'], isFalse);
      expect(responses[6]['status'], 200);
      expect(responses[7]['status'], 400);
    },
    skip:
        'A6 notebook anchor validation and scripted fixture mutations are pending.',
  );
  test(
    "tests.test_notebook.NotebookHTTP.test_export_import_preserves_notes_and_refuses_different_personal_records",
    () {
      final responses = _responses(
        _run([
          _get('/api/books/fixture/offline-manifest'),
          _put(_note()),
          _get('/api/books/fixture/offline-manifest'),
          _get('/api/books/fixture/export'),
          {
            'method': 'POST',
            'path': '/api/books/import',
            'bodyFromResponse': 3,
          },
          {
            'method': 'GET',
            'pathFromResponse': 4,
            'pathTemplate': '/api/books/{id}/notebook',
          },
          {
            'method': 'POST',
            'path': '/api/books/import',
            'bodyFromResponse': 3,
          },
          {
            'method': 'POST',
            'path': '/api/books/import',
            'bodyFromResponse': 3,
            'bodyPatch': {'notebook[0].text': 'Different thought'},
          },
        ]),
      );
      expect(
        _body(responses, 0)['version'],
        isNot(_body(responses, 2)['version']),
      );
      expect(
        (_body(responses, 2)['notebook'] as Map<String, Object?>)['url'],
        '/api/books/fixture/notebook',
      );
      final exported = _body(responses, 3)['notebook'] as List<Object?>;
      expect((exported.first as Map<String, Object?>)['quote'], 'Alice');
      expect(responses[4]['status'], 200);
      expect(_body(responses, 5)['items'], exported);
      expect(responses[6]['status'], 200);
      expect(responses[7]['status'], 409);
    },
    skip:
        'A6 notebook export/import service and scripted HTTP adapter are pending.',
  );
  test(
    "tests.test_notebook.NotebookHTTP.test_delete_tombstone_markdown_and_book_removal_preserve_personal_data",
    () {
      final trace = _run([
        _put(_note()),
        _put(
          _note({
            'operation': 'operation-0002',
            'expected_revision': 1,
            'deleted': true,
          }),
        ),
        _get('/api/books/fixture/notebook.md'),
        {'method': 'DELETE', 'path': '/api/books/fixture'},
        {
          'directive': 'inspectTrashFile',
          'glob': '*/notebook.json',
          'resultKey': 'trashedNotebookExists',
        },
      ]);
      final responses = _responses(trace);
      expect(responses[1]['status'], 200);
      expect(responses[2]['body'], isNot(contains('An early thought')));
      expect(responses[3]['status'], 200);
      expect(trace['trashedNotebookExists'], isTrue);
    },
    skip: 'A6 notebook tombstone/export and book trash service are pending.',
  );
}
