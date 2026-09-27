// Translated Python 1.7.5 reading-list HTTP contracts; enabled with A6.
import 'package:test/test.dart';

import 'contract_invoker.dart';

Map<String, Object?> _put(
  Object? items, {
  String operation = 'list-operation-01',
  Object? expected = 0,
}) => {
  'method': 'PUT',
  'path': '/api/reading-list',
  'body': {
    'items': items,
    'operation': operation,
    'expected_revision': expected,
  },
};

Map<String, Object?> _run(
  List<Map<String, Object?>> steps, {
  List<String> books = const ['one', 'two'],
}) =>
    callPorted('server.app.Handler.route', {
          // A6's test adapter creates these HTTPRepair.make_book fixtures and
          // executes steps on one service. Directives do not occupy response
          // slots. It returns file-existence and parallel-request receipts.
          'books': books,
          'steps': steps,
        })
        as Map<String, Object?>;

List<Map<String, Object?>> _responses(Map<String, Object?> trace) =>
    (trace['responses'] as List<Object?>).cast<Map<String, Object?>>();

void main() {
  test(
    "tests.test_reading_list.ReadingListHTTP.test_order_receipt_conflict_and_no_progress_inference",
    () {
      final trace = _run([
        {'method': 'GET', 'path': '/api/reading-list'},
        _put(['two', 'one']),
        _put(['two', 'one']),
        _put(['one']),
        _put(['one'], operation: 'list-operation-02'),
        _put(['one'], operation: 'list-operation-03', expected: 1),
        {
          'directive': 'inspectFile',
          'path': 'progress.json',
          'resultKey': 'progressExists',
        },
      ]);
      final responses = _responses(trace);
      final first = responses[1]['body'] as Map<String, Object?>;
      expect((responses[0]['body'] as Map<String, Object?>)['items'], isEmpty);
      expect(responses[1]['status'], 200);
      expect(first['items'], ['two', 'one']);
      expect(responses[2]['status'], 200);
      expect(responses[2]['body'], first);
      expect(responses[3]['status'], 400);
      expect(responses[3]['body'], {'error': '同一个书单操作不能提交不同内容'});
      expect(responses[4]['status'], 409);
      expect((responses[4]['body'] as Map<String, Object?>)['list'], first);
      expect((responses[5]['body'] as Map<String, Object?>)['revision'], 2);
      expect(trace['progressExists'], isFalse);
    },
    skip: 'A6 reading-list route and persistent service fixture are pending.',
  );
  test(
    "tests.test_reading_list.ReadingListHTTP.test_concurrent_reorders_have_exactly_one_winner",
    () {
      final trace = _run([
        {
          'parallel': [
            _put(['one', 'two'], operation: 'list-operation-00'),
            _put(['two', 'one'], operation: 'list-operation-01'),
          ],
        },
      ]);
      final statuses =
          (trace['parallelStatuses'] as List<Object?>).cast<int>()..sort();
      expect(statuses, [200, 409]);
    },
    skip: 'A6 reading-list optimistic concurrency adapter is pending.',
  );
  test(
    "tests.test_reading_list.ReadingListHTTP.test_unavailable_slots_preserved_but_new_hidden_or_missing_books_rejected",
    () {
      final trace = _run([
        {'directive': 'makeBook', 'id': 'hidden'},
        {
          'directive': 'writeMeta',
          'id': 'hidden',
          'meta': {'hidden': true},
        },
        _put(['hidden']),
        _put(['missing']),
        _put(['one', 'two']),
        {'method': 'DELETE', 'path': '/api/books/one'},
        _put(['two', 'one'], operation: 'list-operation-02', expected: 1),
        _put(['two'], operation: 'list-operation-03', expected: 2),
        _put(['one', 'two'], operation: 'list-operation-04', expected: 3),
      ]);
      expect(_responses(trace).map((response) => response['status']), [
        400,
        400,
        200,
        200,
        200,
        200,
        400,
      ]);
    },
    skip: 'A6 reading-list unavailable-slot and hidden-book rules are pending.',
  );
  test(
    "tests.test_reading_list.ReadingListHTTP.test_bad_payload_never_creates_state",
    () {
      final invalidItems = [
        ['one', 'one'],
        ['../one'],
        [true],
        'one',
        List.filled(201, 'one'),
      ];
      final invalidRevisions = <Object?>[true, -1, 0.5, null];
      final trace = _run(
        [
          for (final items in invalidItems) _put(items),
          for (final revision in invalidRevisions)
            _put(['one'], expected: revision),
          {
            'directive': 'inspectFile',
            'path': 'reading-list.json',
            'resultKey': 'readingListExists',
          },
        ],
        books: ['one'],
      );
      expect(
        _responses(trace).map((response) => response['status']),
        List.filled(9, 400),
      );
      expect(trace['readingListExists'], isFalse);
    },
    skip: 'A6 reading-list validation and durable-state adapter are pending.',
  );
}
